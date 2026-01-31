import Foundation

/// Protocol for AI diary generation services
protocol DiaryGenerator: Actor {
    /// Generate diary content from aggregated activity data
    func generateDiary(activity: DailyActivity) async throws -> DiaryContent
}
