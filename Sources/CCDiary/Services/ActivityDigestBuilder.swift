import Foundation

/// Builds compact, evidence-rich digests for very large agent transcripts.
enum ActivityDigestBuilder {
    private static let segmentGap: TimeInterval = 30 * 60
    private static let maxMessagesPerSegment = 220
    private static let maxUserIntentsPerSegment = 5
    private static let maxHighlightsPerSegment = 6
    private static let maxSignalsPerSegment = 10

    static func conversations(
        from messages: [AgentActivityMessage],
        source: ActivitySource,
        projectName: String,
        projectPath: String,
        maxContentLength: Int,
        maxMessagesPerProject: Int
    ) -> [ConversationMessage] {
        let sortedMessages = messages.sorted { $0.timestamp < $1.timestamp }
        guard sortedMessages.count > maxMessagesPerProject else {
            return sortedMessages.map { message in
                ConversationMessage(
                    role: message.role,
                    content: truncate(message.content, limit: maxContentLength),
                    timestamp: message.timestamp
                )
            }
        }

        let cleanedMessages = sortedMessages.compactMap(CleanedMessage.init(message:))
        guard !cleanedMessages.isEmpty else {
            return []
        }

        let allSegments = buildSegments(from: cleanedMessages)
        let maxSegments = max(4, min(18, maxMessagesPerProject / 4))
        let selectedSegments = selectSegments(allSegments, limit: maxSegments)

        var digestMessages: [ConversationMessage] = []
        let start = cleanedMessages.first?.timestamp ?? sortedMessages.first?.timestamp ?? Date()
        let overview = """
        Local large-history digest.
        Source: \(source.rawValue)
        Project: \(projectName)
        Path: \(projectPath)
        Raw messages: \(sortedMessages.count)
        Digest windows: \(selectedSegments.count)/\(allSegments.count)
        Rule: this digest was built from the full transcript. Use these user intents, outcome signals, files, PRs, issues, tests, and deploy notes as evidence for the diary.
        """

        digestMessages.append(
            ConversationMessage(
                role: .assistant,
                content: truncate(overview, limit: maxContentLength),
                timestamp: start
            )
        )

        for segment in selectedSegments {
            digestMessages.append(
                ConversationMessage(
                    role: .assistant,
                    content: truncate(segment.digestText, limit: maxContentLength),
                    timestamp: segment.start
                )
            )
        }

        if allSegments.count > selectedSegments.count {
            let omittedCount = allSegments.count - selectedSegments.count
            let omittedMessages = allSegments
                .filter { segment in !selectedSegments.contains(where: { $0.id == segment.id }) }
                .reduce(0) { $0 + $1.messageCount }
            let note = "Condensed \(omittedCount) lower-signal windows (\(omittedMessages) raw messages). They were scanned but not expanded in this prompt."
            digestMessages.append(
                ConversationMessage(
                    role: .assistant,
                    content: note,
                    timestamp: selectedSegments.last?.end ?? start
                )
            )
        }

        return digestMessages
    }

    private static func buildSegments(from messages: [CleanedMessage]) -> [SegmentDigest] {
        var segments: [SegmentDigest] = []
        var current: SegmentDigest?

        for message in messages {
            let shouldStartNew: Bool
            if let active = current {
                let gap = message.timestamp.timeIntervalSince(active.end)
                shouldStartNew = active.sessionId != message.sessionId ||
                    gap > segmentGap ||
                    active.messageCount >= maxMessagesPerSegment
            } else {
                shouldStartNew = true
            }

            if shouldStartNew {
                if let active = current {
                    segments.append(active)
                }
                current = SegmentDigest(sessionId: message.sessionId, start: message.timestamp)
            }

            current?.add(message)
        }

        if let active = current {
            segments.append(active)
        }

        return segments
    }

    private static func selectSegments(_ segments: [SegmentDigest], limit: Int) -> [SegmentDigest] {
        guard segments.count > limit else {
            return segments
        }

        var selectedIds: Set<UUID> = []
        if let first = segments.first {
            selectedIds.insert(first.id)
        }
        if let last = segments.last {
            selectedIds.insert(last.id)
        }

        let ranked = segments.sorted {
            if $0.importanceScore == $1.importanceScore {
                return $0.start < $1.start
            }
            return $0.importanceScore > $1.importanceScore
        }

        for segment in ranked where selectedIds.count < limit {
            selectedIds.insert(segment.id)
        }

        return segments.filter { selectedIds.contains($0.id) }
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else {
            return text
        }
        return String(text.prefix(max(0, limit - 3))) + "..."
    }

    private struct CleanedMessage {
        let role: MessageRole
        let content: String
        let timestamp: Date
        let sessionId: String?

        init?(message: AgentActivityMessage) {
            guard let cleaned = Self.clean(message.content) else {
                return nil
            }

            role = message.role
            content = cleaned
            timestamp = message.timestamp
            sessionId = message.sessionId
        }

        private static func clean(_ raw: String) -> String? {
            var text = raw
                .replacingOccurrences(of: "\u{0000}", with: "")
                .replacingOccurrences(of: "<command-message>", with: "Command: ")
                .replacingOccurrences(of: "</command-message>", with: "")
                .replacingOccurrences(of: "<command-name>", with: " ")
                .replacingOccurrences(of: "</command-name>", with: "")

            text = text
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else {
                return nil
            }

            let lowercased = text.lowercased()
            if lowercased.contains("ag ents.md instructions".replacingOccurrences(of: " ", with: "")) ||
                lowercased.contains("<environment_context>") ||
                lowercased.contains("<permissions instructions>") ||
                (lowercased.contains("base64") && text.count > 8_000) {
                return nil
            }

            return text
        }
    }

    private struct SegmentDigest {
        let id = UUID()
        let sessionId: String?
        let start: Date
        private(set) var end: Date
        private(set) var messageCount = 0
        private(set) var userIntents: [String] = []
        private(set) var assistantHighlights: [String] = []
        private(set) var signals: [String] = []

        init(sessionId: String?, start: Date) {
            self.sessionId = sessionId
            self.start = start
            self.end = start
        }

        mutating func add(_ message: CleanedMessage) {
            messageCount += 1
            end = max(end, message.timestamp)

            switch message.role {
            case .user:
                Self.appendUnique(
                    Self.shorten(message.content, limit: 220),
                    to: &userIntents,
                    limit: ActivityDigestBuilder.maxUserIntentsPerSegment
                )
            case .assistant:
                for highlight in Self.extractHighlights(from: message.content) {
                    Self.appendUnique(
                        Self.shorten(highlight, limit: 240),
                        to: &assistantHighlights,
                        limit: ActivityDigestBuilder.maxHighlightsPerSegment
                    )
                }
            }

            for signal in Self.extractSignals(from: message.content) {
                Self.appendUnique(signal, to: &signals, limit: ActivityDigestBuilder.maxSignalsPerSegment)
            }
        }

        var importanceScore: Int {
            messageCount +
                userIntents.count * 20 +
                assistantHighlights.count * 35 +
                signals.count * 12
        }

        var digestText: String {
            var lines: [String] = []
            let timeRange = "\(DateFormatting.time.string(from: start))-\(DateFormatting.time.string(from: end))"
            lines.append("Digest window \(timeRange), \(messageCount) raw messages, session \(shortSessionId).")

            if !userIntents.isEmpty {
                lines.append("User intents:")
                lines.append(contentsOf: userIntents.map { "- \($0)" })
            }

            if !assistantHighlights.isEmpty {
                lines.append("Outcome signals:")
                lines.append(contentsOf: assistantHighlights.map { "- \($0)" })
            }

            if !signals.isEmpty {
                lines.append("Artifacts and keywords: \(signals.joined(separator: ", "))")
            }

            return lines.joined(separator: "\n")
        }

        private var shortSessionId: String {
            guard let sessionId, !sessionId.isEmpty else {
                return "unknown"
            }
            return String(sessionId.prefix(8))
        }

        private static func appendUnique(_ value: String, to values: inout [String], limit: Int) {
            guard values.count < limit else {
                return
            }

            let normalized = value.lowercased()
            guard !values.contains(where: { $0.lowercased() == normalized }) else {
                return
            }

            values.append(value)
        }

        private static func shorten(_ text: String, limit: Int) -> String {
            guard text.count > limit else {
                return text
            }
            return String(text.prefix(max(0, limit - 3))) + "..."
        }

        private static func extractHighlights(from text: String) -> [String] {
            let separators = CharacterSet.newlines.union(CharacterSet(charactersIn: "。"))
            let candidates = text
                .components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            var highlights: [String] = []
            for candidate in candidates {
                guard score(candidate) > 0 else {
                    continue
                }
                appendUnique(candidate, to: &highlights, limit: 3)
            }
            return highlights
        }

        private static func score(_ text: String) -> Int {
            let lowercased = text.lowercased()
            let keywords = [
                "implemented", "added", "fixed", "created", "updated", "removed",
                "refactored", "deployed", "merged", "tested", "validated", "passed",
                "green", "committed", "pushed", "review", "coverage", "e2e",
                "lint", "typecheck", "build", "pr", "issue", "staging", "prod",
                "cloudflare", "worker", "admin", "cms", "preview", "draft",
                "実装", "追加", "修正", "更新", "削除", "改善", "リファクタ",
                "デプロイ", "テスト", "確認", "成功", "マージ", "レビュー"
            ]
            return keywords.reduce(0) { score, keyword in
                lowercased.contains(keyword) ? score + 1 : score
            }
        }

        private static func extractSignals(from text: String) -> [String] {
            let separators = CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: "`\"'()[]{}<>,;:"))
            let tokens = text
                .components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?")) }
                .filter { !$0.isEmpty }

            var signals: [String] = []
            for token in tokens {
                if isSignal(token) {
                    appendUnique(token, to: &signals, limit: ActivityDigestBuilder.maxSignalsPerSegment)
                }
            }
            return signals
        }

        private static func isSignal(_ token: String) -> Bool {
            let lowercased = token.lowercased()
            if token.hasPrefix("#"), token.dropFirst().allSatisfy(\.isNumber) {
                return true
            }

            if lowercased.hasPrefix("pr") && lowercased.dropFirst(2).allSatisfy(\.isNumber) {
                return true
            }

            let fileExtensions = [
                ".swift", ".ts", ".tsx", ".js", ".jsx", ".md", ".json", ".sql",
                ".toml", ".yaml", ".yml", ".css", ".html", ".vue", ".py"
            ]
            if fileExtensions.contains(where: { lowercased.hasSuffix($0) }) {
                return true
            }

            let keywords = [
                "cloudflare", "worker", "workers", "staging", "production", "prod",
                "admin", "cms", "preview", "draft", "e2e", "vitest", "playwright",
                "lint", "typecheck", "build", "deploy", "merge", "github"
            ]
            return keywords.contains { lowercased.contains($0) }
        }
    }
}
