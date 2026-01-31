import Foundation

/// Generated diary entry
struct DiaryEntry: Identifiable, Codable, Sendable {
    var id: String { dateString }
    let dateString: String  // YYYY-MM-DD format
    let markdown: String
    let generatedAt: Date

    var date: Date? {
        DateFormatting.iso.string(from: generatedAt) == dateString
            ? generatedAt
            : DateFormatting.iso.date(from: dateString)
    }

    /// Formatted display date in Japanese
    var formattedDate: String {
        guard let date = date else { return dateString }
        return DateFormatting.japaneseLong.string(from: date)
    }
}

/// Diary generation state
enum DiaryGenerationState: Sendable {
    case idle
    case loading(progress: String)
    case success(DiaryEntry)
    case error(String)
}
