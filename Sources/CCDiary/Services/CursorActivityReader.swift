import Foundation

/// Normalizes Cursor chat history into shared agent activity.
actor CursorActivityReader {
    private let cursorService = CursorService()

    func readActivity(for date: Date, options: AggregateOptions = AggregateOptions()) async throws -> [AgentProjectActivity] {
        let activities = try await cursorService.getActivityForDate(date)

        return activities.map { activity in
            let messages = activity.messages.map { message in
                AgentActivityMessage(
                    role: message.role,
                    content: message.content,
                    timestamp: message.timestamp ?? activity.timeRangeStart,
                    sessionId: nil
                )
            }

            return AgentProjectActivity(
                source: .cursor,
                path: activity.projectPath,
                name: activity.projectName,
                userInputs: activity.messages.filter { $0.role == .user }.map(\.content),
                messages: messages,
                sessionIds: activity.composerIds,
                timeRange: activity.timeRange
            )
        }
    }

    func readActivityDates() async throws -> Set<String> {
        try await cursorService.getAllDatesWithMessages()
    }

    func buildDateIndexIfNeeded() async throws {
        _ = try await cursorService.buildDateIndexIfNeeded()
    }
}
