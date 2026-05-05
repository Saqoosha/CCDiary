import Foundation

enum HostStatsMergeService {
    /// Merge remote digest payloads into local DailyActivity.
    static func mergeDailyActivity(
        local: DailyActivity,
        remoteDigests: [DigestPayload],
        remoteHosts: [String]
    ) -> DailyActivity {
        var allProjects = local.projects

        for (index, digest) in remoteDigests.enumerated() {
            let host = index < remoteHosts.count ? remoteHosts[index] : "remote"
            for digestProject in digest.projects {
                var project = digestProject.toProjectActivity()

                // Tag project name with host origin to distinguish sources.
                let taggedName = "\(project.name) [from \(host)]"

                // Check if same project exists locally (same path + source).
                if let existingIdx = allProjects.firstIndex(where: {
                    $0.path == project.path && $0.source == project.source
                }) {
                    // Merge: interleave conversations by timestamp, deduplicated by (timestamp, role, content).
                    let existing = allProjects[existingIdx]
                    var seen = Set<String>()
                    let mergedConversations = (existing.conversations + project.conversations)
                        .filter { msg in
                            let key = "\(Int(msg.timestamp.timeIntervalSince1970))|\(msg.role.rawValue)|\(msg.content.hashValue)"
                            return seen.insert(key).inserted
                        }
                        .sorted { $0.timestamp < $1.timestamp }
                    let mergedRange = min(
                        existing.timeRange.lowerBound, project.timeRange.lowerBound
                    )...max(
                        existing.timeRange.upperBound, project.timeRange.upperBound
                    )
                    var mergedInputs = existing.userInputs
                    for input in project.userInputs where !mergedInputs.contains(input) {
                        mergedInputs.append(input)
                    }
                    let mergedStats = ProjectStats(
                        totalMessages: existing.stats.totalMessages + project.stats.totalMessages,
                        usedMessages: existing.stats.usedMessages + project.stats.usedMessages,
                        totalChars: existing.stats.totalChars + project.stats.totalChars,
                        usedChars: existing.stats.usedChars + project.stats.usedChars,
                        truncatedCount: existing.stats.truncatedCount + project.stats.truncatedCount
                    )
                    var merged = ProjectActivity(
                        path: existing.path,
                        name: "\(existing.name) + \(taggedName)",
                        userInputs: mergedInputs,
                        conversations: mergedConversations,
                        timeRange: mergedRange,
                        stats: mergedStats
                    )
                    merged.source = existing.source
                    allProjects[existingIdx] = merged
                } else {
                    // New project from remote: tag and add.
                    var tagged = ProjectActivity(
                        path: project.path,
                        name: taggedName,
                        userInputs: project.userInputs,
                        conversations: project.conversations,
                        timeRange: project.timeRange,
                        stats: project.stats
                    )
                    tagged.source = project.source
                    allProjects.append(tagged)
                }
            }
        }

        allProjects.sort { $0.timeRange.lowerBound < $1.timeRange.lowerBound }
        return DailyActivity(
            date: local.date,
            projects: allProjects,
            totalInputs: local.totalInputs + remoteDigests.reduce(0) { $0 + $1.totalInputs }
        )
    }

    /// Merge multiple DayStatistics into one.
    static func mergeDayStatistics(
        local: DayStatistics,
        remotes: [DayStatistics]
    ) -> DayStatistics {
        var merged = local
        for remote in remotes {
            merged = DayStatistics(
                date: merged.date,
                ccProjectCount: merged.ccProjectCount + remote.ccProjectCount,
                ccSessionCount: merged.ccSessionCount + remote.ccSessionCount,
                ccMessageCount: merged.ccMessageCount + remote.ccMessageCount,
                cursorProjectCount: merged.cursorProjectCount + remote.cursorProjectCount,
                cursorSessionCount: merged.cursorSessionCount + remote.cursorSessionCount,
                cursorMessageCount: merged.cursorMessageCount + remote.cursorMessageCount,
                codexProjectCount: merged.codexProjectCount + remote.codexProjectCount,
                codexSessionCount: merged.codexSessionCount + remote.codexSessionCount,
                codexMessageCount: merged.codexMessageCount + remote.codexMessageCount,
                projects: mergeProjectSummaries(merged.projects, remote.projects)
            )
        }
        return merged
    }

    private static func mergeProjectSummaries(
        _ local: [ProjectSummary],
        _ remote: [ProjectSummary]
    ) -> [ProjectSummary] {
        var merged = local
        for remoteProject in remote {
            if let idx = merged.firstIndex(where: { $0.id == remoteProject.id }) {
                let existing = merged[idx]
                let expanded = ProjectSummary(
                    name: existing.name,
                    path: existing.path,
                    messageCount: existing.messageCount + remoteProject.messageCount,
                    timeRangeStart: min(existing.timeRangeStart, remoteProject.timeRangeStart),
                    timeRangeEnd: max(existing.timeRangeEnd, remoteProject.timeRangeEnd)
                )
                var summary = expanded
                summary.source = existing.source
                merged[idx] = summary
            } else {
                merged.append(remoteProject)
            }
        }
        return merged
    }
}
