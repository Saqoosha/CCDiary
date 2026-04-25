import Foundation

/// Normalized chat message from any supported coding agent.
struct AgentActivityMessage: Identifiable, Sendable {
    let id = UUID()
    let role: MessageRole
    let content: String
    let timestamp: Date
    let sessionId: String?
}

/// Normalized project-level activity from Claude Code, Codex, Cursor, or future agents.
struct AgentProjectActivity: Identifiable, Sendable {
    let id = UUID()
    let source: ActivitySource
    let path: String
    let name: String
    let userInputs: [String]
    let messages: [AgentActivityMessage]
    let sessionIds: Set<String>
    let timeRange: ClosedRange<Date>

    func toProjectActivity(maxContentLength: Int, maxMessagesPerProject: Int) -> ProjectActivity {
        let sortedMessages = messages.sorted { $0.timestamp < $1.timestamp }
        let conversations = ActivityDigestBuilder.conversations(
            from: sortedMessages,
            source: source,
            projectName: name,
            projectPath: path,
            maxContentLength: maxContentLength,
            maxMessagesPerProject: maxMessagesPerProject
        )

        let totalChars = sortedMessages.reduce(0) { $0 + $1.content.count }
        let usedChars = conversations.reduce(0) { $0 + $1.content.count }
        let contentTruncatedCount = sortedMessages.filter { $0.content.count > maxContentLength }.count
        let digestCondensedCount = max(0, sortedMessages.count - conversations.count)

        let stats = ProjectStats(
            totalMessages: sortedMessages.count,
            usedMessages: conversations.count,
            totalChars: totalChars,
            usedChars: usedChars,
            truncatedCount: contentTruncatedCount + digestCondensedCount
        )

        var project = ProjectActivity(
            path: path,
            name: name,
            userInputs: userInputs,
            conversations: conversations,
            timeRange: timeRange,
            stats: stats
        )
        project.source = source
        return project
    }

    func toProjectSummary() -> ProjectSummary {
        var summary = ProjectSummary(
            name: name,
            path: path,
            messageCount: messages.count,
            timeRangeStart: timeRange.lowerBound,
            timeRangeEnd: timeRange.upperBound
        )
        summary.source = source
        return summary
    }
}

enum AgentActivityUtilities {
    static func projectName(from path: String, fallback: String) -> String {
        let lastComponent = (path as NSString).lastPathComponent
        return lastComponent.isEmpty ? fallback : lastComponent
    }

    static func commonAncestor(for paths: [String]) -> String? {
        let components = paths
            .filter { !$0.isEmpty }
            .map { path -> [String] in
                let url = URL(fileURLWithPath: path)
                let candidate = pathHasFileExtension(path) ? url.deletingLastPathComponent().path : url.path
                return candidate.split(separator: "/").map(String.init)
            }

        guard var common = components.first, !common.isEmpty else { return nil }

        for pathComponents in components.dropFirst() {
            var prefixLength = 0
            while prefixLength < common.count &&
                  prefixLength < pathComponents.count &&
                  common[prefixLength] == pathComponents[prefixLength] {
                prefixLength += 1
            }
            common = Array(common.prefix(prefixLength))
            if common.isEmpty { return nil }
        }

        return "/" + common.joined(separator: "/")
    }

    private static func pathHasFileExtension(_ path: String) -> Bool {
        !(path as NSString).pathExtension.isEmpty
    }
}
