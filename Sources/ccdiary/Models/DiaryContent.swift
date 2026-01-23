import Foundation

/// Raw diary content returned by AI services (before formatting)
struct DiaryContent: Sendable {
    let date: Date
    let rawMarkdown: String // AI-generated markdown (without header/footer)

    /// ISO format date string (yyyy-MM-dd), derived from date
    var dateString: String {
        DateFormatting.iso.string(from: date)
    }
}
