import Foundation
import os.log

private let codexActivityLogger = Logger(subsystem: "CCDiary", category: "CodexActivityReader")

/// Reads OpenAI Codex rollout JSONL logs from ~/.codex.
actor CodexActivityReader {
    private let codexHome: URL
    private let sessionsRoot: URL
    private let archivedSessionsRoot: URL

    init(codexHome: URL? = nil) {
        let home = codexHome ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        self.codexHome = home
        self.sessionsRoot = home.appendingPathComponent("sessions")
        self.archivedSessionsRoot = home.appendingPathComponent("archived_sessions")
    }

    func readActivity(for date: Date, options: AggregateOptions = AggregateOptions()) async throws -> [AgentProjectActivity] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            throw AggregatorError.invalidDate
        }

        let files = candidateFiles(for: date)
        guard !files.isEmpty else { return [] }

        let sessions = await withTaskGroup(of: ParsedCodexSession?.self) { group in
            for file in files {
                group.addTask {
                    Self.parseSessionFile(file, start: startOfDay, end: endOfDay)
                }
            }

            var collected: [ParsedCodexSession] = []
            for await session in group {
                if let session, !session.messages.isEmpty {
                    collected.append(session)
                }
            }
            return collected
        }

        let grouped = Dictionary(grouping: sessions) { $0.cwd ?? "Codex" }
        let projects = grouped.compactMap { path, projectSessions -> AgentProjectActivity? in
            let messages = projectSessions.flatMap(\.messages).sorted { $0.timestamp < $1.timestamp }
            guard let first = messages.first?.timestamp, let last = messages.last?.timestamp else {
                return nil
            }

            let projectPath = path.isEmpty ? "Codex" : path
            let fallbackName = projectSessions.first?.title ?? "Codex"
            let sessionIds = Set(projectSessions.map(\.id))

            return AgentProjectActivity(
                source: .codex,
                path: projectPath,
                name: AgentActivityUtilities.projectName(from: projectPath, fallback: fallbackName),
                userInputs: messages.filter { $0.role == .user }.map(\.content),
                messages: messages,
                sessionIds: sessionIds,
                timeRange: first...last
            )
        }
        .sorted { $0.timeRange.lowerBound < $1.timeRange.lowerBound }

        codexActivityLogger.notice("readActivity(\(DateFormatting.iso.string(from: date))): \(projects.count) Codex projects from \(files.count) files")
        return projects
    }

    func readActivityDates() async -> Set<String> {
        var dates: Set<String> = []
        for file in allRolloutFiles() {
            if let date = Self.dateStringFromRolloutFilename(file.lastPathComponent) {
                dates.insert(date)
            }
        }
        return dates
    }

    private func candidateFiles(for date: Date) -> [URL] {
        let calendar = Calendar.current
        let dates = [-1, 0, 1].compactMap { calendar.date(byAdding: .day, value: $0, to: date) }

        var files: [URL] = []
        for candidateDate in dates {
            let year = DateFormatter.codexYear.string(from: candidateDate)
            let month = DateFormatter.codexMonth.string(from: candidateDate)
            let day = DateFormatter.codexDay.string(from: candidateDate)
            let directory = sessionsRoot.appendingPathComponent(year).appendingPathComponent(month).appendingPathComponent(day)
            files.append(contentsOf: Self.rolloutFiles(in: directory))
        }

        files.append(contentsOf: Self.rolloutFiles(in: archivedSessionsRoot))
        return Array(Set(files)).sorted { $0.path < $1.path }
    }

    private func allRolloutFiles() -> [URL] {
        var files: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let file as URL in enumerator where file.pathExtension == "jsonl" && file.lastPathComponent.hasPrefix("rollout-") {
                files.append(file)
            }
        }
        files.append(contentsOf: Self.rolloutFiles(in: archivedSessionsRoot))
        return files
    }

    private static func rolloutFiles(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return contents.filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-") }
    }

    private nonisolated static func parseSessionFile(_ file: URL, start: Date, end: Date) -> ParsedCodexSession? {
        guard let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        var sessionId = file.deletingPathExtension().lastPathComponent
        var cwd: String?
        var title: String?
        var messages: [AgentActivityMessage] = []
        var seenMessages: Set<String> = []
        // Codex Desktop's "import Claude Code web session" stamps task_started
        // with turn_id "external-import-turn-*". Those rollouts dump entire
        // imported transcripts as response_item messages, which would otherwise
        // be counted as real local work.
        var isExternalImport = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else {
                continue
            }

            if type == "session_meta" {
                if let id = payload["id"] as? String {
                    sessionId = id
                }
                if let payloadCwd = payload["cwd"] as? String {
                    cwd = payloadCwd
                }
                if let threadName = payload["thread_name"] as? String {
                    title = threadName
                }
                continue
            }

            if type == "event_msg",
               (payload["type"] as? String) == "task_started",
               let turnId = payload["turn_id"] as? String,
               turnId.hasPrefix("external-import-") {
                isExternalImport = true
                break
            }

            guard let timestampString = object["timestamp"] as? String,
                  let timestamp = DateFormatting.parseISO8601(timestampString),
                  timestamp >= start && timestamp < end else {
                continue
            }

            let parsedMessages = extractMessages(from: type, payload: payload, timestamp: timestamp, sessionId: sessionId)
            for message in parsedMessages where !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let dedupeKey = "\(Int(message.timestamp.timeIntervalSince1970 * 1000))|\(message.role.rawValue)|\(message.content)"
                guard !seenMessages.contains(dedupeKey) else { continue }
                seenMessages.insert(dedupeKey)
                messages.append(message)
            }
        }

        if isExternalImport {
            return nil
        }

        guard !messages.isEmpty else {
            return nil
        }

        return ParsedCodexSession(
            id: sessionId,
            cwd: cwd,
            title: title,
            messages: messages.sorted { $0.timestamp < $1.timestamp }
        )
    }

    private nonisolated static func extractMessages(
        from type: String,
        payload: [String: Any],
        timestamp: Date,
        sessionId: String
    ) -> [AgentActivityMessage] {
        if type == "event_msg", let eventType = payload["type"] as? String {
            switch eventType {
            case "user_message":
                return messageFromString(payload["message"], role: .user, timestamp: timestamp, sessionId: sessionId)
            case "agent_message":
                return messageFromString(payload["message"], role: .assistant, timestamp: timestamp, sessionId: sessionId)
            default:
                return []
            }
        }

        guard type == "response_item",
              (payload["type"] as? String) == "message",
              let roleString = payload["role"] as? String,
              let role = MessageRole(rawValue: roleString),
              role == .assistant,
              let contentBlocks = payload["content"] as? [[String: Any]] else {
            return []
        }

        let text = contentBlocks.compactMap { block -> String? in
            guard let blockType = block["type"] as? String,
                  blockType == "output_text" || blockType == "input_text",
                  let text = block["text"] as? String else {
                return nil
            }
            return text
        }
        .joined(separator: "\n")

        return messageFromString(text, role: role, timestamp: timestamp, sessionId: sessionId)
    }

    private nonisolated static func messageFromString(
        _ rawValue: Any?,
        role: MessageRole,
        timestamp: Date,
        sessionId: String
    ) -> [AgentActivityMessage] {
        guard let content = rawValue as? String else { return [] }
        guard !isInjectedContext(content) else { return [] }

        return [
            AgentActivityMessage(
                role: role,
                content: content,
                timestamp: timestamp,
                sessionId: sessionId
            )
        ]
    }

    private nonisolated static func isInjectedContext(_ content: String) -> Bool {
        content.hasPrefix("# AGENTS.md instructions for") ||
        content.hasPrefix("<permissions instructions>") ||
        content.contains("<INSTRUCTIONS>") && content.contains("</INSTRUCTIONS>")
    }

    private nonisolated static func dateStringFromRolloutFilename(_ filename: String) -> String? {
        let prefix = "rollout-"
        guard filename.hasPrefix(prefix) else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: prefix.count)
        let end = filename.index(start, offsetBy: 10, limitedBy: filename.endIndex) ?? filename.endIndex
        let dateString = String(filename[start..<end])
        guard dateString.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return dateString
    }

    private struct ParsedCodexSession: Sendable {
        let id: String
        let cwd: String?
        let title: String?
        let messages: [AgentActivityMessage]
    }
}

private extension DateFormatter {
    // These build `~/.codex/sessions/<yyyy>/<MM>/<dd>` paths, so they must be
    // locale/calendar independent — a Japanese-calendar system would otherwise
    // produce e.g. "08" for the year and miss the directory entirely.
    static func codexComponentFormatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter
    }

    static let codexYear = codexComponentFormatter(format: "yyyy")
    static let codexMonth = codexComponentFormatter(format: "MM")
    static let codexDay = codexComponentFormatter(format: "dd")
}
