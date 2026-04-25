import Foundation
import os.log

private let logger = Logger(subsystem: "CCDiary", category: "AggregatorService")

/// Options for aggregation
struct AggregateOptions: Sendable {
    var maxContentLength: Int = 10000
    var maxMessagesPerProject: Int = 1000
    /// Skip Cursor scan entirely. Escape hatch for the case where the global
    /// `state.vscdb` has grown pathologically large; the CursorService bubble
    /// index is the proper fix and this flag exists as a fallback.
    var excludeCursor: Bool = false
    /// Per-source timeout in seconds. `0` (default) disables the timeout to
    /// preserve existing call-sites' behavior; the LaunchAgent sets a finite
    /// value so unattended runs can't hang forever on a single bad reader.
    var perSourceTimeoutSeconds: Double = 0
    /// Substrings to match against project name/path. Any project whose name
    /// or path contains one of these is dropped. Useful for ignoring
    /// auto-instrumented projects like `claude-mem-observer-sessions` that
    /// generate huge JSONL files but no useful diary content.
    var excludeProjectSubstrings: [String] = []
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

        let rawAgentProjects = await readAllAgentProjects(for: date, options: options)
        let agentProjects = Self.filterExcludedProjects(rawAgentProjects, options: options)
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
        let timeout = options.perSourceTimeoutSeconds
        let excludeCursor = options.excludeCursor

        return await withTaskGroup(of: [AgentProjectActivity].self) { group in
            group.addTask {
                (try? await Self.runWithTimeout(label: "Claude Code", seconds: timeout) {
                    try await claudeReader.readActivity(for: date, options: options)
                }) ?? []
            }

            group.addTask {
                (try? await Self.runWithTimeout(label: "Codex", seconds: timeout) {
                    try await codexReader.readActivity(for: date, options: options)
                }) ?? []
            }

            if !excludeCursor {
                group.addTask {
                    (try? await Self.runWithTimeout(label: "Cursor", seconds: timeout) {
                        try await cursorReader.readActivity(for: date, options: options)
                    }) ?? []
                }
            }

            var projects: [AgentProjectActivity] = []
            for await result in group {
                projects.append(contentsOf: result)
            }
            return projects
        }
    }

    /// Drops any project whose path or name contains one of the configured
    /// substrings (case-insensitive). Belt-and-braces with the per-reader
    /// pre-scan filter — protects sources that don't honor the option yet.
    private static func filterExcludedProjects(
        _ projects: [AgentProjectActivity],
        options: AggregateOptions
    ) -> [AgentProjectActivity] {
        guard !options.excludeProjectSubstrings.isEmpty else { return projects }
        return projects.filter { project in
            !options.excludeProjectSubstrings.contains { sub in
                project.path.localizedCaseInsensitiveContains(sub) ||
                    project.name.localizedCaseInsensitiveContains(sub)
            }
        }
    }

    /// Runs `body` with an optional timeout. Errors and timeouts degrade to an
    /// empty result so a single bad source can't take down the aggregate run;
    /// `CancellationError` propagates so a parent-task cancel still reaches the
    /// caller. `seconds <= 0` disables the timeout. Timeout events are
    /// surfaced to stderr (not just os_log) so unattended LaunchAgent runs
    /// leave a visible trail in `daily.err.log`.
    ///
    /// Caveat: SQLite scans inside `CursorService` aren't cooperative
    /// cancellation points, so the body task can keep running in the background
    /// after the timeout fires. Subsequent calls into the same actor will
    /// serialize behind it.
    private static func runWithTimeout(
        label: String,
        seconds: Double,
        body: @escaping @Sendable () async throws -> [AgentProjectActivity]
    ) async throws -> [AgentProjectActivity] {
        if seconds <= 0 {
            do {
                return try await body()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.warning("Failed to read \(label) activity: \(error.localizedDescription)")
                return []
            }
        }

        struct TimedOut: Error {
            let label: String
            let seconds: Double
        }

        let result = await withTaskGroup(of: Result<[AgentProjectActivity], Error>.self) { group -> Result<[AgentProjectActivity], Error> in
            group.addTask {
                do { return .success(try await body()) }
                catch { return .failure(error) }
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    return .failure(TimedOut(label: label, seconds: seconds))
                } catch {
                    // Sleep cancelled (the body finished first or the parent
                    // task was cancelled). Suspend forever so this loser never
                    // races ahead of the body's real result.
                    try? await Task.sleep(nanoseconds: .max)
                    return .failure(CancellationError())
                }
            }
            defer { group.cancelAll() }
            return await group.next() ?? .success([])
        }

        switch result {
        case .success(let projects):
            return projects
        case .failure(let error as TimedOut):
            let message = "\(error.label) reader exceeded \(Int(error.seconds))s timeout; skipping for this date"
            logger.warning("\(message)")
            fputs("Warning: \(message)\n", stderr)
            return []
        case .failure(is CancellationError):
            throw CancellationError()
        case .failure(let error):
            logger.warning("Failed to read \(label) activity: \(error.localizedDescription)")
            return []
        }
    }

    /// Get quick statistics for a date.
    func getQuickStatistics(for date: Date, options: AggregateOptions = AggregateOptions()) async throws -> DayStatistics? {
        let startTime = CFAbsoluteTimeGetCurrent()
        let dateString = DateFormatting.iso.string(from: date)

        // Check cache first for past dates
        if StatisticsCache.shouldCache(date: date),
           let cached = await statisticsCache.get(for: dateString) {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            logger.notice("getQuickStatistics(\(dateString)): \(elapsed, format: .fixed(precision: 1))ms (cached)")
            return cached
        }

        let rawAgentProjects = await readAllAgentProjects(for: date, options: options)
        let agentProjects = Self.filterExcludedProjects(rawAgentProjects, options: options)
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
