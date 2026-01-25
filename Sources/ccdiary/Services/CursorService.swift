import Foundation
import SQLite3
import os.log

private let logger = Logger(subsystem: "ccdiary", category: "CursorService")

// SQLITE_TRANSIENT tells SQLite to copy the string immediately
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Cache for Cursor dates with actual messages
private actor CursorDateCache {
    private var dates: Set<String> = []
    private var isLoaded = false
    private var lastDBModTime: TimeInterval = 0

    private static var cacheFileURL: URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ccdiary")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir.appendingPathComponent("cursor_dates.json")
    }

    func getDates() -> Set<String> {
        return dates
    }

    func setDates(_ newDates: Set<String>, dbModTime: TimeInterval) {
        dates = newDates
        lastDBModTime = dbModTime
        saveToDisk()
    }

    func needsRebuild(currentDBModTime: TimeInterval) -> Bool {
        ensureLoaded()
        return currentDBModTime != lastDBModTime
    }

    private func ensureLoaded() {
        guard !isLoaded else { return }
        loadFromDisk()
        isLoaded = true
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: Self.cacheFileURL),
              let stored = try? JSONDecoder().decode(StoredCursorDateCache.self, from: data) else {
            return
        }
        dates = Set(stored.dates)
        lastDBModTime = stored.dbModTime
        logger.info("Loaded Cursor date cache: \(self.dates.count) dates")
    }

    private func saveToDisk() {
        let stored = StoredCursorDateCache(dates: Array(dates), dbModTime: lastDBModTime)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: Self.cacheFileURL)
    }

    private struct StoredCursorDateCache: Codable {
        let dates: [String]
        let dbModTime: TimeInterval
    }
}

/// Service for reading Cursor activity data from SQLite database
actor CursorService {
    private let globalDBPath: String
    private let workspaceStoragePath: String
    private var globalDB: OpaquePointer?
    private let dateCache = CursorDateCache()

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
        return await dateCache.getDates()
    }

    /// Build date index if needed (call at app startup)
    func buildDateIndexIfNeeded() async throws -> Set<String> {
        guard isAvailable() else {
            return []
        }

        // Check if cache needs rebuild
        let dbModTime = getDBModTime()
        if await !dateCache.needsRebuild(currentDBModTime: dbModTime) {
            logger.notice("Cursor date index up-to-date")
            return await dateCache.getDates()
        }

        // Rebuild cache from database
        let dates = try await buildDateIndex()
        await dateCache.setDates(dates, dbModTime: dbModTime)

        return dates
    }

    /// Get database modification time
    private nonisolated func getDBModTime() -> TimeInterval {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: globalDBPath),
              let modDate = attrs[.modificationDate] as? Date else {
            return 0
        }
        return modDate.timeIntervalSince1970
    }

    /// Build date index from workspace composers (same logic as getActivityForDate)
    private func buildDateIndex() async throws -> Set<String> {
        let startTime = CFAbsoluteTimeGetCurrent()

        try openGlobalDB()

        let workspaces = getAllWorkspaces()
        logger.notice("buildDateIndex: \(workspaces.count) workspaces found")

        // Step 1: Get all composers from all workspaces in parallel
        var checkpoint = CFAbsoluteTimeGetCurrent()
        let allComposers = await withTaskGroup(of: [String].self) { group in
            for (_, _, dbPath) in workspaces {
                group.addTask {
                    let composers = self.getAllComposersFromWorkspace(dbPath: dbPath)
                    return composers.map { $0.composerId }
                }
            }

            var results: [String] = []
            for await composerIds in group {
                results.append(contentsOf: composerIds)
            }
            return results
        }
        logger.notice("  workspace scan: \((CFAbsoluteTimeGetCurrent() - checkpoint) * 1000, format: .fixed(precision: 1))ms (\(allComposers.count) composers)")
        checkpoint = CFAbsoluteTimeGetCurrent()

        // Step 2: Get all message dates in a single query (much faster than per-composer queries)
        let dates = try getAllMessageDates()
        logger.notice("  message dates: \((CFAbsoluteTimeGetCurrent() - checkpoint) * 1000, format: .fixed(precision: 1))ms")

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger.notice("Built Cursor date index: \(dates.count) dates in \(elapsed, format: .fixed(precision: 1))ms")

        return dates
    }

    /// Get all unique dates from ALL messages in globalDB (single efficient query)
    private func getAllMessageDates() throws -> Set<String> {
        let query = "SELECT value FROM cursorDiskKV WHERE key LIKE 'bubbleId:%'"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(globalDB, query, -1, &stmt, nil) == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(globalDB))
            throw CursorServiceError.queryFailed(errorMsg)
        }
        defer { sqlite3_finalize(stmt) }

        var dates: Set<String> = []
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let valuePtr = sqlite3_column_blob(stmt, 0) else { continue }
            let valueLength = sqlite3_column_bytes(stmt, 0)
            let data = Data(bytes: valuePtr, count: Int(valueLength))

            // Fast path: try to extract just createdAt without full JSON parsing
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
                timeRangeStart: timeRangeStart,
                timeRangeEnd: timeRangeEnd
            ))
        }

        // Sort by first activity time
        activities.sort { $0.timeRangeStart < $1.timeRangeStart }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        let totalMessages = activities.reduce(0) { $0 + $1.messages.count }
        logger.notice("getActivityForDate(\(dateString)): \(elapsed, format: .fixed(precision: 1))ms (\(activities.count) projects, \(totalMessages) messages)")

        return activities
    }

    /// Check if there's any Cursor activity on a specific date
    func hasActivityOnDate(_ date: Date) async throws -> Bool {
        guard let stats = try await getDailyStats(for: date) else {
            return false
        }
        return stats.hasActivity
    }

    /// Get quick stats for a date (project count, session count, message count)
    func getQuickStatsForDate(_ date: Date) async throws -> CursorQuickStats {
        guard isAvailable() else {
            return CursorQuickStats(projectCount: 0, sessionCount: 0, messageCount: 0)
        }

        let activities = try await getActivityForDate(date)

        let projectCount = activities.count
        let sessionCount = activities.reduce(0) { $0 + $1.composerCount }
        let messageCount = activities.reduce(0) { $0 + $1.messages.count }

        return CursorQuickStats(
            projectCount: projectCount,
            sessionCount: sessionCount,
            messageCount: messageCount
        )
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

/// Cursor activity for a single project on a given day
struct CursorProjectActivity: Sendable {
    let projectPath: String
    let projectName: String
    let messages: [CursorChatMessage]
    let composerCount: Int
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
