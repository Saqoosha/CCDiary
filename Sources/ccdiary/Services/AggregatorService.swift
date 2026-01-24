import Foundation
import os.log

private let logger = Logger(subsystem: "ccdiary", category: "AggregatorService")

/// Options for aggregation
struct AggregateOptions: Sendable {
    var maxContentLength: Int = 10000
    var maxMessagesPerProject: Int = 1000
}

/// Service for aggregating daily activity data
actor AggregatorService {
    private let historyService = HistoryService()
    private let conversationService = ConversationService()
    private let statisticsCache = StatisticsCache()
    private let cursorService = CursorService()

    /// Aggregate activity data for a specific date
    /// Uses parallel processing for better performance
    func aggregateForDate(_ date: Date, options: AggregateOptions = AggregateOptions()) async throws -> DailyActivity {
        let startTime = CFAbsoluteTimeGetCurrent()
        let dateString = DateFormatting.iso.string(from: date)

        // Read and filter history entries
        let allHistory = try await historyService.readHistory()
        let dayHistory = historyService.filterByDate(allHistory, date: date)
        let projectGroups = historyService.groupByProject(dayHistory)

        // Set up time range for the day
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)?.addingTimeInterval(-1) else {
            throw AggregatorError.invalidDate
        }

        let maxContentLength = options.maxContentLength
        let maxMessagesPerProject = options.maxMessagesPerProject

        // Process projects in parallel
        let projects = try await withThrowingTaskGroup(of: ProjectActivity?.self) { group in
            for (projectPath, entries) in projectGroups {
                group.addTask {
                    // Get user inputs from history (skip commands starting with /)
                    let userInputs = entries
                        .map { $0.display }
                        .filter { !$0.isEmpty && !$0.hasPrefix("/") }

                    // Find conversation files and filter by date index
                    let allFiles = try await self.conversationService.findConversationFiles(projectPath: projectPath)
                    let relevantFiles = await self.conversationService.getFilesForDate(dateString, projectFiles: allFiles)

                    // Process only relevant files in parallel
                    let fileResults = try await withThrowingTaskGroup(of: [(message: ConversationMessage, originalLength: Int)].self) { fileGroup in
                        for file in relevantFiles {
                            fileGroup.addTask {
                                // Use optimized date-range reading
                                let dayEntries = try await self.conversationService.readConversationForDateRange(from: file, start: startOfDay, end: endOfDay)
                                let meaningfulMessages = self.conversationService.filterMeaningfulMessages(dayEntries)

                                var messages: [(message: ConversationMessage, originalLength: Int)] = []

                                for entry in meaningfulMessages {
                                    guard let text = entry.textContent, let message = entry.message else { continue }
                                    guard let entryDate = entry.date else { continue }

                                    let truncatedContent: String
                                    if text.count <= maxContentLength {
                                        truncatedContent = text
                                    } else {
                                        truncatedContent = String(text.prefix(maxContentLength)) + "..."
                                    }

                                    messages.append((
                                        message: ConversationMessage(
                                            role: message.role,
                                            content: truncatedContent,
                                            timestamp: entryDate
                                        ),
                                        originalLength: text.count
                                    ))
                                }

                                return messages
                            }
                        }

                        var allResults: [[(message: ConversationMessage, originalLength: Int)]] = []
                        for try await result in fileGroup {
                            allResults.append(result)
                        }
                        return allResults.flatMap { $0 }
                    }

                    // Aggregate results
                    var allConversations: [ConversationMessage] = []
                    var totalChars = 0
                    var usedChars = 0
                    var truncatedCount = 0

                    for result in fileResults {
                        allConversations.append(result.message)
                        totalChars += result.originalLength
                        usedChars += result.message.content.count
                        if result.originalLength > maxContentLength {
                            truncatedCount += 1
                        }
                    }

                    // Sort conversations by timestamp
                    allConversations.sort { $0.timestamp < $1.timestamp }

                    // Limit messages per project
                    let totalMessages = allConversations.count
                    let conversations: [ConversationMessage]

                    if allConversations.count <= maxMessagesPerProject {
                        conversations = allConversations
                    } else {
                        // Take first half and last half
                        let half = maxMessagesPerProject / 2
                        conversations = Array(allConversations.prefix(half)) + Array(allConversations.suffix(half))
                    }

                    let stats = ProjectStats(
                        totalMessages: totalMessages,
                        usedMessages: conversations.count,
                        totalChars: totalChars,
                        usedChars: usedChars,
                        truncatedCount: truncatedCount
                    )

                    // Calculate time range from history entries
                    let timestamps = entries.map { $0.timestamp }
                    guard let minTime = timestamps.min(), let maxTime = timestamps.max() else {
                        return nil
                    }

                    let startTime = Date(timeIntervalSince1970: Double(minTime) / 1000.0)
                    let endTime = Date(timeIntervalSince1970: Double(maxTime) / 1000.0)

                    return ProjectActivity(
                        path: projectPath,
                        name: HistoryService.getProjectName(projectPath),
                        userInputs: userInputs,
                        conversations: conversations,
                        timeRange: startTime...endTime,
                        stats: stats
                    )
                }
            }

            var collected: [ProjectActivity] = []
            for try await result in group {
                if let result {
                    collected.append(result)
                }
            }
            return collected
        }

        // Get Cursor activity for this date
        var cursorProjects: [ProjectActivity] = []
        let cursorActivities: [CursorProjectActivity]
        do {
            cursorActivities = try await cursorService.getActivityForDate(date)
        } catch {
            logger.warning("Failed to get Cursor activity: \(error.localizedDescription)")
            cursorActivities = []
        }
        for activity in cursorActivities {
            // Convert CursorChatMessage to ConversationMessage
            let conversations = activity.messages.map { msg in
                ConversationMessage(
                    role: msg.role,
                    content: msg.content.count <= maxContentLength
                        ? msg.content
                        : String(msg.content.prefix(maxContentLength)) + "...",
                    timestamp: msg.timestamp ?? activity.timeRangeStart
                )
            }

            // Limit messages
            let limitedConversations: [ConversationMessage]
            if conversations.count <= maxMessagesPerProject {
                limitedConversations = conversations
            } else {
                let half = maxMessagesPerProject / 2
                limitedConversations = Array(conversations.prefix(half)) + Array(conversations.suffix(half))
            }

            let stats = ProjectStats(
                totalMessages: conversations.count,
                usedMessages: limitedConversations.count,
                totalChars: activity.messages.reduce(0) { $0 + $1.content.count },
                usedChars: limitedConversations.reduce(0) { $0 + $1.content.count },
                truncatedCount: 0
            )

            var project = ProjectActivity(
                path: activity.projectPath,
                name: activity.projectName,
                userInputs: activity.messages.filter { $0.role == .user }.map { $0.content },
                conversations: limitedConversations,
                timeRange: activity.timeRange,
                stats: stats
            )
            project.source = .cursor
            cursorProjects.append(project)
        }

        // Combine Claude Code and Cursor projects
        var allProjects = projects + cursorProjects

        // Sort all projects by first activity time
        allProjects.sort { $0.timeRange.lowerBound < $1.timeRange.lowerBound }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        let totalMessages = allProjects.reduce(0) { $0 + $1.conversations.count }
        logger.notice("aggregateForDate(\(dateString)): \(elapsed, format: .fixed(precision: 1))ms (\(allProjects.count) projects, \(totalMessages) messages)")

        return DailyActivity(
            date: date,
            projects: allProjects,
            totalInputs: dayHistory.count
        )
    }

    private func truncateContent(_ content: String, maxLength: Int) -> (String, Bool) {
        if content.count <= maxLength {
            return (content, false)
        }
        return (String(content.prefix(maxLength)) + "...", true)
    }

    /// Get quick statistics for a date (without full conversation content)
    /// This is faster than full aggregation and suitable for calendar display
    /// Uses parallel processing for better performance
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

        var checkpoint = CFAbsoluteTimeGetCurrent()

        let allHistory = try await historyService.readHistory()
        logger.notice("  history read: \((CFAbsoluteTimeGetCurrent() - checkpoint) * 1000, format: .fixed(precision: 1))ms")
        checkpoint = CFAbsoluteTimeGetCurrent()

        let dayHistory = historyService.filterByDate(allHistory, date: date)
        let projectGroups = historyService.groupByProject(dayHistory)

        // Get Cursor daily stats early to check if we have any activity
        var cursorStats: CursorDailyStats?
        do {
            cursorStats = try await cursorService.getDailyStats(for: date)
        } catch {
            logger.warning("Failed to get Cursor daily stats: \(error.localizedDescription)")
            cursorStats = nil
        }

        // Return nil only if we have no Claude Code AND no Cursor activity
        if dayHistory.isEmpty && cursorStats == nil {
            return nil
        }
        logger.notice("  filter/group: \((CFAbsoluteTimeGetCurrent() - checkpoint) * 1000, format: .fixed(precision: 1))ms (\(projectGroups.count) projects)")
        checkpoint = CFAbsoluteTimeGetCurrent()

        // Set up time range for the day
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)?.addingTimeInterval(-1) else {
            throw AggregatorError.invalidDate
        }

        // Result type for parallel processing
        struct ProjectResult: Sendable {
            let summary: ProjectSummary
            let messageCount: Int
            let characterCount: Int
            let sessionIds: Set<String>
        }

        // Process projects in parallel
        let results = try await withThrowingTaskGroup(of: ProjectResult?.self) { group in
            for (projectPath, entries) in projectGroups {
                group.addTask {
                    // Find conversation files and filter by date index
                    let allFiles = try await self.conversationService.findConversationFiles(projectPath: projectPath)
                    let relevantFiles = await self.conversationService.getFilesForDate(dateString, projectFiles: allFiles)

                    logger.notice("  project \(HistoryService.getProjectName(projectPath)): \(allFiles.count) files, \(relevantFiles.count) relevant")

                    // Process only relevant files in parallel
                    let datePrefix = dateString
                    let fileResults = await withTaskGroup(of: (messageCount: Int, characterCount: Int, sessionId: String?).self) { fileGroup in
                        for file in relevantFiles {
                            fileGroup.addTask {
                                // Use fully nonisolated fast stats reading
                                let stats = ConversationService.readStatsFromFileFast(
                                    file,
                                    datePrefix: datePrefix,
                                    start: startOfDay,
                                    end: endOfDay
                                )

                                let sessionId: String? = stats.messageCount > 0
                                    ? file.deletingPathExtension().lastPathComponent
                                    : nil

                                return (stats.messageCount, stats.characterCount, sessionId)
                            }
                        }

                        var results: [(messageCount: Int, characterCount: Int, sessionId: String?)] = []
                        for await result in fileGroup {
                            results.append(result)
                        }
                        return results
                    }

                    // Aggregate file results
                    var projectMessageCount = 0
                    var projectCharacterCount = 0
                    var sessionIds: Set<String> = []

                    for result in fileResults {
                        projectMessageCount += result.messageCount
                        projectCharacterCount += result.characterCount
                        if let sessionId = result.sessionId {
                            sessionIds.insert(sessionId)
                        }
                    }

                    // Calculate time range from history entries
                    let timestamps = entries.map { $0.timestamp }
                    guard let minTime = timestamps.min(), let maxTime = timestamps.max() else {
                        return nil
                    }

                    let startTime = Date(timeIntervalSince1970: Double(minTime) / 1000.0)
                    let endTime = Date(timeIntervalSince1970: Double(maxTime) / 1000.0)

                    let summary = ProjectSummary(
                        name: HistoryService.getProjectName(projectPath),
                        path: projectPath,
                        messageCount: projectMessageCount,
                        timeRangeStart: startTime,
                        timeRangeEnd: endTime
                    )

                    return ProjectResult(
                        summary: summary,
                        messageCount: projectMessageCount,
                        characterCount: projectCharacterCount,
                        sessionIds: sessionIds
                    )
                }
            }

            var collected: [ProjectResult] = []
            for try await result in group {
                if let result {
                    collected.append(result)
                }
            }
            return collected
        }

        logger.notice("  parallel processing: \((CFAbsoluteTimeGetCurrent() - checkpoint) * 1000, format: .fixed(precision: 1))ms")

        // Aggregate results
        var projectSummaries: [ProjectSummary] = []
        var totalMessageCount = 0
        var totalCharacterCount = 0
        var allSessionIds: Set<String> = []

        for result in results {
            projectSummaries.append(result.summary)
            totalMessageCount += result.messageCount
            totalCharacterCount += result.characterCount
            allSessionIds.formUnion(result.sessionIds)
        }

        // Sort projects by first activity time
        projectSummaries.sort { $0.timeRange.lowerBound < $1.timeRange.lowerBound }

        let statistics = DayStatistics(
            date: date,
            projectCount: projectGroups.count,
            sessionCount: allSessionIds.count,
            messageCount: totalMessageCount,
            characterCount: totalCharacterCount,
            projects: projectSummaries,
            cursorStats: cursorStats
        )

        // Cache for past dates
        if StatisticsCache.shouldCache(date: date) {
            await statisticsCache.save(statistics)
        }

        // Persist file date index
        await conversationService.saveDateCache()

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger.notice("getQuickStatistics(\(dateString)): \(elapsed, format: .fixed(precision: 1))ms (\(statistics.projectCount) projects, \(statistics.messageCount) messages)")

        return statistics
    }

    /// Get all dates that have activity in history (Claude Code + Cursor)
    func getAllActivityDates() async throws -> Set<String> {
        let allHistory = try await historyService.readHistory()

        var dates: Set<String> = []
        for entry in allHistory {
            dates.insert(DateFormatting.iso.string(from: entry.date))
        }

        // Also add Cursor dates
        let cursorDates = try await cursorService.getAllDatesWithStats()
        dates.formUnion(cursorDates)

        return dates
    }

    /// Build date index for fast lookups (call at app startup)
    func buildDateIndex() async {
        await conversationService.buildFullDateIndex()
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
