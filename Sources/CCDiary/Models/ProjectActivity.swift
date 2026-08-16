import Foundation

/// Statistics for filtering/truncation
struct ProjectStats: Sendable {
    let totalMessages: Int
    let usedMessages: Int
    let totalChars: Int
    let usedChars: Int
    let truncatedCount: Int
}

/// Single conversation message with timestamp
struct ConversationMessage: Sendable, Identifiable {
    let id = UUID()
    let role: MessageRole
    let content: String
    let timestamp: Date
}

/// Aggregated data for a single project on a given day
struct ProjectActivity: Identifiable, Sendable {
    let id = UUID()
    let path: String
    let name: String
    let userInputs: [String]
    let conversations: [ConversationMessage]
    let timeRange: ClosedRange<Date>
    let stats: ProjectStats
    var source: ActivitySource = .claudeCode

    /// Format time range as "HH:mm - HH:mm"
    var formattedTimeRange: String {
        "\(DateFormatting.time.string(from: timeRange.lowerBound)) - \(DateFormatting.time.string(from: timeRange.upperBound))"
    }
}

/// Aggregated data for a full day
struct DailyActivity: Sendable {
    let date: Date
    let projects: [ProjectActivity]
    let totalInputs: Int
    /// Sources whose read timed out or failed. Empty means every enabled
    /// reader finished; non-empty means the project list may under-count.
    var incompleteSources: [ActivitySource] = []

    /// Format date as localized string
    var formattedDate: String {
        DateFormatting.japaneseLong.string(from: date)
    }

    /// Format date as ISO date string (YYYY-MM-DD)
    var isoDateString: String {
        DateFormatting.iso.string(from: date)
    }
}
