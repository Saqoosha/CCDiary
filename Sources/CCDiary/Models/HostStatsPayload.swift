import Foundation

/// Payload sent to and received from /api/host-stats for multi-Mac statistics aggregation.
struct HostStatsPayload: Codable {
    let date: String          // YYYY-MM-DD
    let host: String
    let stats: DayStatistics
    let digest: DigestPayload
    let updatedAt: Int        // unix epoch seconds
}

struct DigestPayload: Codable {
    let totalInputs: Int
    let projects: [DigestProject]
}

struct DigestProject: Codable {
    let name: String
    let path: String
    let source: String         // ActivitySource.rawValue
    let timeRangeStart: Date
    let timeRangeEnd: Date
    let totalMessages: Int
    let usedMessages: Int
    let conversations: [DigestMessage]
}

struct DigestMessage: Codable {
    let role: String           // "user" or "assistant"
    let content: String
    let timestamp: Date
}

extension ProjectActivity {
    func toDigestProject() -> DigestProject {
        DigestProject(
            name: name,
            path: path,
            source: source.rawValue,
            timeRangeStart: timeRange.lowerBound,
            timeRangeEnd: timeRange.upperBound,
            totalMessages: stats.totalMessages,
            usedMessages: stats.usedMessages,
            conversations: conversations.map {
                DigestMessage(role: $0.role.rawValue, content: $0.content, timestamp: $0.timestamp)
            }
        )
    }
}

extension DigestProject {
    func toProjectActivity() -> ProjectActivity {
        let messages = conversations.map {
            ConversationMessage(
                role: MessageRole(rawValue: $0.role) ?? .assistant,
                content: $0.content,
                timestamp: $0.timestamp
            )
        }
        let stats = ProjectStats(
            totalMessages: totalMessages,
            usedMessages: usedMessages,
            // Digest only carries the used subset of messages,
            // so totalChars == usedChars here.
            totalChars: conversations.reduce(0) { $0 + $1.content.count },
            usedChars: conversations.reduce(0) { $0 + $1.content.count },
            truncatedCount: max(0, totalMessages - usedMessages)
        )
        let range = timeRangeStart...timeRangeEnd
        let userMsgs = conversations.filter { $0.role == "user" }.map(\.content)
        var activity = ProjectActivity(
            path: path,
            name: name,
            userInputs: userMsgs,
            conversations: messages,
            timeRange: range,
            stats: stats
        )
        activity.source = ActivitySource(rawValue: source) ?? .claudeCode
        return activity
    }
}

extension DailyActivity {
    func toDigestPayload() -> DigestPayload {
        DigestPayload(
            totalInputs: totalInputs,
            projects: projects.map { $0.toDigestProject() }
        )
    }
}
