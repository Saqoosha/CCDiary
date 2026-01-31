import Foundation

/// Cursor daily stats (from aiCodeTracking.dailyStats.v1.5.{YYYY-MM-DD})
struct CursorDailyStats: Codable, Sendable {
    let tabSuggestedLines: Int?
    let tabAcceptedLines: Int?
    let composerSuggestedLines: Int?
    let composerAcceptedLines: Int?

    /// Check if has any meaningful stats
    var hasActivity: Bool {
        (tabSuggestedLines ?? 0) > 0 ||
        (tabAcceptedLines ?? 0) > 0 ||
        (composerSuggestedLines ?? 0) > 0 ||
        (composerAcceptedLines ?? 0) > 0
    }
}
