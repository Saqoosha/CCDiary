import Foundation
import SQLite3
import os.log

private let logger = Logger(subsystem: "CCDiary", category: "CursorService")

// SQLITE_TRANSIENT tells SQLite to copy the string immediately
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Persistent date → bubbleKey index for Cursor's globalStorage SQLite.
///
/// Cursor stores every chat bubble under `cursorDiskKV` with a key like
/// `bubbleId:<composerId>:<bubbleId>` and the JSON payload (incl. `createdAt`)
/// in the value blob. There's no SQL-side date index, so naive per-day scans
/// re-parse every blob on every call — pathological once `state.vscdb` grows
/// past a few hundred MB.
///
/// This actor caches `date → [bubbleKey]` to disk so subsequent date queries
/// turn into a single `WHERE key IN (...)` query. Invalidated by DB mtime.
private actor CursorBubbleIndex {
    private var byDate: [String: [String]] = [:]
    private var isLoaded = false
    /// True once `setIndex` has run for the current `lastDBModTime`. Lets us
    /// distinguish "no Cursor activity ever" (zero bubbles, no rebuild needed)
    /// from "cache empty because we haven't built yet" (rebuild required).
    private var hasBuilt = false
    private var lastDBModTime: TimeInterval = 0

    private static var cacheFileURL: URL {
        let fileManager = FileManager.default
        let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!

        // Remove legacy cache directory
        let legacyDir = cachesDir.appendingPathComponent("ccdiary")
        if fileManager.fileExists(atPath: legacyDir.path) {
            try? fileManager.removeItem(at: legacyDir)
        }

        let cacheDir = cachesDir.appendingPathComponent("CCDiary")
        try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir.appendingPathComponent("cursor_bubble_index_v1.json")
    }

    /// Old v0 cache file. Removed on first load if present.
    private static var legacyCacheFileURL: URL {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cachesDir.appendingPathComponent("CCDiary/cursor_dates.json")
    }

    func getDates() -> Set<String> {
        ensureLoaded()
        return Set(byDate.keys)
    }

    func getKeys(for date: String) -> [String]? {
        ensureLoaded()
        return byDate[date]
    }

    func setIndex(_ newIndex: [String: [String]], dbModTime: TimeInterval) {
        byDate = newIndex
        lastDBModTime = dbModTime
        isLoaded = true
        hasBuilt = true
        saveToDisk()
    }

    func needsRebuild(currentDBModTime: TimeInterval) -> Bool {
        ensureLoaded()
        if currentDBModTime != lastDBModTime { return true }
        // mtime matches and we already built once for this DB — even an empty
        // index is "definitively empty" (no Cursor activity), so don't rescan.
        return !hasBuilt
    }

    private func ensureLoaded() {
        guard !isLoaded else { return }
        loadFromDisk()
        isLoaded = true
        // Drop the v0 file if it's still around — the v1 cache supersedes it.
        try? FileManager.default.removeItem(at: Self.legacyCacheFileURL)
    }

    private func loadFromDisk() {
        let url = Self.cacheFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)
            let stored = try JSONDecoder().decode(StoredCursorBubbleIndex.self, from: data)
            byDate = stored.byDate
            lastDBModTime = stored.dbModTime
            hasBuilt = true
            let bubbleCount = byDate.values.reduce(0) { $0 + $1.count }
            // logger.notice (not .info) — index load status should survive
            // log rotation so post-hoc debugging can confirm cache was used.
            logger.notice("Loaded Cursor bubble index: \(self.byDate.count) dates, \(bubbleCount) bubbles")
        } catch is DecodingError {
            // Schema drift or genuinely corrupt JSON — safe to drop.
            logger.warning("Cursor bubble index incompatible/corrupt, rebuilding")
            try? FileManager.default.removeItem(at: url)
        } catch {
            // Transient I/O failure — keep the file, leave the in-memory state
            // empty so the next call rebuilds from the DB.
            logger.warning("Cursor bubble index read failed (will rebuild from DB): \(error.localizedDescription)")
        }
    }

    private func saveToDisk() {
        let stored = StoredCursorBubbleIndex(byDate: byDate, dbModTime: lastDBModTime)
        do {
            let data = try JSONEncoder().encode(stored)
            try data.write(to: Self.cacheFileURL)
        } catch {
            logger.error("Failed to save Cursor bubble index: \(error)")
        }
    }

    private struct StoredCursorBubbleIndex: Codable {
        let byDate: [String: [String]]
        let dbModTime: TimeInterval
    }
}

/// Service for reading Cursor activity data from SQLite database
actor CursorService {
    private let globalDBPath: String
    private let workspaceStoragePath: String
    private var globalDB: OpaquePointer?
    private let bubbleIndex = CursorBubbleIndex()

    /// Default Cursor paths
    static var defaultGlobalDBPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }

    static var defaultWorkspaceStoragePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Cursor/User/workspaceStorage"
    }

    init(globalDBPath: String = CursorService.defaultGlobalDBPath,
         workspaceStoragePath: String = CursorService.defaultWorkspaceStoragePath) {
        self.globalDBPath = globalDBPath
        self.workspaceStoragePath = workspaceStoragePath
    }

    /// Close database connection
    func close() {
        if let db = globalDB {
            sqlite3_close(db)
            self.globalDB = nil
        }
    }

    /// Check if Cursor database exists
    nonisolated func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: globalDBPath)
    }

    /// Check if we have permission to access Cursor database
    /// Returns: .notInstalled, .noPermission, or .accessible
    nonisolated func checkAccessStatus() -> CursorAccessStatus {
        guard FileManager.default.fileExists(atPath: globalDBPath) else {
            return .notInstalled
        }

        // Try to open the database with immutable mode and run a test query
        var db: OpaquePointer?
        let uriPath = "file:\(globalDBPath)?immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(uriPath, &db, flags, nil)
        defer {
            if db != nil {
                sqlite3_close(db)
            }
        }

        guard result == SQLITE_OK else {
            return .noPermission
        }

        // Also verify we can actually query
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT 1", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_finalize(stmt)
            return .accessible
        } else {
            return .noPermission
        }
    }

    /// Open global database connection (read-only, immutable mode)
    private func openGlobalDB() throws {
        guard globalDB == nil else { return }

        // Use immutable mode via URI to avoid WAL/temp file issues
        let uriPath = "file:\(globalDBPath)?immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(uriPath, &globalDB, flags, nil)
        if result != SQLITE_OK {
            let errorMsg = String(cString: sqlite3_errmsg(globalDB))
            throw CursorServiceError.databaseOpenFailed(errorMsg)
        }
    }

    /// Open a workspace-specific database (read-only, immutable mode)
    private nonisolated func openWorkspaceDB(at path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        // Use immutable mode via URI to avoid WAL/temp file issues
        let uriPath = "file:\(path)?immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(uriPath, &db, flags, nil) == SQLITE_OK {
            return db
        }
        return nil
    }

    /// Get daily stats for a specific date
    func getDailyStats(for date: Date) async throws -> CursorDailyStats? {
        guard isAvailable() else {
            logger.notice("getDailyStats: Cursor not available")
            return nil
        }

        try openGlobalDB()

        let dateString = DateFormatting.iso.string(from: date)
        let key = "aiCodeTracking.dailyStats.v1.5.\(dateString)"

        let query = "SELECT value FROM ItemTable WHERE key = ?"

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(globalDB, query, -1, &stmt, nil) != SQLITE_OK {
            let errorMsg = String(cString: sqlite3_errmsg(globalDB))
            throw CursorServiceError.queryFailed(errorMsg)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)

        if sqlite3_step(stmt) == SQLITE_ROW {
            guard let valuePtr = sqlite3_column_blob(stmt, 0) else { return nil }
            let valueLength = sqlite3_column_bytes(stmt, 0)
            let valueData = Data(bytes: valuePtr, count: Int(valueLength))

            if let stats = try? JSONDecoder().decode(CursorDailyStats.self, from: valueData) {
                let tabAcc = stats.tabAcceptedLines ?? 0
                let tabSug = stats.tabSuggestedLines ?? 0
                let compAcc = stats.composerAcceptedLines ?? 0
                let compSug = stats.composerSuggestedLines ?? 0
                logger.notice("getDailyStats(\(dateString)): Tab=\(tabAcc)/\(tabSug), Composer=\(compAcc)/\(compSug)")
                return stats
            }
        }

        logger.notice("getDailyStats(\(dateString)): no stats found")
        return nil
    }

    /// Get all dates that have actual Composer messages (from cache only)
    func getAllDatesWithMessages() async throws -> Set<String> {
        guard isAvailable() else {
            return []
        }
        // Return cached dates - buildDateIndexIfNeeded() should be called at startup
        return await bubbleIndex.getDates()
    }

    /// Build date index if needed (call at app startup)
    func buildDateIndexIfNeeded() async throws -> Set<String> {
        guard isAvailable() else {
            return []
        }

        // Check if cache needs rebuild
        let dbModTime = getDBModTime()
        if await !bubbleIndex.needsRebuild(currentDBModTime: dbModTime) {
            logger.notice("Cursor bubble index up-to-date")
            return await bubbleIndex.getDates()
        }

        // Rebuild cache from database
        try await rebuildBubbleIndex(dbModTime: dbModTime)
        return await bubbleIndex.getDates()
    }

    /// Build the bubble index by scanning all `bubbleId:%` rows once. Reuses
    /// the byte-pattern matcher from `getAllMessageDates` so we extract date
    /// AND key in a single pass — no JSON parse per row.
    private func rebuildBubbleIndex(dbModTime: TimeInterval) async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        try openGlobalDB()

        let workspaces = getAllWorkspaces()
        logger.notice("rebuildBubbleIndex: \(workspaces.count) workspaces found")

        let byDate = try collectBubbleKeysByDate()
        await bubbleIndex.setIndex(byDate, dbModTime: dbModTime)

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        let bubbleCount = byDate.values.reduce(0) { $0 + $1.count }
        logger.notice("Built Cursor bubble index: \(byDate.count) dates, \(bubbleCount) bubbles in \(elapsed, format: .fixed(precision: 1))ms")
    }

    /// Get database modification time
    private nonisolated func getDBModTime() -> TimeInterval {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: globalDBPath),
              let modDate = attrs[.modificationDate] as? Date else {
            return 0
        }
        return modDate.timeIntervalSince1970
    }

    /// Single-pass byte-pattern scan that builds a `date → [bubbleKey]` map.
    /// Reads `key` and `value` together so we never have to revisit blobs.
    /// JSON parsing is deferred to `parseBubbles(...)` — that runs only on the
    /// small subset of bubbles for the queried date.
    ///
    /// Date keys are in **the user's local time zone**, matching how
    /// `getGlobalMessagesByComposer(for:)` resolves the requested date via
    /// `Calendar.current.startOfDay(for:)`. Naively prefixing the ISO
    /// `createdAt` (which is always UTC `Z`) would split bubbles created
    /// between 00:00 and the local UTC offset onto the wrong day.
    private func collectBubbleKeysByDate() throws -> [String: [String]] {
        let query = "SELECT key, value FROM cursorDiskKV WHERE key LIKE 'bubbleId:%'"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(globalDB, query, -1, &stmt, nil) == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(globalDB))
            throw CursorServiceError.queryFailed(errorMsg)
        }
        defer { sqlite3_finalize(stmt) }

        var byDate: [String: [String]] = [:]

        // Byte patterns for the fast pre-filter.
        let type1Pattern = Data("\"type\":1".utf8)
        let type2Pattern = Data("\"type\":2".utf8)
        let createdAtPattern = Data("\"createdAt\":\"".utf8)
        let emptyTextPattern = Data("\"text\":\"\"".utf8)

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let keyPtr = sqlite3_column_text(stmt, 0),
                  let valuePtr = sqlite3_column_blob(stmt, 1) else { continue }
            let valueLength = Int(sqlite3_column_bytes(stmt, 1))
            let data = Data(bytes: valuePtr, count: valueLength)

            guard data.range(of: type1Pattern) != nil || data.range(of: type2Pattern) != nil else { continue }
            if data.range(of: emptyTextPattern) != nil { continue }

            guard let range = data.range(of: createdAtPattern) else { continue }
            let valueStart = range.upperBound
            // Locate the closing quote of the timestamp string. Cap at 32 bytes —
            // ISO8601 with millis ("2026-04-25T11:11:58.123Z") fits in 24.
            let scanEnd = min(valueStart + 32, data.count)
            guard let quoteIndex = data[valueStart..<scanEnd].firstIndex(of: 0x22 /* " */) else { continue }
            guard let timestampString = String(data: data[valueStart..<quoteIndex], encoding: .utf8),
                  let timestamp = DateFormatting.parseISO8601(timestampString) else { continue }

            let localDate = DateFormatting.iso.string(from: timestamp)
            let key = String(cString: keyPtr)
            byDate[localDate, default: []].append(key)
        }

        return byDate
    }

    /// Get all composers from a workspace (without date filtering)
    private nonisolated func getAllComposersFromWorkspace(dbPath: String) -> [CursorComposerInfo] {
        guard let db = openWorkspaceDB(at: dbPath) else { return [] }
        defer { sqlite3_close(db) }

        let query = "SELECT value FROM ItemTable WHERE key = 'composer.composerData'"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let valuePtr = sqlite3_column_blob(stmt, 0) else { return [] }

        let valueLength = sqlite3_column_bytes(stmt, 0)
        let data = Data(bytes: valuePtr, count: Int(valueLength))

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let allComposers = json["allComposers"] as? [[String: Any]] else {
            return []
        }

        var composers: [CursorComposerInfo] = []

        for composer in allComposers {
            guard let composerId = composer["composerId"] as? String else { continue }

            let createdAt = composer["createdAt"] as? Double ?? 0
            let lastUpdatedAt = composer["lastUpdatedAt"] as? Double ?? createdAt
            let name = composer["name"] as? String

            composers.append(CursorComposerInfo(
                composerId: composerId,
                name: name,
                subtitle: nil,
                createdAt: Date(timeIntervalSince1970: createdAt / 1000),
                lastUpdatedAt: Date(timeIntervalSince1970: lastUpdatedAt / 1000)
            ))
        }

        return composers
    }

    /// Get all unique dates from messages for a composer
    private func getMessageDatesForComposer(_ composerId: String) throws -> Set<String> {
        let query = "SELECT value FROM cursorDiskKV WHERE key LIKE ?"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(globalDB, query, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        let pattern = "bubbleId:\(composerId):%"
        sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT)

        var dates: Set<String> = []
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let valuePtr = sqlite3_column_blob(stmt, 0) else { continue }
            let valueLength = sqlite3_column_bytes(stmt, 0)
            let data = Data(bytes: valuePtr, count: Int(valueLength))

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? Int,
                  type == 1 || type == 2,
                  let createdAtStr = json["createdAt"] as? String,
                  let createdAt = isoFormatter.date(from: createdAtStr),
                  !((json["text"] as? String) ?? "").isEmpty else {
                continue
            }

            let dateString = DateFormatting.iso.string(from: createdAt)
            dates.insert(dateString)
        }

        return dates
    }

    // MARK: - Workspace-based Chat History

    /// Get all workspaces with their project paths
    private nonisolated func getAllWorkspaces() -> [(hash: String, projectPath: String, dbPath: String)] {
        var workspaces: [(String, String, String)] = []

        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: workspaceStoragePath) else {
            return []
        }

        for hash in contents {
            let workspaceDir = "\(workspaceStoragePath)/\(hash)"
            let workspaceJsonPath = "\(workspaceDir)/workspace.json"
            let stateDBPath = "\(workspaceDir)/state.vscdb"

            // Check if state.vscdb exists
            guard FileManager.default.fileExists(atPath: stateDBPath) else { continue }

            // Read workspace.json to get project path
            // Can be "folder" (local) or "workspace" (remote/multi-root)
            guard let jsonData = FileManager.default.contents(atPath: workspaceJsonPath),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            // Try "folder" first, then "workspace"
            guard let rawURL = (json["folder"] as? String) ?? (json["workspace"] as? String) else {
                continue
            }

            // Convert URL to path/name
            let projectPath: String
            if let url = URL(string: rawURL), url.isFileURL {
                projectPath = url.path
            } else if rawURL.hasPrefix("file://") {
                // Fallback for malformed file:// URLs
                let stripped = rawURL.replacingOccurrences(of: "file://localhost", with: "")
                    .replacingOccurrences(of: "file://", with: "")
                projectPath = stripped.removingPercentEncoding ?? stripped
            } else if rawURL.hasPrefix("vscode-remote://") {
                // Remote workspace: extract path from URL
                // e.g., vscode-remote://ssh-remote%2Brh1/home/udgp/UDGP.code-workspace
                if let url = URL(string: rawURL), !url.path.isEmpty {
                    projectPath = url.path
                } else {
                    projectPath = rawURL
                }
            } else {
                projectPath = rawURL
            }

            workspaces.append((hash, projectPath, stateDBPath))
        }

        return workspaces
    }

    /// Get composer sessions for a specific date from a workspace
    private nonisolated func getComposersForDate(from dbPath: String, date: Date) -> [CursorComposerInfo] {
        guard let db = openWorkspaceDB(at: dbPath) else { return [] }
        defer { sqlite3_close(db) }

        let query = "SELECT value FROM ItemTable WHERE key = 'composer.composerData'"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let valuePtr = sqlite3_column_blob(stmt, 0) else { return [] }

        let valueLength = sqlite3_column_bytes(stmt, 0)
        let data = Data(bytes: valuePtr, count: Int(valueLength))

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let allComposers = json["allComposers"] as? [[String: Any]] else {
            return []
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return [] }

        let startTs = startOfDay.timeIntervalSince1970 * 1000
        let endTs = endOfDay.timeIntervalSince1970 * 1000

        var composers: [CursorComposerInfo] = []

        for composer in allComposers {
            guard let composerId = composer["composerId"] as? String else { continue }

            // Check if composer was active on this date
            let createdAt = composer["createdAt"] as? Double ?? 0
            let lastUpdatedAt = composer["lastUpdatedAt"] as? Double ?? createdAt

            // Include if created or updated on this date
            let overlaps = (createdAt < endTs && lastUpdatedAt >= startTs)
            guard overlaps else { continue }

            let name = composer["name"] as? String
            let subtitle = composer["subtitle"] as? String

            composers.append(CursorComposerInfo(
                composerId: composerId,
                name: name,
                subtitle: subtitle,
                createdAt: Date(timeIntervalSince1970: createdAt / 1000),
                lastUpdatedAt: Date(timeIntervalSince1970: lastUpdatedAt / 1000)
            ))
        }

        return composers
    }

    /// Get messages for a composer from global DB
    private func getMessagesForComposer(_ composerId: String, date: Date) throws -> [CursorChatMessage] {
        try openGlobalDB()

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            throw CursorServiceError.invalidDate
        }

        let query = "SELECT key, value FROM cursorDiskKV WHERE key LIKE ?"
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(globalDB, query, -1, &stmt, nil) != SQLITE_OK {
            let errorMsg = String(cString: sqlite3_errmsg(globalDB))
            throw CursorServiceError.queryFailed(errorMsg)
        }
        defer { sqlite3_finalize(stmt) }

        let pattern = "bubbleId:\(composerId):%"
        sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT)

        var messages: [CursorChatMessage] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let valuePtr = sqlite3_column_blob(stmt, 1) else { continue }
            let valueLength = sqlite3_column_bytes(stmt, 1)
            let data = Data(bytes: valuePtr, count: Int(valueLength))

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            // Parse type: 1=user, 2=assistant
            guard let type = json["type"] as? Int, type == 1 || type == 2 else { continue }

            // Parse createdAt (ISO 8601 string with fractional seconds)
            var timestamp: Date?
            if let createdAtStr = json["createdAt"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                timestamp = formatter.date(from: createdAtStr)
            }

            // Skip messages without timestamp - they can't be filtered by date
            guard let ts = timestamp else { continue }
            guard ts >= startOfDay && ts < endOfDay else { continue }

            // Get text content
            let text = json["text"] as? String ?? ""

            // Skip empty messages
            guard !text.isEmpty else { continue }

            let role: MessageRole = type == 1 ? .user : .assistant
            messages.append(CursorChatMessage(role: role, content: text, timestamp: timestamp))
        }

        // Sort by timestamp
        messages.sort { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }

        return messages
    }

    /// Get all Cursor activity for a specific date, grouped by project
    func getActivityForDate(_ date: Date) async throws -> [CursorProjectActivity] {
        guard isAvailable() else { return [] }

        let startTime = CFAbsoluteTimeGetCurrent()
        let dateString = DateFormatting.iso.string(from: date)

        // Cursor 3.x stores Agent chats in global cursorDiskKV composerData/bubbleId keys.
        let globalActivities = try await getGlobalActivityForDate(date)
        if !globalActivities.isEmpty {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            let totalMessages = globalActivities.reduce(0) { $0 + $1.messages.count }
            logger.notice("getActivityForDate(\(dateString)): \(elapsed, format: .fixed(precision: 1))ms global (\(globalActivities.count) projects, \(totalMessages) messages)")
            return globalActivities
        }

        let activities = try getWorkspaceActivityForDate(date)
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        let totalMessages = activities.reduce(0) { $0 + $1.messages.count }
        logger.notice("getActivityForDate(\(dateString)): \(elapsed, format: .fixed(precision: 1))ms workspace (\(activities.count) projects, \(totalMessages) messages)")

        return activities
    }

    /// Legacy workspaceStorage-backed Cursor activity reader.
    private func getWorkspaceActivityForDate(_ date: Date) throws -> [CursorProjectActivity] {
        let workspaces = getAllWorkspaces()
        var activities: [CursorProjectActivity] = []

        for (_, projectPath, dbPath) in workspaces {
            let composers = getComposersForDate(from: dbPath, date: date)
            guard !composers.isEmpty else { continue }

            var allMessages: [CursorChatMessage] = []
            var timeRangeStart: Date = .distantFuture
            var timeRangeEnd: Date = .distantPast

            for composer in composers {
                let messages = try getMessagesForComposer(composer.composerId, date: date)
                allMessages.append(contentsOf: messages)

                // Update time range from actual message timestamps
                for msg in messages {
                    if let ts = msg.timestamp {
                        if ts < timeRangeStart { timeRangeStart = ts }
                        if ts > timeRangeEnd { timeRangeEnd = ts }
                    }
                }
            }

            guard !allMessages.isEmpty else { continue }

            // Sort all messages by timestamp
            allMessages.sort { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }

            // Extract project name from path
            let projectName = (projectPath as NSString).lastPathComponent

            activities.append(CursorProjectActivity(
                projectPath: projectPath,
                projectName: projectName,
                messages: allMessages,
                composerCount: composers.count,
                composerIds: Set(composers.map(\.composerId)),
                timeRangeStart: timeRangeStart,
                timeRangeEnd: timeRangeEnd
            ))
        }

        // Sort by first activity time
        activities.sort { $0.timeRangeStart < $1.timeRangeStart }

        return activities
    }

    /// Cursor 3.x globalStorage-backed activity reader.
    private func getGlobalActivityForDate(_ date: Date) async throws -> [CursorProjectActivity] {
        try openGlobalDB()

        let messagesByComposer = try await getGlobalMessagesByComposer(for: date)
        guard !messagesByComposer.isEmpty else { return [] }

        let composers = try getGlobalComposers(only: Set(messagesByComposer.keys))
        let composersById = Dictionary(uniqueKeysWithValues: composers.map { ($0.composerId, $0) })

        struct ProjectBucket {
            var projectName: String
            var messages: [CursorChatMessage]
            var composerIds: Set<String>
            var timeRangeStart: Date
            var timeRangeEnd: Date
        }

        var buckets: [String: ProjectBucket] = [:]

        for (composerId, bundle) in messagesByComposer {
            let composer = composersById[composerId]
            let inferredProjectPath = AgentActivityUtilities.commonAncestor(for: Array(bundle.paths))
            let projectPath = composer?.projectPath ?? inferredProjectPath ?? "Cursor/\(composerId)"
            let fallbackName = composer?.name ?? "Cursor"

            let projectName = (composer?.projectPath ?? inferredProjectPath).map {
                AgentActivityUtilities.projectName(from: $0, fallback: fallbackName)
            } ?? fallbackName

            let start = bundle.messages.compactMap(\.timestamp).min() ?? composer?.createdAt ?? .distantPast
            let end = bundle.messages.compactMap(\.timestamp).max() ?? composer?.lastUpdatedAt ?? start

            var bucket = buckets[projectPath] ?? ProjectBucket(
                projectName: projectName,
                messages: [],
                composerIds: [],
                timeRangeStart: start,
                timeRangeEnd: end
            )

            bucket.messages.append(contentsOf: bundle.messages)
            bucket.composerIds.insert(composerId)
            if start < bucket.timeRangeStart { bucket.timeRangeStart = start }
            if end > bucket.timeRangeEnd { bucket.timeRangeEnd = end }
            buckets[projectPath] = bucket
        }

        return buckets.map { projectPath, bucket in
            CursorProjectActivity(
                projectPath: projectPath,
                projectName: bucket.projectName,
                messages: bucket.messages.sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) },
                composerCount: bucket.composerIds.count,
                composerIds: bucket.composerIds,
                timeRangeStart: bucket.timeRangeStart,
                timeRangeEnd: bucket.timeRangeEnd
            )
        }
        .sorted { $0.timeRangeStart < $1.timeRangeStart }
    }

    private func getGlobalMessagesByComposer(for date: Date) async throws -> [String: GlobalCursorMessageBundle] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            throw CursorServiceError.invalidDate
        }
        let dateString = DateFormatting.iso.string(from: date)

        // Make sure the persistent date → bubbleKeys index is current.
        let dbModTime = getDBModTime()
        if await bubbleIndex.needsRebuild(currentDBModTime: dbModTime) {
            try await rebuildBubbleIndex(dbModTime: dbModTime)
        }

        guard let keys = await bubbleIndex.getKeys(for: dateString), !keys.isEmpty else {
            return [:]
        }

        return try parseBubbles(keys: keys, startOfDay: startOfDay, endOfDay: endOfDay)
    }

    /// Fetches the given bubble keys via batched `WHERE key IN (...)` queries
    /// and parses their JSON. Bounded by the cardinality of `keys`, not the DB.
    private func parseBubbles(
        keys: [String],
        startOfDay: Date,
        endOfDay: Date,
        chunkSize: Int = 500
    ) throws -> [String: GlobalCursorMessageBundle] {
        var bundles: [String: GlobalCursorMessageBundle] = [:]
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }

        for chunk in stride(from: 0, to: keys.count, by: chunkSize) {
            let end = min(chunk + chunkSize, keys.count)
            let slice = keys[chunk..<end]
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            let query = "SELECT key, value FROM cursorDiskKV WHERE key IN (\(placeholders))"

            if stmt != nil { sqlite3_finalize(stmt); stmt = nil }
            guard sqlite3_prepare_v2(globalDB, query, -1, &stmt, nil) == SQLITE_OK else {
                let errorMsg = String(cString: sqlite3_errmsg(globalDB))
                throw CursorServiceError.queryFailed(errorMsg)
            }

            for (i, key) in slice.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), key, -1, SQLITE_TRANSIENT)
            }

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let keyPtr = sqlite3_column_text(stmt, 0),
                      let valuePtr = sqlite3_column_blob(stmt, 1) else { continue }

                let key = String(cString: keyPtr)
                let keyParts = key.split(separator: ":", omittingEmptySubsequences: false)
                guard keyParts.count >= 3 else { continue }
                let composerId = String(keyParts[1])

                let valueLength = sqlite3_column_bytes(stmt, 1)
                let data = Data(bytes: valuePtr, count: Int(valueLength))

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = json["type"] as? Int,
                      type == 1 || type == 2,
                      let createdAtStr = json["createdAt"] as? String,
                      let timestamp = isoFormatter.date(from: createdAtStr),
                      timestamp >= startOfDay && timestamp < endOfDay,
                      let text = json["text"] as? String,
                      !text.isEmpty else {
                    continue
                }

                let role: MessageRole = type == 1 ? .user : .assistant
                var bundle = bundles[composerId] ?? GlobalCursorMessageBundle(messages: [], paths: [])
                bundle.messages.append(CursorChatMessage(role: role, content: text, timestamp: timestamp))
                bundle.paths.formUnion(Self.collectFileSystemPaths(from: json))
                bundles[composerId] = bundle
            }
        }

        return bundles
    }

    private func getGlobalComposers(only composerIds: Set<String>) throws -> [GlobalCursorComposerInfo] {
        let query = "SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%'"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(globalDB, query, -1, &stmt, nil) == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(globalDB))
            throw CursorServiceError.queryFailed(errorMsg)
        }
        defer { sqlite3_finalize(stmt) }

        var composers: [GlobalCursorComposerInfo] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let keyPtr = sqlite3_column_text(stmt, 0),
                  let valuePtr = sqlite3_column_blob(stmt, 1) else {
                continue
            }

            let key = String(cString: keyPtr)
            let valueLength = sqlite3_column_bytes(stmt, 1)
            let data = Data(bytes: valuePtr, count: Int(valueLength))

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let keyComposerId = key.replacingOccurrences(of: "composerData:", with: "")
            let composerId = json["composerId"] as? String ?? keyComposerId
            guard !composerId.isEmpty else { continue }
            guard composerIds.contains(composerId) else { continue }

            let createdAtMs = json["createdAt"] as? Double ?? 0
            let lastUpdatedAtMs = json["lastUpdatedAt"] as? Double ?? createdAtMs
            let name = json["name"] as? String
            let projectPath = Self.extractProjectPath(from: json)

            composers.append(GlobalCursorComposerInfo(
                composerId: composerId,
                name: name,
                projectPath: projectPath,
                createdAt: Date(timeIntervalSince1970: createdAtMs / 1000),
                lastUpdatedAt: Date(timeIntervalSince1970: lastUpdatedAtMs / 1000)
            ))
        }

        return composers
    }

    private nonisolated static func extractProjectPath(from json: [String: Any]) -> String? {
        let paths = collectFileSystemPaths(from: json)
        return AgentActivityUtilities.commonAncestor(for: paths)
    }

    private nonisolated static func collectFileSystemPaths(from value: Any) -> [String] {
        var paths: [String] = []

        func walk(_ value: Any, key: String?) {
            if let string = value as? String {
                if key == "fsPath", string.hasPrefix("/") {
                    paths.append(string)
                } else if key == "path", string.hasPrefix("/") {
                    paths.append(string)
                } else if string.hasPrefix("file://"), let url = URL(string: string), url.isFileURL {
                    paths.append(url.path)
                }
                return
            }

            if let dict = value as? [String: Any] {
                for (childKey, childValue) in dict {
                    walk(childValue, key: childKey)
                }
                return
            }

            if let array = value as? [Any] {
                for item in array {
                    walk(item, key: key)
                }
            }
        }

        walk(value, key: nil)
        return Array(Set(paths))
    }

    /// Check if there's any Cursor activity on a specific date
    func hasActivityOnDate(_ date: Date) async throws -> Bool {
        guard let stats = try await getDailyStats(for: date) else {
            return false
        }
        return stats.hasActivity
    }

}

/// Quick stats for Cursor activity
struct CursorQuickStats: Sendable {
    let projectCount: Int
    let sessionCount: Int
    let messageCount: Int
}

// MARK: - Models

/// Chat message from Cursor
struct CursorChatMessage: Sendable {
    let role: MessageRole
    let content: String
    let timestamp: Date?
}

/// Composer session info from workspace
struct CursorComposerInfo: Sendable {
    let composerId: String
    let name: String?
    let subtitle: String?
    let createdAt: Date
    let lastUpdatedAt: Date
}

/// Composer metadata from Cursor 3.x globalStorage composerData entries.
private struct GlobalCursorComposerInfo: Sendable {
    let composerId: String
    let name: String?
    let projectPath: String?
    let createdAt: Date
    let lastUpdatedAt: Date
}

private struct GlobalCursorMessageBundle: Sendable {
    var messages: [CursorChatMessage]
    var paths: Set<String>
}

/// Cursor activity for a single project on a given day
struct CursorProjectActivity: Sendable {
    let projectPath: String
    let projectName: String
    let messages: [CursorChatMessage]
    let composerCount: Int
    let composerIds: Set<String>
    let timeRangeStart: Date
    let timeRangeEnd: Date

    var timeRange: ClosedRange<Date> {
        timeRangeStart...timeRangeEnd
    }
}

// MARK: - Errors

enum CursorServiceError: LocalizedError {
    case databaseOpenFailed(String)
    case queryFailed(String)
    case invalidDate

    var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let msg):
            return "Failed to open Cursor database: \(msg)"
        case .queryFailed(let msg):
            return "Database query failed: \(msg)"
        case .invalidDate:
            return "Invalid date provided"
        }
    }
}

/// Cursor database access status
enum CursorAccessStatus: Sendable {
    case notInstalled
    case noPermission
    case accessible
}
