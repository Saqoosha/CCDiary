import Foundation

/// Quick statistics for a single day (without full conversation content)
struct DayStatistics: Sendable, Codable {
    let date: Date
    let projectCount: Int
    let sessionCount: Int       // unique session IDs
    let messageCount: Int
    let characterCount: Int
    let projects: [ProjectSummary]

    // Cursor-specific stats (optional for backwards compatibility)
    let cursorStats: CursorDailyStats?

    // Custom coding keys to handle optional cursorStats
    enum CodingKeys: String, CodingKey {
        case date, projectCount, sessionCount, messageCount, characterCount, projects, cursorStats
    }

    init(date: Date, projectCount: Int, sessionCount: Int, messageCount: Int, characterCount: Int, projects: [ProjectSummary], cursorStats: CursorDailyStats? = nil) {
        self.date = date
        self.projectCount = projectCount
        self.sessionCount = sessionCount
        self.messageCount = messageCount
        self.characterCount = characterCount
        self.projects = projects
        self.cursorStats = cursorStats
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(Date.self, forKey: .date)
        projectCount = try container.decode(Int.self, forKey: .projectCount)
        sessionCount = try container.decode(Int.self, forKey: .sessionCount)
        messageCount = try container.decode(Int.self, forKey: .messageCount)
        characterCount = try container.decode(Int.self, forKey: .characterCount)
        projects = try container.decode([ProjectSummary].self, forKey: .projects)
        cursorStats = try container.decodeIfPresent(CursorDailyStats.self, forKey: .cursorStats)
    }

    /// Format date as localized string
    var formattedDate: String {
        DateFormatting.japaneseLong.string(from: date)
    }

    /// Format date as ISO date string (YYYY-MM-DD)
    var isoDateString: String {
        DateFormatting.iso.string(from: date)
    }

    /// Check if there's any Cursor activity
    var hasCursorActivity: Bool {
        cursorStats?.hasActivity ?? false
    }

    /// Total lines suggested by Cursor (Tab + Composer)
    var cursorTotalSuggested: Int {
        (cursorStats?.tabSuggestedLines ?? 0) + (cursorStats?.composerSuggestedLines ?? 0)
    }

    /// Total lines accepted from Cursor (Tab + Composer)
    var cursorTotalAccepted: Int {
        (cursorStats?.tabAcceptedLines ?? 0) + (cursorStats?.composerAcceptedLines ?? 0)
    }
}

/// Summary of a single project's activity for a day
struct ProjectSummary: Identifiable, Sendable, Codable {
    let id: UUID = UUID()
    let name: String
    let path: String
    let messageCount: Int
    let timeRangeStart: Date
    let timeRangeEnd: Date
    var source: ActivitySource = .claudeCode

    var timeRange: ClosedRange<Date> {
        timeRangeStart...timeRangeEnd
    }

    /// Format time range as "HH:mm - HH:mm"
    var formattedTimeRange: String {
        "\(DateFormatting.time.string(from: timeRange.lowerBound)) - \(DateFormatting.time.string(from: timeRange.upperBound))"
    }

    /// Calculate duration in minutes
    var durationMinutes: Int {
        Int(timeRange.upperBound.timeIntervalSince(timeRange.lowerBound) / 60)
    }

    /// Format duration as "Xh Ym"
    var formattedDuration: String {
        let hours = durationMinutes / 60
        let minutes = durationMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    // Custom coding to skip id
    enum CodingKeys: String, CodingKey {
        case name, path, messageCount, timeRangeStart, timeRangeEnd, source
    }
}
