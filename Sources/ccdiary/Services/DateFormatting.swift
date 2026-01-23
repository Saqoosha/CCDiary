import Foundation

/// Cached DateFormatters for consistent date formatting throughout the app
enum DateFormatting {
    /// ISO date format: yyyy-MM-dd
    static let iso: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Japanese long date format
    static let japaneseLong: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter
    }()

    /// Time format: HH:mm
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// Japanese date with day of week: yyyy/MM/dd (E)
    static let japaneseDateWithWeekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd (E)"
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter
    }()

    /// Parse ISO8601 date string with fallback for timestamps without fractional seconds
    /// Note: Creates new formatters each call since ISO8601DateFormatter is not Sendable
    static func parseISO8601(_ string: String) -> Date? {
        let formatterWithFractional = ISO8601DateFormatter()
        formatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatterWithFractional.date(from: string) {
            return date
        }

        let formatterBasic = ISO8601DateFormatter()
        formatterBasic.formatOptions = [.withInternetDateTime]
        return formatterBasic.date(from: string)
    }
}
