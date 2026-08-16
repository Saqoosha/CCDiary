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
/// After the first full build, refreshes are incremental via a rowid watermark
/// so daily mtime bumps don't re-scan a multi-GB file.
private actor CursorBubbleIndex {
    private var byDate: [String: [String]] = [:]
    private var isLoaded = false
    /// True once `setIndex`/`mergeIndex` has run for the current `lastDBModTime`.
    /// Lets us distinguish "no Cursor activity ever" (zero bubbles, no rebuild
    /// needed) from "cache empty because we haven't built yet" (rebuild required).
    private var hasBuilt = false
    private var lastDBModTime: TimeInterval = 0
    /// Highest `cursorDiskKV.rowid` incorporated into `byDate`. Incremental
    /// refreshes only scan rows at or above this watermark (`rowid >=`).
    private var maxRowid: Int64 = 0
    /// Unfiltered `COUNT(*)` of `bubbleId:%` rows at last scan time — not the
    /// indexed-key count (the byte pre-filter drops most non-message bubbles).
    /// Used to detect net deletions that leave the max-rowid watermark unchanged.
    private var dbBubbleRowCount: Int = 0

    private static var cacheFileURL: URL {
        let fileManager = FileManager.default
        let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let cacheDir = cachesDir.appendingPathComponent("CCDiary")

        // Remove the legacy lowercase cache directory — but only when it is
        // truly a separate directory. On case-insensitive APFS (the default)
        // "ccdiary" resolves to "CCDiary" itself, and deleting it would nuke
        // every cache (date index, statistics) on every single run.
        let legacyDir = cachesDir.appendingPathComponent("ccdiary")
        if let legacyCanonical = try? legacyDir.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath,
           legacyCanonical != ((try? cacheDir.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? cacheDir.path) {
            try? fileManager.removeItem(at: legacyDir)
        }

        try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir.appendingPathComponent("cursor_bubble_index_v4.json")
    }

    /// Old v0 cache file. Removed on first load if present.
    private static var legacyCacheFileURL: URL {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cachesDir.appendingPathComponent("CCDiary/cursor_dates.json")
    }

    /// Pre-watermark (v1) cache. Removed on first load so it does not linger
    /// next to the live file forever.
    private static var legacyV1CacheFileURL: URL {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cachesDir.appendingPathComponent("CCDiary/cursor_bubble_index_v1.json")
    }

    /// Watermark-only (v2) cache — superseded by the count-gated refresh.
    private static var legacyV2CacheFileURL: URL {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cachesDir.appendingPathComponent("CCDiary/cursor_bubble_index_v2.json")
    }

    /// v3 carried a DB-identity full-rescan trigger that could not fire on
    /// mtime-preserving restores and misfired across APFS reboots — dropped
    /// in v4. Removed on first load so it does not linger next to v4.
    private static var legacyV3CacheFileURL: URL {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cachesDir.appendingPathComponent("CCDiary/cursor_bubble_index_v3.json")
    }

    func getDates() -> Set<String> {
        ensureLoaded()
        return Set(byDate.keys)
    }

    func getKeys(for date: String) -> [String]? {
        ensureLoaded()
        return byDate[date]
    }

    /// Rowid watermark for incremental scans. Purely a watermark — "never
    /// built" is tracked by `hasBuiltIndex()`, not by `maxRowid == 0`.
    func currentMaxRowid() -> Int64 {
        ensureLoaded()
        return maxRowid
    }

    /// Whether the index has been built at least once (disk load or scan).
    /// Distinct from `maxRowid == 0`, which is legitimate when Cursor has
    /// zero `bubbleId:%` rows.
    func hasBuiltIndex() -> Bool {
        ensureLoaded()
        return hasBuilt
    }

    func currentDbBubbleRowCount() -> Int {
        ensureLoaded()
        return dbBubbleRowCount
    }

    func setIndex(
        _ newIndex: [String: [String]],
        dbModTime: TimeInterval,
        maxRowid: Int64,
        dbBubbleRowCount: Int
    ) {
        byDate = newIndex
        lastDBModTime = dbModTime
        self.maxRowid = maxRowid
        self.dbBubbleRowCount = dbBubbleRowCount
        isLoaded = true
        hasBuilt = true
        saveToDisk()
    }

    /// Appends newly-scanned keys onto the existing per-date arrays without
    /// dropping older entries. De-duplicates with a Set per date — load-bearing
    /// because REPLACE rewrites re-enter above the watermark with a **new**
    /// rowid on every fill-in, so the incremental scan routinely re-lists
    /// thousands of already-indexed keys each refresh.
    func mergeIndex(
        _ delta: [String: [String]],
        dbModTime: TimeInterval,
        maxRowid: Int64,
        dbBubbleRowCount: Int
    ) {
        for (date, keys) in delta {
            var seen = Set(byDate[date] ?? [])
            for key in keys where seen.insert(key).inserted {
                byDate[date, default: []].append(key)
            }
        }
        lastDBModTime = dbModTime
        self.maxRowid = maxRowid
        self.dbBubbleRowCount = dbBubbleRowCount
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
        // Drop superseded cache files so they don't linger next to v4.
        try? FileManager.default.removeItem(at: Self.legacyCacheFileURL)
        try? FileManager.default.removeItem(at: Self.legacyV1CacheFileURL)
        try? FileManager.default.removeItem(at: Self.legacyV2CacheFileURL)
        try? FileManager.default.removeItem(at: Self.legacyV3CacheFileURL)
    }

    private func loadFromDisk() {
        let url = Self.cacheFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)
            let stored = try JSONDecoder().decode(StoredCursorBubbleIndex.self, from: data)
            byDate = stored.byDate
            lastDBModTime = stored.dbModTime
            maxRowid = stored.maxRowid
            dbBubbleRowCount = stored.dbBubbleRowCount
            hasBuilt = true
            let bubbleCount = byDate.values.reduce(0) { $0 + $1.count }
            // logger.notice (not .info) — index load status should survive
            // log rotation so post-hoc debugging can confirm cache was used.
            logger.notice("Loaded Cursor bubble index: \(self.byDate.count) dates, \(bubbleCount) bubbles (maxRowid=\(self.maxRowid))")
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
        let stored = StoredCursorBubbleIndex(
            byDate: byDate,
            dbModTime: lastDBModTime,
            maxRowid: maxRowid,
            dbBubbleRowCount: dbBubbleRowCount
        )
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
        let maxRowid: Int64
        let dbBubbleRowCount: Int
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

        // Rebuild/refresh cache from database (full or incremental via rowid watermark)
        try await refreshBubbleIndex(dbModTime: dbModTime)
        return await bubbleIndex.getDates()
    }

    /// Refresh the bubble index when the DB mtime changes.
    ///
    /// Rewrites re-enter **above** the watermark with a fresh rowid
    /// (`UNIQUE ON CONFLICT REPLACE` deletes then inserts at a new higher
    /// rowid), which is what makes the incremental scan safe. The per-date
    /// `Set` dedupe in `mergeIndex` is therefore load-bearing — thousands of
    /// rewritten bubbles reappear in each refresh. The index derives the date
    /// from `createdAt` **and** membership from the byte pre-filter
    /// (`"type":1`/`"type":2` present, `"text":""` absent). Most excluded
    /// rows are permanently empty tool/thinking bubbles; a genuine message
    /// fill-in re-enters above the watermark via REPLACE.
    ///
    /// Residual: a deletion exactly compensated by an equal or greater number
    /// of new rows between two runs leaves the count non-decreasing, so that
    /// specific interleaving is still missed until the next net deletion or
    /// rowid regression. Do not attempt to close it.
    private func refreshBubbleIndex(dbModTime: TimeInterval) async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        try openGlobalDB()

        let workspaces = getAllWorkspaces()
        logger.notice("refreshBubbleIndex: \(workspaces.count) workspaces found")

        let hasBuilt = await bubbleIndex.hasBuiltIndex()
        let storedMaxRowid = await bubbleIndex.currentMaxRowid()
        let storedCount = await bubbleIndex.currentDbBubbleRowCount()
        let dbMaxRowid = try maxBubbleRowid()
        let currentCount = try countBubbleRows()

        // Full rescan triggers (any one forces a rebuild):
        // 1. never built  2. rowids went backwards  3. net deletion of bubbleId:% rows
        let needsFullScan: Bool
        let fullScanReason: String
        if !hasBuilt {
            needsFullScan = true
            fullScanReason = "never built"
        } else if dbMaxRowid < storedMaxRowid {
            needsFullScan = true
            fullScanReason = "rowid went backwards (\(dbMaxRowid) < \(storedMaxRowid))"
        } else if currentCount < storedCount {
            needsFullScan = true
            fullScanReason = "bubble row count decreased (\(currentCount) < \(storedCount))"
        } else {
            needsFullScan = false
            fullScanReason = ""
        }

        if needsFullScan {
            // `.public` — the reason is a fixed diagnostic string, and os_log
            // redacts interpolated values by default, which would render this
            // as "full rescan: <private>" and defeat the whole log line.
            logger.notice("Cursor bubble index full rescan: \(fullScanReason, privacy: .public)")
            let collected = try collectBubbleKeysByDate(sinceRowid: 0)
            await bubbleIndex.setIndex(
                collected.byDate,
                dbModTime: dbModTime,
                maxRowid: collected.maxRowid,
                dbBubbleRowCount: currentCount
            )
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            let bubbleCount = collected.byDate.values.reduce(0) { $0 + $1.count }
            logger.notice("Built Cursor bubble index (full): \(collected.byDate.count) dates, \(bubbleCount) bubbles, scanned to rowid \(collected.maxRowid) in \(elapsed, format: .fixed(precision: 1))ms")
        } else {
            let collected = try collectBubbleKeysByDate(sinceRowid: storedMaxRowid)
            await bubbleIndex.mergeIndex(
                collected.byDate,
                dbModTime: dbModTime,
                maxRowid: collected.maxRowid,
                dbBubbleRowCount: currentCount
            )
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            let deltaCount = collected.byDate.values.reduce(0) { $0 + $1.count }
            logger.notice("Refreshed Cursor bubble index (incremental): +\(deltaCount) bubbles since rowid \(storedMaxRowid) → \(collected.maxRowid) in \(elapsed, format: .fixed(precision: 1))ms")
        }
    }

    /// Cheap watermark probe — `MAX(rowid)` over bubble keys only. Used to
    /// decide full vs incremental without touching value blobs.
    private func maxBubbleRowid() throws -> Int64 {
        let query = "SELECT MAX(rowid) FROM cursorDiskKV WHERE key LIKE 'bubbleId:%'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(globalDB, query, -1, &stmt, nil) == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(globalDB))
            throw CursorServiceError.queryFailed(errorMsg)
        }
        defer { sqlite3_finalize(stmt) }
        // Returning 0 on a non-ROW step only forces a full scan when
        // `storedMaxRowid > 0` (the `dbMaxRowid < storedMaxRowid` branch).
        // Log the errmsg so a surprising 0 is still explainable.
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            let errorMsg = String(cString: sqlite3_errmsg(globalDB))
            logger.warning("maxBubbleRowid step failed (\(errorMsg, privacy: .public)) — treating as 0")
            return 0
        }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Unfiltered `COUNT(*)` of `bubbleId:%` rows. Affordable on every refresh
    /// (~25 ms on a 3.4 GB DB, measured 2026-08-16); used to detect net
    /// deletions that leave the max-rowid watermark unchanged.
    private func countBubbleRows() throws -> Int {
        let query = "SELECT COUNT(*) FROM cursorDiskKV WHERE key LIKE 'bubbleId:%'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(globalDB, query, -1, &stmt, nil) == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(globalDB))
            throw CursorServiceError.queryFailed(errorMsg)
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            let errorMsg = String(cString: sqlite3_errmsg(globalDB))
            throw CursorServiceError.queryFailed(errorMsg)
        }
        return Int(sqlite3_column_int64(stmt, 0))
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
    /// Reads `rowid`, `key`, and `value` together so we never have to revisit
    /// blobs. JSON parsing is deferred to `parseBubbles(...)` — that runs only
    /// on the small subset of bubbles for the queried date.
    ///
    /// Pass `sinceRowid: 0` for a full scan; otherwise only rows with
    /// `rowid >= sinceRowid` are visited. The `>=` (not `>`) is deliberate
    /// overlap covering rowid reuse at exactly the watermark — not an
    /// off-by-one. The per-date `Set` dedupe in `mergeIndex` absorbs the one
    /// redundant row. Returns the largest rowid actually seen so the caller
    /// can advance the watermark.
    ///
    /// Throwing on a non-`SQLITE_DONE` termination is deliberate: it reaches
    /// `runWithTimeout`'s generic failure branch, which marks Cursor
    /// incomplete, instead of silently persisting a truncated index and
    /// advancing the watermark past unread rows.
    ///
    /// Date keys are in **the user's local time zone**, matching how
    /// `getGlobalMessagesByComposer(for:)` resolves the requested date via
    /// `Calendar.current.startOfDay(for:)`. Naively prefixing the ISO
    /// `createdAt` (which is always UTC `Z`) would split bubbles created
    /// between 00:00 and the local UTC offset onto the wrong day.
    private func collectBubbleKeysByDate(sinceRowid: Int64) throws -> (byDate: [String: [String]], maxRowid: Int64) {
        let query = "SELECT rowid, key, value FROM cursorDiskKV WHERE key LIKE 'bubbleId:%' AND rowid >= ? ORDER BY rowid"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(globalDB, query, -1, &stmt, nil) == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(globalDB))
            throw CursorServiceError.queryFailed(errorMsg)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, sinceRowid)

        var byDate: [String: [String]] = [:]
        var maxRowid = sinceRowid

        // Byte patterns for the fast pre-filter.
        let type1Pattern = Data("\"type\":1".utf8)
        let type2Pattern = Data("\"type\":2".utf8)
        let createdAtPattern = Data("\"createdAt\":\"".utf8)
        let emptyTextPattern = Data("\"text\":\"\"".utf8)

        // `defer` advances the cursor on every exit from the body, including the
        // six `continue`s below. Hand-written `sqlite3_step` calls before each
        // one would be a silent infinite loop the day a seventh filter is added.
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            defer { stepResult = sqlite3_step(stmt) }

            let rowid = sqlite3_column_int64(stmt, 0)
            if rowid > maxRowid { maxRowid = rowid }

            guard let keyPtr = sqlite3_column_text(stmt, 1),
                  let valuePtr = sqlite3_column_blob(stmt, 2) else { continue }
            let valueLength = Int(sqlite3_column_bytes(stmt, 2))
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
        guard stepResult == SQLITE_DONE else {
            let errmsg = String(cString: sqlite3_errmsg(globalDB))
            throw CursorServiceError.queryFailed("sqlite3_step returned \(stepResult): \(errmsg)")
        }

        return (byDate, maxRowid)
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
            try await refreshBubbleIndex(dbModTime: dbModTime)
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
