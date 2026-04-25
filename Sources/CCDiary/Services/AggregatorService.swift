import Foundation
import os.log

private let logger = Logger(subsystem: "CCDiary", category: "AggregatorService")

/// Options for aggregation
struct AggregateOptions: Sendable {
    var maxContentLength: Int = 10000
    var maxMessagesPerProject: Int = 1000
}

/// Service for aggregating daily activity data
actor AggregatorService {
    private let claudeReader = ClaudeCodeActivityReader()
    private let codexReader = CodexActivityReader()
    private let cursorReader = CursorActivityReader()
    private let statisticsCache = StatisticsCache()

    /// Aggregate activity data for a specific date
    /// Uses parallel processing for better performance
    func aggregateForDate(_ date: Date, options: AggregateOptions = AggregateOptions()) async throws -> DailyActivity {
        let startTime = CFAbsoluteTimeGetCurrent()
        let dateString = DateFormatting.iso.string(from: date)

        let agentProjects = await readAllAgentProjects(for: date, options: options)
        var allProjects = agentProjects.map {
            $0.toProjectActivity(
                maxContentLength: options.maxContentLength,
                maxMessagesPerProject: options.maxMessagesPerProject
            )
        }

        // Sort all projects by first activity time
        allProjects.sort { $0.timeRange.lowerBound < $1.timeRange.lowerBound }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        let totalMessages = allProjects.reduce(0) { $0 + $1.conversations.count }
        logger.notice("aggregateForDate(\(dateString)): \(elapsed, format: .fixed(precision: 1))ms (\(allProjects.count) projects, \(totalMessages) messages)")

        return DailyActivity(
            date: date,
            projects: allProjects,
            totalInputs: agentProjects.reduce(0) { $0 + $1.userInputs.count }
        )
    }

    private func readAllAgentProjects(
        for date: Date,
        options: AggregateOptions = AggregateOptions()
    ) async -> [AgentProjectActivity] {
        let claudeReader = self.claudeReader
        let codexReader = self.codexReader
        let cursorReader = self.cursorReader

        return await withTaskGroup(of: [AgentProjectActivity].self) { group in
            group.addTask {
                do {
                    return try await claudeReader.readActivity(for: date, options: options)
                } catch {
                    logger.warning("Failed to read Claude Code activity: \(error.localizedDescription)")
                    return []
                }
            }

            group.addTask {
                do {
                    return try await codexReader.readActivity(for: date, options: options)
                } catch {
                    logger.warning("Failed to read Codex activity: \(error.localizedDescription)")
                    return []
                }
            }

            group.addTask {
                do {
                    return try await cursorReader.readActivity(for: date, options: options)
                } catch {
                    logger.warning("Failed to read Cursor activity: \(error.localizedDescription)")
                    return []
                }
            }

            var projects: [AgentProjectActivity] = []
            for await result in group {
                projects.append(contentsOf: result)
            }
            return projects
        }
    }

    /// Get quick statistics for a date.
    func getQuickStatistics(for date: Date) async throws -> DayStatistics? {
        let startTime = CFAbsoluteTimeGetCurrent()
        let dateString = DateFormatting.iso.string(from: date)

        // Check cache first for past dates
        if StatisticsCache.shouldCache(date: date),
           let cached = await statisticsCache.get(for: dateString) {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            logger.notice("getQuickStatistics(\(dateString)): \(elapsed, format: .fixed(precision: 1))ms (cached)")
            return cached
        }

        let agentProjects = await readAllAgentProjects(for: date)
        if agentProjects.isEmpty {
            return nil
        }

        let projectSummaries = agentProjects
            .map { $0.toProjectSummary() }
            .sorted { $0.timeRange.lowerBound < $1.timeRange.lowerBound }

        func counts(for source: ActivitySource) -> (projects: Int, sessions: Int, messages: Int) {
            let projects = agentProjects.filter { $0.source == source }
            let sessions = projects.reduce(0) { $0 + max($1.sessionIds.count, 1) }
            let messages = projects.reduce(0) { $0 + $1.messages.count }
            return (projects.count, sessions, messages)
        }

        let claudeCounts = counts(for: .claudeCode)
        let cursorCounts = counts(for: .cursor)
        let codexCounts = counts(for: .codex)

        let statistics = DayStatistics(
            date: date,
            ccProjectCount: claudeCounts.projects,
            ccSessionCount: claudeCounts.sessions,
            ccMessageCount: claudeCounts.messages,
            cursorProjectCount: cursorCounts.projects,
            cursorSessionCount: cursorCounts.sessions,
            cursorMessageCount: cursorCounts.messages,
            codexProjectCount: codexCounts.projects,
            codexSessionCount: codexCounts.sessions,
            codexMessageCount: codexCounts.messages,
            projects: projectSummaries
        )

        // Cache for past dates
        if StatisticsCache.shouldCache(date: date) {
            await statisticsCache.save(statistics)
        }

        // Persist file date index
        await claudeReader.saveDateIndex()

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger.notice("getQuickStatistics(\(dateString)): \(elapsed, format: .fixed(precision: 1))ms (CC: \(statistics.ccProjectCount) proj/\(statistics.ccMessageCount) msgs, Codex: \(statistics.codexProjectCount) proj/\(statistics.codexMessageCount) msgs, Cursor: \(statistics.cursorProjectCount) proj/\(statistics.cursorMessageCount) msgs)")

        return statistics
    }

    /// Get all dates that have activity (Claude Code + Codex + Cursor)
    func getAllActivityDates() async throws -> Set<String> {
        var dates: Set<String> = []

        let ccDates = await claudeReader.readActivityDates()
        logger.notice("getAllActivityDates: CC dates = \(ccDates.count) [\(ccDates.sorted().suffix(5).joined(separator: ", "))]")
        dates.formUnion(ccDates)

        let codexDates = await codexReader.readActivityDates()
        logger.notice("getAllActivityDates: Codex dates = \(codexDates.count) [\(codexDates.sorted().suffix(5).joined(separator: ", "))]")
        dates.formUnion(codexDates)

        do {
            let cursorDates = try await cursorReader.readActivityDates()
            logger.notice("getAllActivityDates: Cursor dates = \(cursorDates.count) [\(cursorDates.sorted().suffix(5).joined(separator: ", "))]")
            dates.formUnion(cursorDates)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning("Failed to get Cursor dates: \(error.localizedDescription)")
        }

        logger.notice("getAllActivityDates: Total = \(dates.count) dates")
        return dates
    }

    /// Build date index for fast lookups (call at app startup)
    func buildDateIndex(progressCallback: (@MainActor @Sendable (String) -> Void)? = nil) async {
        await progressCallback?("Building Claude Code index...")
        await claudeReader.buildDateIndex()

        await progressCallback?("Preparing Codex index...")
        _ = await codexReader.readActivityDates()

        await progressCallback?("Building Cursor index...")
        do {
            try await cursorReader.buildDateIndexIfNeeded()
        } catch {
            logger.warning("Failed to build Cursor date index: \(error.localizedDescription)")
        }
    }
}

enum AggregatorError: LocalizedError {
    case invalidDate

    var errorDescription: String? {
        switch self {
        case .invalidDate:
            return "Invalid date provided"
        }
    }
}
