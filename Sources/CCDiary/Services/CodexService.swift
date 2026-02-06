import Foundation
import os.log

private let logger = Logger(subsystem: "CCDiary", category: "CodexService")

/// Date index cache for Codex session files
private actor CodexDateIndex {
    private var dateToFiles: [String: Set<String>] = [:]
    private var fileModTimes: [String: TimeInterval] = [:]
    private var fileToDates: [String: Set<String>] = [:]
    private var isDirty = false
    private var isLoaded = false

    private static var cacheFileURL: URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CCDiary")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir.appendingPathComponent("codex_dates.json")
    }

    func getAllDates() -> Set<String> {
        ensureLoaded()
        return Set(dateToFiles.keys)
    }

    func getFiles(for dateString: String) -> Set<String>? {
        ensureLoaded()
        return dateToFiles[dateString]
    }

    func isFileIndexed(_ path: String, modTime: TimeInterval) -> Bool {
        ensureLoaded()
        guard let cached = fileModTimes[path] else { return false }
        return cached == modTime
    }

    func indexFile(_ path: String, modTime: TimeInterval, dates: Set<String>) {
        ensureLoaded()

        if let oldDates = fileToDates[path] {
            for date in oldDates {
                dateToFiles[date]?.remove(path)
                if dateToFiles[date]?.isEmpty == true {
                    dateToFiles.removeValue(forKey: date)
                }
            }
        }

        fileToDates[path] = dates
        fileModTimes[path] = modTime

        for date in dates {
            dateToFiles[date, default: []].insert(path)
        }

        isDirty = true
    }

    func removeMissingFiles(validPaths: Set<String>) {
        ensureLoaded()

        let stalePaths = Set(fileToDates.keys).subtracting(validPaths)
        guard !stalePaths.isEmpty else { return }

        for path in stalePaths {
            if let dates = fileToDates[path] {
                for date in dates {
                    dateToFiles[date]?.remove(path)
                    if dateToFiles[date]?.isEmpty == true {
                        dateToFiles.removeValue(forKey: date)
                    }
                }
            }
            fileToDates.removeValue(forKey: path)
            fileModTimes.removeValue(forKey: path)
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
        let url = Self.cacheFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)
            let stored = try JSONDecoder().decode(StoredCodexDateIndex.self, from: data)

            for file in stored.files {
                let dates = Set(file.dates)
                fileToDates[file.path] = dates
                fileModTimes[file.path] = file.modTime
                for date in dates {
                    dateToFiles[date, default: []].insert(file.path)
                }
            }

            logger.info("Loaded Codex date index: \(stored.files.count) files, \(self.dateToFiles.count) dates")
        } catch {
            logger.warning("Codex date index cache corrupted, deleting: \(error)")
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func saveToDisk() {
        var files: [StoredFileEntry] = []

        for (path, dates) in fileToDates {
            guard let modTime = fileModTimes[path] else { continue }
            files.append(StoredFileEntry(path: path, modTime: modTime, dates: Array(dates)))
        }

        let stored = StoredCodexDateIndex(files: files)
        do {
            let data = try JSONEncoder().encode(stored)
            try data.write(to: Self.cacheFileURL)
            logger.info("Saved Codex date index: \(files.count) files")
        } catch {
            logger.error("Failed to save Codex date index: \(error)")
        }
    }

    private struct StoredCodexDateIndex: Codable {
        let files: [StoredFileEntry]
    }

    private struct StoredFileEntry: Codable {
        let path: String
        let modTime: TimeInterval
        let dates: [String]
    }
}

/// Service for reading Codex CLI/App chat history
actor CodexService {
    private let sessionsPath: URL
    private let dateIndex = CodexDateIndex()

    private static let filteredUserMessagePrefixes: [String] = [
        "# AGENTS.md instructions for ",
        "<environment_context>",
        "<permissions instructions>",
        "<app-context>",
        "<collaboration_mode>",
        "<turn_aborted>",
        "<user_action>"
    ]

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.sessionsPath = home.appendingPathComponent(".codex/sessions")
    }

    nonisolated func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: sessionsPath.path)
    }

    func buildDateIndexIfNeeded() async throws -> Set<String> {
        guard isAvailable() else {
            logger.notice("Codex sessions directory not found at \(self.sessionsPath.path)")
            return []
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let allFiles = try collectSessionFiles()
        let validPaths = Set(allFiles.map(\.path))

        await dateIndex.removeMissingFiles(validPaths: validPaths)

        var filesToIndex: [(url: URL, modTime: TimeInterval)] = []
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
            logger.notice("Codex date index up-to-date (\(allFiles.count) files)")
            return await dateIndex.getAllDates()
        }

        await withTaskGroup(of: (String, TimeInterval, Set<String>).self) { group in
            for (fileURL, modTime) in filesToIndex {
                group.addTask {
                    let dates = Self.extractDatesFromFile(fileURL)
                    return (fileURL.path, modTime, dates)
                }
            }

            for await (path, modTime, dates) in group {
                await dateIndex.indexFile(path, modTime: modTime, dates: dates)
            }
        }

        await dateIndex.saveToDiskIfNeeded()

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger.notice("Built Codex date index: \(filesToIndex.count) files in \(elapsed, format: .fixed(precision: 1))ms")
        return await dateIndex.getAllDates()
    }

    func getAllDatesWithMessages() async throws -> Set<String> {
        guard isAvailable() else { return [] }
        return await dateIndex.getAllDates()
    }

    func getActivityForDate(_ date: Date) async throws -> [CodexProjectActivity] {
        guard isAvailable() else { return [] }

        let dateString = DateFormatting.iso.string(from: date)
        guard let filePaths = await dateIndex.getFiles(for: dateString), !filePaths.isEmpty else {
            return []
        }

        let fileURLs = filePaths.map { URL(fileURLWithPath: $0) }

        let parsedSessions = await withTaskGroup(of: ParsedSession?.self) { group in
            for fileURL in fileURLs {
                group.addTask {
                    Self.parseSession(from: fileURL, targetDate: date)
                }
            }

            var sessions: [ParsedSession] = []
            for await session in group {
                if let session {
                    sessions.append(session)
                }
            }
            return sessions
        }

        // Deduplicate by session ID (prefer richer/newer format when duplicated)
        var uniqueSessionsByID: [String: ParsedSession] = [:]
        for session in parsedSessions {
            guard let existing = uniqueSessionsByID[session.sessionId] else {
                uniqueSessionsByID[session.sessionId] = session
                continue
            }

            let shouldReplace: Bool
            if session.messages.count != existing.messages.count {
                shouldReplace = session.messages.count > existing.messages.count
            } else {
                shouldReplace = session.format > existing.format
            }

            if shouldReplace {
                uniqueSessionsByID[session.sessionId] = session
            }
        }

        struct GroupedProject {
            var messages: [CodexChatMessage]
            var sessionIds: Set<String>
        }

        var grouped: [String: GroupedProject] = [:]

        for session in uniqueSessionsByID.values {
            var project = grouped[session.cwd] ?? GroupedProject(messages: [], sessionIds: [])
            project.messages.append(contentsOf: session.messages)
            project.sessionIds.insert(session.sessionId)
            grouped[session.cwd] = project
        }

        var activities: [CodexProjectActivity] = []
        for (projectPath, project) in grouped {
            let sortedMessages = project.messages.sorted { $0.timestamp < $1.timestamp }
            guard let start = sortedMessages.first?.timestamp, let end = sortedMessages.last?.timestamp else {
                continue
            }

            activities.append(CodexProjectActivity(
                projectPath: projectPath,
                projectName: (projectPath as NSString).lastPathComponent,
                messages: sortedMessages,
                sessionCount: project.sessionIds.count,
                timeRangeStart: start,
                timeRangeEnd: end
            ))
        }

        activities.sort { $0.timeRangeStart < $1.timeRangeStart }
        return activities
    }

    private func collectSessionFiles() throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsPath,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if ext == "jsonl" || ext == "json" {
                files.append(fileURL)
            }
        }
        return files
    }

    private nonisolated static func extractDatesFromFile(_ fileURL: URL) -> Set<String> {
        guard let session = parseSession(from: fileURL, targetDate: nil) else {
            return []
        }

        return Set(session.messages.map { DateFormatting.iso.string(from: $0.timestamp) })
    }

    private nonisolated static func parseSession(from fileURL: URL, targetDate: Date?) -> ParsedSession? {
        switch fileURL.pathExtension.lowercased() {
        case "jsonl":
            return parseJSONLSession(from: fileURL, targetDate: targetDate)
        case "json":
            return parseLegacySession(from: fileURL, targetDate: targetDate)
        default:
            return nil
        }
    }

    private nonisolated static func parseJSONLSession(from fileURL: URL, targetDate: Date?) -> ParsedSession? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            logger.warning("Failed to read Codex session \(fileURL.lastPathComponent): \(error)")
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else {
            logger.warning("Codex session not valid UTF-8: \(fileURL.lastPathComponent)")
            return nil
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let decoder = JSONDecoder()

        var sessionId: String?
        var cwd: String?
        var fallbackTimestamp: Date?
        var messages: [CodexChatMessage] = []
        var isSubagentSession = false
        var skippedLines = 0

        for line in lines {
            guard let event = try? decoder.decode(JSONLEvent.self, from: Data(line.utf8)) else {
                skippedLines += 1
                continue
            }

            if event.type == "session_meta" {
                if let id = event.payload?.id, !id.isEmpty {
                    sessionId = id
                }
                if let sessionPath = event.payload?.cwd, !sessionPath.isEmpty {
                    cwd = sessionPath
                }
                if event.payload?.source?.isSubagent == true {
                    isSubagentSession = true
                }

                let ts = event.payload?.timestamp ?? event.timestamp
                if let ts, let parsed = DateFormatting.parseISO8601(ts) {
                    fallbackTimestamp = parsed
                }
                continue
            }

            guard event.type == "response_item",
                  event.payload?.type == "message",
                  let role = parseRole(event.payload?.role),
                  let textContent = extractText(event.payload?.content) else {
                continue
            }

            if role == .user && shouldExcludeUserMessage(textContent) {
                continue
            }

            let timestampString = event.timestamp ?? event.payload?.timestamp
            let parsedTimestamp = timestampString.flatMap(DateFormatting.parseISO8601) ?? fallbackTimestamp
            guard let timestamp = parsedTimestamp else { continue }

            if let targetDate, !Calendar.current.isDate(timestamp, inSameDayAs: targetDate) {
                continue
            }

            messages.append(CodexChatMessage(role: role, content: textContent, timestamp: timestamp))
        }

        if isSubagentSession {
            return nil
        }

        if messages.isEmpty && skippedLines > 0 {
            logger.warning("Codex session \(fileURL.lastPathComponent): all \(skippedLines)/\(lines.count) lines failed to decode")
        }
        guard !messages.isEmpty else { return nil }
        guard let rawPath = cwd, let sessionPath = normalizeProjectPath(rawPath) else {
            return nil
        }

        messages.sort { $0.timestamp < $1.timestamp }
        let resolvedSessionId = sessionId.flatMap { $0.isEmpty ? nil : $0 }
            ?? fileURL.deletingPathExtension().lastPathComponent

        return ParsedSession(sessionId: resolvedSessionId, cwd: sessionPath, messages: messages, format: .jsonl)
    }

    private nonisolated static func parseLegacySession(from fileURL: URL, targetDate: Date?) -> ParsedSession? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            logger.warning("Failed to read Codex legacy session \(fileURL.lastPathComponent): \(error)")
            return nil
        }
        let legacy: LegacySessionFile
        do {
            legacy = try JSONDecoder().decode(LegacySessionFile.self, from: data)
        } catch {
            logger.warning("Failed to decode Codex legacy session \(fileURL.lastPathComponent): \(error)")
            return nil
        }

        guard let rawPath = legacy.session.cwd,
              let sessionPath = normalizeProjectPath(rawPath) else {
            return nil
        }

        let sessionTimestamp = legacy.session.timestamp.flatMap(DateFormatting.parseISO8601)
        var messages: [CodexChatMessage] = []

        for item in legacy.items {
            guard item.type == "message",
                  let role = parseRole(item.role),
                  let textContent = extractText(item.content) else {
                continue
            }

            if role == .user && shouldExcludeUserMessage(textContent) {
                continue
            }

            let timestamp = item.timestamp.flatMap(DateFormatting.parseISO8601) ?? sessionTimestamp
            guard let timestamp else { continue }

            if let targetDate, !Calendar.current.isDate(timestamp, inSameDayAs: targetDate) {
                continue
            }

            messages.append(CodexChatMessage(role: role, content: textContent, timestamp: timestamp))
        }

        guard !messages.isEmpty else { return nil }

        messages.sort { $0.timestamp < $1.timestamp }
        let resolvedSessionId = legacy.session.id.flatMap { $0.isEmpty ? nil : $0 }
            ?? fileURL.deletingPathExtension().lastPathComponent

        return ParsedSession(sessionId: resolvedSessionId, cwd: sessionPath, messages: messages, format: .legacyJSON)
    }

    private nonisolated static func parseRole(_ rawRole: String?) -> MessageRole? {
        guard let rawRole else { return nil }
        switch rawRole {
        case "user":
            return .user
        case "assistant":
            return .assistant
        default:
            return nil
        }
    }

    private nonisolated static func extractText(_ content: [CodexContent]?) -> String? {
        guard let content else { return nil }
        let texts = content.compactMap { block -> String? in
            guard let text = block.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            return text
        }

        guard !texts.isEmpty else { return nil }
        return texts.joined(separator: "\n")
    }

    private nonisolated static func shouldExcludeUserMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredUserMessagePrefixes.contains { trimmed.hasPrefix($0) }
    }

    private nonisolated static func normalizeProjectPath(_ rawPath: String) -> String? {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        if let url = URL(string: path), url.isFileURL {
            path = url.path
        } else if path.hasPrefix("file://") {
            let stripped = path
                .replacingOccurrences(of: "file://localhost", with: "")
                .replacingOccurrences(of: "file://", with: "")
            path = stripped.removingPercentEncoding ?? stripped
        }

        let standardized = (path as NSString).standardizingPath
        guard !standardized.isEmpty else { return nil }

        let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        guard !resolved.isEmpty else { return nil }

        if resolved.count > 1 && resolved.hasSuffix("/") {
            return String(resolved.dropLast())
        }
        return resolved
    }

    /// Priority for session format deduplication (higher = preferred)
    private enum SessionFormat: Int, Comparable, Sendable {
        case legacyJSON = 1
        case jsonl = 2

        static func < (lhs: SessionFormat, rhs: SessionFormat) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private struct ParsedSession: Sendable {
        let sessionId: String
        let cwd: String
        let messages: [CodexChatMessage]
        let format: SessionFormat
    }

    private struct JSONLEvent: Decodable {
        let timestamp: String?
        let type: String
        let payload: JSONLPayload?
    }

    private struct JSONLPayload: Decodable {
        let id: String?
        let cwd: String?
        let timestamp: String?
        let source: SessionSource?
        let type: String?
        let role: String?
        let content: [CodexContent]?
    }

    private enum SessionSource: Decodable {
        case string(String)
        case object([String: String])
        case unknown

        var isSubagent: Bool {
            switch self {
            case .object(let fields):
                return fields["subagent"] != nil
            default:
                return false
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()

            if let value = try? container.decode(String.self) {
                self = .string(value)
                return
            }

            if let value = try? container.decode([String: String].self) {
                self = .object(value)
                return
            }

            self = .unknown
        }
    }

    private struct LegacySessionFile: Decodable {
        let session: LegacySessionMeta
        let items: [LegacyItem]
    }

    private struct LegacySessionMeta: Decodable {
        let id: String?
        let timestamp: String?
        let cwd: String?
    }

    private struct LegacyItem: Decodable {
        let type: String
        let role: String?
        let timestamp: String?
        let content: [CodexContent]?
    }

    private struct CodexContent: Decodable {
        let text: String?
    }
}

/// Chat message from Codex session logs
struct CodexChatMessage: Sendable {
    let role: MessageRole
    let content: String
    let timestamp: Date
}

/// Codex activity grouped by project for one day
struct CodexProjectActivity: Sendable {
    let projectPath: String
    let projectName: String
    let messages: [CodexChatMessage]
    let sessionCount: Int
    let timeRangeStart: Date
    let timeRangeEnd: Date

    var timeRange: ClosedRange<Date> {
        timeRangeStart...timeRangeEnd
    }
}

/// Quick stats for Codex activity
struct CodexQuickStats: Sendable {
    let projectCount: Int
    let sessionCount: Int
    let messageCount: Int
}
