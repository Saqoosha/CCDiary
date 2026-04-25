import Foundation
import os.log

private let claudeActivityLogger = Logger(subsystem: "CCDiary", category: "ClaudeCodeActivityReader")

/// Normalizes Claude Code history into shared agent activity.
actor ClaudeCodeActivityReader {
    private let historyService = HistoryService()
    private let conversationService = ConversationService()

    func readActivity(for date: Date, options: AggregateOptions = AggregateOptions()) async throws -> [AgentProjectActivity] {
        let dateString = DateFormatting.iso.string(from: date)
        let allHistory = try await historyService.readHistory()
        let dayHistory = historyService.filterByDate(allHistory, date: date)
        var projectGroups = historyService.groupByProject(dayHistory)

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let startOfNextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            throw AggregatorError.invalidDate
        }

        let discoveredFilesByProject = try await conversationService.findConversationFilesForDateRange(
            start: startOfDay,
            end: startOfNextDay
        )

        for projectPath in discoveredFilesByProject.keys where projectGroups[projectPath] == nil {
            projectGroups[projectPath] = []
        }

        // Drop excluded projects BEFORE opening their JSONL files. Auto-instrumented
        // projects like `claude-mem-observer-sessions` can produce huge logs that
        // hang the reader otherwise.
        if !options.excludeProjectSubstrings.isEmpty {
            let beforeCount = projectGroups.count
            projectGroups = projectGroups.filter { path, _ in
                !options.excludeProjectSubstrings.contains { sub in
                    path.localizedCaseInsensitiveContains(sub)
                }
            }
            let dropped = beforeCount - projectGroups.count
            if dropped > 0 {
                claudeActivityLogger.notice("readActivity: skipped \(dropped) excluded Claude Code project(s)")
            }
        }

        guard !projectGroups.isEmpty else {
            return []
        }

        let projects = try await withThrowingTaskGroup(of: AgentProjectActivity?.self) { group in
            for (projectPath, entries) in projectGroups {
                let discoveredFiles = discoveredFilesByProject[projectPath] ?? []
                group.addTask {
                    let historyInputs = entries
                        .map { $0.display }
                        .filter { !$0.isEmpty && !$0.hasPrefix("/") }

                    let allFiles: [URL]
                    let relevantFiles: [URL]
                    if discoveredFiles.isEmpty {
                        allFiles = try await self.conversationService.findConversationFiles(projectPath: projectPath)
                        let indexedFiles = await self.conversationService.getFilesForDate(dateString, projectFiles: allFiles)
                        relevantFiles = indexedFiles.isEmpty ? allFiles : indexedFiles
                    } else {
                        allFiles = discoveredFiles
                        relevantFiles = discoveredFiles
                    }

                    let messages = try await withThrowingTaskGroup(of: [AgentActivityMessage].self) { fileGroup in
                        for file in relevantFiles {
                            fileGroup.addTask {
                                let sessionId = file.deletingPathExtension().lastPathComponent
                                let dayEntries = try await self.conversationService.readConversationForDateRange(
                                    from: file,
                                    start: startOfDay,
                                    end: startOfNextDay
                                )
                                let meaningfulMessages = self.conversationService.filterMeaningfulMessages(dayEntries)

                                return meaningfulMessages.compactMap { entry -> AgentActivityMessage? in
                                    guard let text = entry.textContent,
                                          let message = entry.message,
                                          let timestamp = entry.date else {
                                        return nil
                                    }

                                    return AgentActivityMessage(
                                        role: message.role,
                                        content: text,
                                        timestamp: timestamp,
                                        sessionId: sessionId
                                    )
                                }
                            }
                        }

                        var collected: [AgentActivityMessage] = []
                        for try await fileMessages in fileGroup {
                            collected.append(contentsOf: fileMessages)
                        }
                        return collected
                    }

                    let timestamps = entries.map { $0.timestamp }
                    let historyTimes = timestamps.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
                    let messageTimes = messages.map(\.timestamp)
                    let allTimes = historyTimes + messageTimes
                    guard let minTime = allTimes.min(), let maxTime = allTimes.max() else {
                        return nil
                    }

                    let messageInputs = messages
                        .filter { $0.role == .user }
                        .map { $0.content }
                        .filter { content in
                            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                            return !trimmed.isEmpty && !trimmed.hasPrefix("/")
                        }

                    let userInputs = historyInputs.isEmpty ? messageInputs : historyInputs
                    let timeRange = minTime...maxTime
                    let sessionIds = Set(messages.compactMap(\.sessionId))

                    return AgentProjectActivity(
                        source: .claudeCode,
                        path: projectPath,
                        name: HistoryService.getProjectName(projectPath),
                        userInputs: userInputs,
                        messages: messages.sorted { $0.timestamp < $1.timestamp },
                        sessionIds: sessionIds,
                        timeRange: timeRange
                    )
                }
            }

            var collected: [AgentProjectActivity] = []
            for try await project in group {
                if let project {
                    collected.append(project)
                }
            }
            return collected
        }

        claudeActivityLogger.notice("readActivity(\(dateString)): \(projects.count) Claude Code projects")
        return projects
    }

    func readActivityDates() async -> Set<String> {
        await conversationService.getAllDatesWithConversations()
    }

    func buildDateIndex() async {
        await conversationService.buildFullDateIndex()
    }

    func saveDateIndex() async {
        await conversationService.saveDateCache()
    }
}
