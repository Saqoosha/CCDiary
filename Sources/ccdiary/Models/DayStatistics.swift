import Foundation

/// Quick statistics for a single day (without full conversation content)
struct DayStatistics: Sendable, Codable {
    let date: Date

    // Claude Code stats
    let ccProjectCount: Int
    let ccSessionCount: Int
    let ccMessageCount: Int

    // Cursor stats
    let cursorProjectCount: Int
    let cursorSessionCount: Int
    let cursorMessageCount: Int

    let projects: [ProjectSummary]

    // Custom coding keys
    enum CodingKeys: String, CodingKey {
        case date, ccProjectCount, ccSessionCount, ccMessageCount
        case cursorProjectCount, cursorSessionCount, cursorMessageCount
        case projects
    }

    init(date: Date,
         ccProjectCount: Int, ccSessionCount: Int, ccMessageCount: Int,
         cursorProjectCount: Int = 0, cursorSessionCount: Int = 0, cursorMessageCount: Int = 0,
         projects: [ProjectSummary]) {
        self.date = date
        self.ccProjectCount = ccProjectCount
        self.ccSessionCount = ccSessionCount
        self.ccMessageCount = ccMessageCount
        self.cursorProjectCount = cursorProjectCount
        self.cursorSessionCount = cursorSessionCount
        self.cursorMessageCount = cursorMessageCount
        self.projects = projects
    }

    // Combined totals
    var projectCount: Int { ccProjectCount + cursorProjectCount }
    var sessionCount: Int { ccSessionCount + cursorSessionCount }
    var messageCount: Int { ccMessageCount + cursorMessageCount }

    /// Format date as localized string
    var formattedDate: String {
        DateFormatting.japaneseLong.string(from: date)
    }

    /// Format date as ISO date string (YYYY-MM-DD)
    var isoDateString: String {
        DateFormatting.iso.string(from: date)
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
