import Foundation
import os.log

private let logger = Logger(subsystem: "ccdiary", category: "ConversationService")



/// Date-to-files index for fast lookups
/// Maps date strings (YYYY-MM-DD) to list of file paths containing that date
private actor DateIndex {
    // dateString -> [filePaths]
    private var dateToFiles: [String: Set<String>] = [:]
    // filePath -> modTime (for invalidation)
    private var fileModTimes: [String: TimeInterval] = [:]
    // filePath -> set of dates it contains
    private var fileToDates: [String: Set<String>] = [:]

    private var isDirty = false
    private var isLoaded = false

    private static var cacheFileURL: URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ccdiary")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir.appendingPathComponent("date_index_v2.json")
    }

    /// Get files that contain entries for a specific date
    func getFiles(for dateString: String) -> Set<String>? {
        ensureLoaded()
        return dateToFiles[dateString]
    }

    /// Get all dates that have conversation data
    func getAllDates() -> Set<String> {
        ensureLoaded()
        return Set(dateToFiles.keys)
    }

    /// Check if a file is indexed and up-to-date
    func isFileIndexed(_ path: String, modTime: TimeInterval) -> Bool {
        ensureLoaded()
        guard let cachedModTime = fileModTimes[path] else { return false }
        return cachedModTime == modTime
    }

    /// Index a file's dates
    func indexFile(_ path: String, modTime: TimeInterval, dates: Set<String>) {
        ensureLoaded()

        // Remove old entries if file was previously indexed
        if let oldDates = fileToDates[path] {
            for date in oldDates {
                dateToFiles[date]?.remove(path)
            }
        }

        // Add new entries
        fileToDates[path] = dates
        fileModTimes[path] = modTime
        for date in dates {
            dateToFiles[date, default: []].insert(path)
        }
        isDirty = true
    }

    func saveToDiskIfNeeded() {
        guard isDirty else { return }
        saveToDisk()
        isDirty = false
    }

    private func ensureLoaded() {
        if !isLoaded {
            loadFromDisk()
            isLoaded = true
        }
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: Self.cacheFileURL.path),
              let data = try? Data(contentsOf: Self.cacheFileURL),
              let stored = try? JSONDecoder().decode(StoredDateIndex.self, from: data) else {
            return
        }

        // Rebuild dateToFiles from stored data
        for entry in stored.files {
            fileToDates[entry.path] = Set(entry.dates)
            fileModTimes[entry.path] = entry.modTime
            for date in entry.dates {
                dateToFiles[date, default: []].insert(entry.path)
            }
        }
        let dateCount = self.dateToFiles.count
        logger.info("Loaded date index: \(stored.files.count) files, \(dateCount) dates")
    }

    private func saveToDisk() {
        var files: [StoredFileEntry] = []
        for (path, dates) in fileToDates {
            if let modTime = fileModTimes[path] {
                files.append(StoredFileEntry(
                    path: path,
                    modTime: modTime,
                    dates: Array(dates)
                ))
            }
        }
        let stored = StoredDateIndex(files: files)
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: Self.cacheFileURL)
            logger.info("Saved date index: \(files.count) files")
        }
    }

    private struct StoredDateIndex: Codable {
        let files: [StoredFileEntry]
    }

    private struct StoredFileEntry: Codable {
        let path: String
        let modTime: TimeInterval
        let dates: [String]
    }
}

/// Service for reading Claude Code conversation files
actor ConversationService {
    private let projectsPath: URL
    private let dateIndex = DateIndex()

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.projectsPath = home.appendingPathComponent(".claude/projects")
    }

    /// Get all dates that have actual conversation data
    /// Note: Call buildFullDateIndex() at app startup first
    func getAllDatesWithConversations() async -> Set<String> {
        await dateIndex.getAllDates()
    }

    /// Get files for a specific date from pre-built index
    /// Note: Call buildFullDateIndex() at app startup first
    func getFilesForDate(_ dateString: String, projectFiles: [URL]) async -> [URL] {
        // Get files for the target date from index
        guard let filePaths = await dateIndex.getFiles(for: dateString) else {
            return []
        }

        // Filter to only files in our projectFiles list
        let projectFilePaths = Set(projectFiles.map { $0.path })
        let matchingPaths = filePaths.intersection(projectFilePaths)

        return matchingPaths.compactMap { URL(fileURLWithPath: $0) }
    }

    /// Extract all unique dates from a file (YYYY-MM-DD format)
    private static func extractDatesFromFile(_ fileURL: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        var dates: Set<String> = []
        let pattern = "\"timestamp\":\""

        var searchStart = text.startIndex
        while let range = text.range(of: pattern, range: searchStart..<text.endIndex) {
            let dateStart = range.upperBound
            if let dateEnd = text.index(dateStart, offsetBy: 10, limitedBy: text.endIndex) {
                let dateStr = String(text[dateStart..<dateEnd])
                // Validate it looks like a date (YYYY-MM-DD)
                if dateStr.count == 10 && dateStr[dateStr.index(dateStr.startIndex, offsetBy: 4)] == "-" {
                    dates.insert(dateStr)
                }
            }
            searchStart = range.upperBound
        }

        return dates
    }

    /// Save index to disk
    func saveDateIndex() async {
        await dateIndex.saveToDiskIfNeeded()
    }

    /// Build full date index for all projects (call at app startup)
    func buildFullDateIndex() async {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Find all project directories
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsPath,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        // Collect all jsonl files
        var allFiles: [URL] = []
        for dir in projectDirs where dir.hasDirectoryPath {
            if let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) {
                allFiles.append(contentsOf: files.filter { $0.pathExtension == "jsonl" })
            }
        }

        // Check which files need indexing
        var filesToIndex: [(URL, TimeInterval)] = []
        for file in allFiles {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let modDate = attrs[.modificationDate] as? Date else {
                continue
            }
            let modTime = modDate.timeIntervalSince1970
            if await !dateIndex.isFileIndexed(file.path, modTime: modTime) {
                filesToIndex.append((file, modTime))
            }
        }

        if filesToIndex.isEmpty {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            logger.info("Date index up-to-date: \(allFiles.count) files checked in \(elapsed, format: .fixed(precision: 1))ms")
            return
        }

        // Index files in parallel
        await withTaskGroup(of: (String, TimeInterval, Set<String>)?.self) { group in
            for (file, modTime) in filesToIndex {
                group.addTask {
                    let dates = Self.extractDatesFromFile(file)
                    return (file.path, modTime, dates)
                }
            }

            for await result in group {
                if let (path, modTime, dates) = result {
                    await dateIndex.indexFile(path, modTime: modTime, dates: dates)
                }
            }
        }

        await dateIndex.saveToDiskIfNeeded()

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger.info("Built date index: \(filesToIndex.count) files indexed in \(elapsed, format: .fixed(precision: 1))ms")
    }

    /// Encode project path to directory name
    /// /Users/hiko/Desktop/myproject -> -Users-hiko-Desktop-myproject
    static func encodeProjectPath(_ projectPath: String) -> String {
        projectPath.replacingOccurrences(of: "/", with: "-")
                   .replacingOccurrences(of: ".", with: "-")
    }

    /// Find all conversation files for a project
    func findConversationFiles(projectPath: String) async throws -> [URL] {
        let encodedPath = Self.encodeProjectPath(projectPath)
        let projectDir = projectsPath.appendingPathComponent(encodedPath)

        guard FileManager.default.fileExists(atPath: projectDir.path) else {
            return []
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: projectDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )

        return contents.filter { $0.pathExtension == "jsonl" }
    }

    /// Read conversation entries from a file
    func readConversation(from fileURL: URL) async throws -> [ConversationEntry] {
        let result = try await readConversationWithResult(from: fileURL)
        return result.entries
    }

    /// Read conversation entries with parse result tracking
    func readConversationWithResult(from fileURL: URL) async throws -> ParseResult<ConversationEntry> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ParseResult(entries: [])
        }

        let data = try Data(contentsOf: fileURL)
        guard let text = String(data: data, encoding: .utf8) else {
            return ParseResult(entries: [])
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let decoder = JSONDecoder()

        var entries: [ConversationEntry] = []
        var errors: [String] = []
        var skippedCount = 0

        for (index, line) in lines.enumerated() {
            guard let lineData = line.data(using: .utf8) else {
                skippedCount += 1
                continue
            }
            do {
                let entry = try decoder.decode(ConversationEntry.self, from: lineData)
                entries.append(entry)
            } catch {
                skippedCount += 1
                let errorMsg = "Line \(index + 1): \(error.localizedDescription)"
                errors.append(errorMsg)
                // Log only first few errors to avoid spam
                if errors.count <= 3 {
                    logger.debug("Parse error in \(fileURL.lastPathComponent): \(errorMsg)")
                }
            }
        }

        if skippedCount > 0 {
            logger.info("Parsed \(fileURL.lastPathComponent): \(entries.count) entries, \(skippedCount) skipped")
        }

        return ParseResult(entries: entries, skippedCount: skippedCount, errors: errors)
    }

    /// Optimized: Read only entries within a specific date range
    /// Uses bulk read with fast date filtering
    /// Note: Caller should use getFilesForDate first to filter files
    func readConversationForDateRange(
        from fileURL: URL,
        start: Date,
        end: Date
    ) async throws -> [ConversationEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let datePrefix = DateFormatting.iso.string(from: start)

        // Get file size to decide strategy
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attrs[.size] as? UInt64 else {
            return []
        }

        // For large files (>10MB), use binary search approach
        if fileSize > 10_000_000 {
            return Self.readEntriesFromLargeFile(fileURL, datePrefix: datePrefix, fileSize: fileSize)
        }

        // For smaller files, use optimized full scan
        return Self.readEntriesFromSmallFile(fileURL, datePrefix: datePrefix)
    }

    /// Read entries from small files (<10MB) with lightweight decoding
    private nonisolated static func readEntriesFromSmallFile(
        _ fileURL: URL,
        datePrefix: String
    ) -> [ConversationEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        // Quick check: if the date string doesn't appear anywhere in the file, skip it
        if !text.contains(datePrefix) {
            return []
        }

        let decoder = JSONDecoder()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)

        var entries: [ConversationEntry] = []
        for line in lines {
            guard lineMatchesDate(String(line), datePrefix: datePrefix) else { continue }
            let lineData = Data(line.utf8)
            // Use lightweight decoder
            if let light = try? decoder.decode(LightEntry.self, from: lineData),
               let entry = light.toConversationEntry() {
                entries.append(entry)
            }
        }

        return entries
    }

    /// Read entries from large files (>10MB) with binary search
    private nonisolated static func readEntriesFromLargeFile(
        _ fileURL: URL,
        datePrefix: String,
        fileSize: UInt64
    ) -> [ConversationEntry] {
        let startTime = CFAbsoluteTimeGetCurrent()

        guard let fileHandle = FileHandle(forReadingAtPath: fileURL.path) else {
            return []
        }
        defer { try? fileHandle.close() }

        // Binary search to find approximate start of target date
        let startOffset = binarySearchForDate(fileHandle: fileHandle, datePrefix: datePrefix, fileSize: fileSize)

        // Seek to found position with safety margin
        let safeStart = startOffset > 500_000 ? startOffset - 500_000 : 0
        try? fileHandle.seek(toOffset: safeStart)

        let decoder = JSONDecoder()
        var entries: [ConversationEntry] = []

        // Read in chunks from the found position
        let chunkSize = 4 * 1024 * 1024 // 4MB chunks
        var buffer = Data()
        var foundAnyMatch = false
        var noMatchChunks = 0
        let maxNoMatchChunks = 3

        while true {
            guard let chunk = try? fileHandle.read(upToCount: chunkSize) else { break }
            if chunk.isEmpty { break }

            buffer.append(chunk)

            guard let text = String(data: buffer, encoding: .utf8) else {
                buffer = Data()
                continue
            }

            let chunkHasDate = text.contains(datePrefix)

            if !chunkHasDate {
                if foundAnyMatch {
                    noMatchChunks += 1
                    if noMatchChunks >= maxNoMatchChunks {
                        break
                    }
                }
                if let lastNewline = text.lastIndex(of: "\n") {
                    let afterNewline = text.index(after: lastNewline)
                    buffer = Data(text[afterNewline...].utf8)
                } else {
                    buffer = Data()
                }
                continue
            }

            noMatchChunks = 0

            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            let completeLineCount = text.hasSuffix("\n") ? lines.count : max(0, lines.count - 1)

            for i in 0..<completeLineCount {
                let line = String(lines[i])

                if lineMatchesDate(line, datePrefix: datePrefix) {
                    foundAnyMatch = true
                    let lineData = Data(line.utf8)
                    if let light = try? decoder.decode(LightEntry.self, from: lineData),
                       let entry = light.toConversationEntry() {
                        entries.append(entry)
                    }
                }
            }

            if completeLineCount < lines.count {
                buffer = Data(String(lines[completeLineCount]).utf8)
            } else {
                buffer = Data()
            }
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        let fileSizeMB = Double(fileSize) / 1_000_000.0
        logger.notice("    entries(binary): \(elapsed, format: .fixed(precision: 1))ms, \(fileSizeMB, format: .fixed(precision: 2))MB, \(entries.count) entries - \(fileURL.lastPathComponent)")

        return entries
    }

    /// Save date cache to disk (call periodically or on app termination)
    func saveDateCache() async {
        await dateIndex.saveToDiskIfNeeded()
    }

    /// Lightweight entry for conversation content - faster than full ConversationEntry
    private struct LightEntry: Decodable {
        let type: String
        let message: LightMessage?
        let timestamp: String
        let isMeta: Bool?

        struct LightMessage: Decodable {
            let role: String
            let content: LightContent

            enum LightContent: Decodable {
                case string(String)
                case blocks([LightBlock])

                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let str = try? container.decode(String.self) {
                        self = .string(str)
                    } else if let blocks = try? container.decode([LightBlock].self) {
                        self = .blocks(blocks)
                    } else {
                        self = .string("")
                    }
                }

                var textContent: String? {
                    switch self {
                    case .string(let str):
                        return str.isEmpty ? nil : str
                    case .blocks(let blocks):
                        let texts = blocks.compactMap { $0.text }
                        return texts.isEmpty ? nil : texts.joined(separator: "\n")
                    }
                }
            }

            struct LightBlock: Decodable {
                let type: String?
                let text: String?
            }
        }

        var isValid: Bool {
            guard type == "user" || type == "assistant" else { return false }
            guard isMeta != true else { return false }
            guard message?.content.textContent != nil else { return false }
            return true
        }

        func toConversationEntry() -> ConversationEntry? {
            guard isValid else { return nil }
            guard let msg = message, let text = msg.content.textContent else { return nil }

            let role: MessageRole = msg.role == "user" ? .user : .assistant
            let content = MessageContent.string(text)
            let entryType: ConversationEntryType = msg.role == "user" ? .user : .assistant

            return ConversationEntry(
                type: entryType,
                message: Message(role: role, content: content),
                timestamp: timestamp,
                sessionId: nil,
                uuid: nil,
                parentUuid: nil,
                isSidechain: nil,
                isMeta: isMeta,
                cwd: nil,
                version: nil
            )
        }
    }

    /// Lightweight entry for statistics - only decodes required fields
    private struct StatsEntry: Decodable {
        let type: String
        let message: StatsMessage?
        let isMeta: Bool?

        struct StatsMessage: Decodable {
            let role: String
            let content: StatsContent

            enum StatsContent: Decodable {
                case string(String)
                case blocks([StatsBlock])

                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let str = try? container.decode(String.self) {
                        self = .string(str)
                    } else if let blocks = try? container.decode([StatsBlock].self) {
                        self = .blocks(blocks)
                    } else {
                        self = .string("")
                    }
                }

                var textLength: Int {
                    switch self {
                    case .string(let str): return str.count
                    case .blocks(let blocks):
                        return blocks.reduce(0) { $0 + ($1.text?.count ?? 0) }
                    }
                }
            }

            struct StatsBlock: Decodable {
                let type: String?
                let text: String?
            }
        }

        var isValidForStats: Bool {
            guard type == "user" || type == "assistant" else { return false }
            guard isMeta != true else { return false }
            guard let msg = message else { return false }
            return msg.content.textLength > 0
        }

        var textLength: Int {
            message?.content.textLength ?? 0
        }
    }

    /// Fast statistics reading - returns (messageCount, characterCount)
    /// This is a wrapper that handles caching; use readStatsForDateRangeParallel for bulk parallel reads
    func readStatsForDateRange(
        from fileURL: URL,
        start: Date,
        end: Date
    ) async throws -> (messageCount: Int, characterCount: Int) {
        let datePrefix = DateFormatting.iso.string(from: start)
        return Self.readStatsFromFileFast(fileURL, datePrefix: datePrefix, start: start, end: end)
    }

    /// Fully nonisolated stats reading - for maximum parallelism
    nonisolated static func readStatsFromFileFast(
        _ fileURL: URL,
        datePrefix: String,
        start: Date,
        end: Date
    ) -> (messageCount: Int, characterCount: Int) {
        // Use file metadata for fast filtering (no file read needed!)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modDate = attrs[.modificationDate] as? Date,
              let createDate = attrs[.creationDate] as? Date else {
            return (0, 0)
        }

        // File metadata filter: skip if file's date range doesn't overlap target
        // Creation date ≈ first entry, Modification date ≈ last entry
        let endOfTargetDay = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start

        if modDate < start {
            // File was last modified before our target date - skip
            return (0, 0)
        }
        if createDate > endOfTargetDay {
            // File was created after our target date - skip
            return (0, 0)
        }

        // File might contain target date - do full parse
        return parseStatsFromFile(fileURL, datePrefix: datePrefix)
    }

    /// Nonisolated file parsing - can run truly in parallel
    /// Uses binary search for large files to find date range quickly
    private nonisolated static func parseStatsFromFile(
        _ fileURL: URL,
        datePrefix: String
    ) -> (messageCount: Int, characterCount: Int) {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Get file size first
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attrs[.size] as? UInt64 else {
            return (0, 0)
        }

        let fileSizeMB = Double(fileSize) / 1_000_000.0

        // For large files (>10MB), use binary search approach
        if fileSize > 10_000_000 {
            let result = parseStatsFromLargeFile(fileURL, datePrefix: datePrefix, fileSize: fileSize)
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            logger.notice("    file(binary): \(elapsed, format: .fixed(precision: 1))ms, \(fileSizeMB, format: .fixed(precision: 2))MB, \(result.messageCount) msgs - \(fileURL.lastPathComponent)")
            return result
        }

        // For smaller files, use the original approach
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return (0, 0)
        }

        if !text.contains(datePrefix) {
            return (0, 0)
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let decoder = JSONDecoder()

        var messageCount = 0
        var characterCount = 0

        for line in lines {
            guard lineMatchesDate(String(line), datePrefix: datePrefix) else { continue }
            let lineData = Data(line.utf8)
            if let entry = try? decoder.decode(StatsEntry.self, from: lineData),
               entry.isValidForStats {
                messageCount += 1
                characterCount += entry.textLength
            }
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        if elapsed > 50 || fileSizeMB > 0.5 {
            logger.notice("    file: \(elapsed, format: .fixed(precision: 1))ms, \(fileSizeMB, format: .fixed(precision: 2))MB, \(messageCount) msgs - \(fileURL.lastPathComponent)")
        }

        return (messageCount, characterCount)
    }

    /// Parse large files using binary search + chunked reading
    /// First finds approximate date position, then reads chunks from there
    private nonisolated static func parseStatsFromLargeFile(
        _ fileURL: URL,
        datePrefix: String,
        fileSize: UInt64
    ) -> (messageCount: Int, characterCount: Int) {
        guard let fileHandle = FileHandle(forReadingAtPath: fileURL.path) else {
            return (0, 0)
        }
        defer { try? fileHandle.close() }

        // Binary search to find approximate start of target date
        let startOffset = binarySearchForDate(fileHandle: fileHandle, datePrefix: datePrefix, fileSize: fileSize)

        // Seek to found position with safety margin
        let safeStart = startOffset > 500_000 ? startOffset - 500_000 : 0
        try? fileHandle.seek(toOffset: safeStart)


        let decoder = JSONDecoder()
        var messageCount = 0
        var characterCount = 0

        // Read in chunks from the found position
        let chunkSize = 4 * 1024 * 1024 // 4MB chunks
        var buffer = Data()
        var foundAnyMatch = false
        var noMatchChunks = 0
        let maxNoMatchChunks = 3 // Stop after 3 chunks with no matches (after finding some)

        while true {
            guard let chunk = try? fileHandle.read(upToCount: chunkSize) else { break }
            if chunk.isEmpty { break }

            buffer.append(chunk)

            guard let text = String(data: buffer, encoding: .utf8) else {
                buffer = Data()
                continue
            }

            // Quick check: if chunk doesn't contain date prefix
            let chunkHasDate = text.contains(datePrefix)

            if !chunkHasDate {
                if foundAnyMatch {
                    noMatchChunks += 1
                    if noMatchChunks >= maxNoMatchChunks {
                        break // We've moved past the target date range
                    }
                }
                // Keep the last incomplete line
                if let lastNewline = text.lastIndex(of: "\n") {
                    let afterNewline = text.index(after: lastNewline)
                    buffer = Data(text[afterNewline...].utf8)
                } else {
                    buffer = Data()
                }
                continue
            }

            // Reset no-match counter since we found matches
            noMatchChunks = 0

            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            let completeLineCount = text.hasSuffix("\n") ? lines.count : max(0, lines.count - 1)

            for i in 0..<completeLineCount {
                let line = String(lines[i])

                if lineMatchesDate(line, datePrefix: datePrefix) {
                    foundAnyMatch = true
                    let lineData = Data(line.utf8)
                    if let entry = try? decoder.decode(StatsEntry.self, from: lineData),
                       entry.isValidForStats {
                        messageCount += 1
                        characterCount += entry.textLength
                    }
                }
            }

            // Keep incomplete last line in buffer
            if completeLineCount < lines.count {
                buffer = Data(String(lines[completeLineCount]).utf8)
            } else {
                buffer = Data()
            }

        }

        return (messageCount, characterCount)
    }

    /// Binary search to find the FIRST occurrence of target date
    /// Uses two-phase search: find any match, then find left boundary
    private nonisolated static func binarySearchForDate(
        fileHandle: FileHandle,
        datePrefix: String,
        fileSize: UInt64
    ) -> UInt64 {
        // Phase 1: Find any position with target date
        var low: UInt64 = 0
        var high: UInt64 = fileSize
        var anyMatch: UInt64? = nil

        while high - low > 50_000 {
            let mid = low + (high - low) / 2
            guard let lineDate = readDateAtPosition(fileHandle: fileHandle, position: mid) else {
                low = mid + 1
                continue
            }

            if lineDate < datePrefix {
                low = mid + 1
            } else if lineDate > datePrefix {
                high = mid
            } else {
                anyMatch = mid
                break
            }
        }

        // If no match found, scan from low position
        guard let matchPos = anyMatch else {
            return low
        }

        // Phase 2: Binary search for LEFT boundary (first occurrence)
        low = 0
        high = matchPos

        while high - low > 50_000 {
            let mid = low + (high - low) / 2
            guard let lineDate = readDateAtPosition(fileHandle: fileHandle, position: mid) else {
                low = mid + 1
                continue
            }

            if lineDate < datePrefix {
                low = mid + 1
            } else {
                // lineDate >= datePrefix, search earlier
                high = mid
            }
        }

        // Phase 3: Linear scan to find exact first occurrence
        return findExactFirstOccurrence(fileHandle: fileHandle, datePrefix: datePrefix, startPos: low, endPos: matchPos)
    }

    /// Read the date from a line at approximately the given position
    private nonisolated static func readDateAtPosition(
        fileHandle: FileHandle,
        position: UInt64
    ) -> String? {
        try? fileHandle.seek(toOffset: position)
        // Use 1MB chunk to handle very long lines (some can be >256KB)
        guard let chunk = try? fileHandle.read(upToCount: 1_048_576),
              let text = String(data: chunk, encoding: .utf8) else {
            return nil
        }

        // At position 0, read first line directly
        if position == 0 {
            guard let firstNewline = text.firstIndex(of: "\n") else { return nil }
            let line = String(text[..<firstNewline])
            return extractDateFromLine(line)
        }

        // Otherwise, skip partial first line and read complete second line
        guard let firstNewline = text.firstIndex(of: "\n") else { return nil }
        let afterFirst = text.index(after: firstNewline)
        let rest = text[afterFirst...]
        guard let secondNewline = rest.firstIndex(of: "\n") else { return nil }

        let line = String(rest[..<secondNewline])
        return extractDateFromLine(line)
    }

    /// Linear scan to find exact first occurrence of target date
    private nonisolated static func findExactFirstOccurrence(
        fileHandle: FileHandle,
        datePrefix: String,
        startPos: UInt64,
        endPos: UInt64
    ) -> UInt64 {
        try? fileHandle.seek(toOffset: startPos)

        // Read enough to cover the search range plus buffer
        let readSize = min(Int(endPos - startPos) + 100_000, 2_000_000)
        guard let data = try? fileHandle.read(upToCount: readSize),
              let text = String(data: data, encoding: .utf8) else {
            return startPos
        }

        var currentOffset = startPos
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineStr = String(line)
            if let lineDate = extractDateFromLine(lineStr), lineDate == datePrefix {
                return currentOffset
            }
            currentOffset += UInt64(line.utf8.count) + 1
        }

        return startPos
    }

    /// Extract date (YYYY-MM-DD) from a JSONL line
    @inline(__always)
    private nonisolated static func extractDateFromLine(_ line: String) -> String? {
        guard let range = line.range(of: "\"timestamp\":\"") else { return nil }
        let afterQuote = line[range.upperBound...]
        guard afterQuote.count >= 10 else { return nil }
        return String(afterQuote.prefix(10))
    }


    /// Quick check file's date range by reading only first and last lines
    /// This avoids reading the entire file for date range checking
    private static func getFileDateRangeQuick(fileURL: URL) -> ClosedRange<Date>? {
        guard let fileHandle = FileHandle(forReadingAtPath: fileURL.path) else {
            return nil
        }
        defer { try? fileHandle.close() }

        // Read first 4KB to get first line
        guard let headData = try? fileHandle.read(upToCount: 4096),
              let headText = String(data: headData, encoding: .utf8) else {
            return nil
        }

        // Get first complete line
        guard let firstNewline = headText.firstIndex(of: "\n") else {
            return nil
        }
        let firstLine = String(headText[..<firstNewline])

        guard let firstTimestamp = extractTimestamp(from: firstLine),
              let firstDate = DateFormatting.parseISO8601(firstTimestamp) else {
            return nil
        }

        // Seek to end and read last 4KB
        guard let endOffset = try? fileHandle.seekToEnd(), endOffset > 4096 else {
            // Small file, first date is probably the only date
            return firstDate...firstDate
        }

        let tailOffset = endOffset > 8192 ? endOffset - 4096 : 0
        try? fileHandle.seek(toOffset: tailOffset)

        guard let tailData = try? fileHandle.read(upToCount: 4096),
              let tailText = String(data: tailData, encoding: .utf8) else {
            return firstDate...firstDate
        }

        // Get last complete line
        let lines = tailText.split(separator: "\n", omittingEmptySubsequences: true)
        guard let lastLineSubstring = lines.last else {
            return firstDate...firstDate
        }

        let lastLine = String(lastLineSubstring)
        guard let lastTimestamp = extractTimestamp(from: lastLine),
              let lastDate = DateFormatting.parseISO8601(lastTimestamp) else {
            return firstDate...firstDate
        }

        return min(firstDate, lastDate)...max(firstDate, lastDate)
    }

    /// Extract timestamp from JSON line without full parsing
    /// Uses simple string search instead of regex for speed
    @inline(__always)
    private static func extractTimestamp(from line: String) -> String? {
        // Look for "timestamp":" pattern
        guard let timestampKeyRange = line.range(of: "\"timestamp\":\"") else {
            return nil
        }
        let valueStart = timestampKeyRange.upperBound
        guard let valueEnd = line[valueStart...].firstIndex(of: "\"") else {
            return nil
        }
        return String(line[valueStart..<valueEnd])
    }

    /// Quick check if line's date matches target date (YYYY-MM-DD format)
    /// This is faster than full timestamp parsing for filtering
    @inline(__always)
    private static func lineMatchesDate(_ line: String, datePrefix: String) -> Bool {
        // Look for timestamp containing the date
        guard let range = line.range(of: "\"timestamp\":\"") else {
            return false
        }
        let afterKey = line[range.upperBound...]
        return afterKey.hasPrefix(datePrefix)
    }

    /// Filter conversations by time range
    nonisolated func filterByTimeRange(
        _ entries: [ConversationEntry],
        start: Date,
        end: Date
    ) -> [ConversationEntry] {
        entries.filter { entry in
            guard let entryDate = entry.date else { return false }
            return entryDate >= start && entryDate <= end
        }
    }

    /// Filter to meaningful messages (user/assistant with actual content)
    nonisolated func filterMeaningfulMessages(_ entries: [ConversationEntry]) -> [ConversationEntry] {
        entries.filter { entry in
            // Only user and assistant types
            guard entry.type == .user || entry.type == .assistant else { return false }
            // Skip meta messages
            if entry.isMeta == true { return false }
            // Must have actual message content
            guard entry.message != nil else { return false }
            // Must have extractable text
            guard let text = entry.textContent, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                return false
            }
            return true
        }
    }
}
