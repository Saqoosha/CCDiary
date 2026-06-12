import Foundation

enum HostStatsMergeService {
    /// Merge remote digest payloads into local DailyActivity.
    ///
    /// `excludeProjectSubstrings` is applied to remote digest projects too:
    /// remote hosts may push stats from older binaries (or run automation of
    /// their own), and a name/path filter is the only lever the merging side
    /// has — the source JSONL files live on the remote Mac.
    static func mergeDailyActivity(
        local: DailyActivity,
        remoteDigests: [DigestPayload],
        remoteHosts: [String],
        excludeProjectSubstrings: [String] = []
    ) -> DailyActivity {
        var allProjects = local.projects
        var remoteInputs = 0

        for (index, digest) in remoteDigests.enumerated() {
            let host = index < remoteHosts.count ? remoteHosts[index] : "remote"
            var includedProjects: [DigestProject] = []
            var droppedInputs = 0
            for project in digest.projects {
                if isExcluded(project, substrings: excludeProjectSubstrings) {
                    droppedInputs += project.conversations.filter { $0.role == "user" }.count
                } else {
                    includedProjects.append(project)
                }
            }
            // Digest conversations are the used (possibly truncated) subset,
            // so subtracting them is a best-effort adjustment that keeps the
            // input total close to the projects actually shown.
            remoteInputs += max(0, digest.totalInputs - droppedInputs)
            for digestProject in includedProjects {
                let project = digestProject.toProjectActivity()

                // Tag project name with host origin to distinguish sources.
                let taggedName = "\(project.name) [from \(host)]"

                // Match by path, or by normalized name when the same project
                // lives at a different path on the remote Mac (different
                // checkout location or username). Source must always match.
                // Name matching could in principle conflate two distinct
                // repos sharing a name across Macs — accepted tradeoff: for
                // one user's Macs a wrongly split section is the common
                // failure, a name collision the rare one.
                let baseName = DiaryPromptBuilder.sectionName(for: project.name)
                if let existingIdx = allProjects.firstIndex(where: { existing in
                    guard existing.source == project.source else { return false }
                    return existing.path == project.path ||
                        DiaryPromptBuilder.sectionName(for: existing.name)
                            .caseInsensitiveCompare(baseName) == .orderedSame
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
                    // Keep the plain name — "A + A [from host]" concatenation
                    // leaked host tags into diary section headings.
                    var merged = ProjectActivity(
                        path: existing.path,
                        name: DiaryPromptBuilder.sectionName(for: existing.name),
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
            totalInputs: local.totalInputs + remoteInputs
        )
    }

    private static func isExcluded(_ project: DigestProject, substrings: [String]) -> Bool {
        substrings.contains { sub in
            project.path.localizedCaseInsensitiveContains(sub) ||
                project.name.localizedCaseInsensitiveContains(sub)
        }
    }

    /// Merge multiple DayStatistics into one. Remote projects matching
    /// `excludeProjectSubstrings` are dropped before merging so older remote
    /// binaries can't reinject excluded projects into the cloud stats.
    static func mergeDayStatistics(
        local: DayStatistics,
        remotes: [DayStatistics],
        excludeProjectSubstrings: [String] = []
    ) -> DayStatistics {
        var merged = local
        for rawRemote in remotes {
            let remote = filterExcludedProjects(rawRemote, substrings: excludeProjectSubstrings)
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

    /// Drop excluded projects from a remote DayStatistics and adjust the
    /// per-source counters. Message and project counts adjust exactly from
    /// the dropped summaries; session counts adjust by one per dropped
    /// project — a lower bound, since per-project session counts aren't
    /// carried in ProjectSummary.
    private static func filterExcludedProjects(
        _ stats: DayStatistics,
        substrings: [String]
    ) -> DayStatistics {
        guard !substrings.isEmpty else { return stats }

        var kept: [ProjectSummary] = []
        var droppedProjects: [ActivitySource: Int] = [:]
        var droppedMessages: [ActivitySource: Int] = [:]
        for project in stats.projects {
            let excluded = substrings.contains { sub in
                project.path.localizedCaseInsensitiveContains(sub) ||
                    project.name.localizedCaseInsensitiveContains(sub)
            }
            if excluded {
                droppedProjects[project.source, default: 0] += 1
                droppedMessages[project.source, default: 0] += project.messageCount
            } else {
                kept.append(project)
            }
        }
        guard kept.count != stats.projects.count else { return stats }

        func adjusted(_ count: Int, minus dropped: Int) -> Int { max(0, count - dropped) }
        return DayStatistics(
            date: stats.date,
            ccProjectCount: adjusted(stats.ccProjectCount, minus: droppedProjects[.claudeCode] ?? 0),
            ccSessionCount: adjusted(stats.ccSessionCount, minus: droppedProjects[.claudeCode] ?? 0),
            ccMessageCount: adjusted(stats.ccMessageCount, minus: droppedMessages[.claudeCode] ?? 0),
            cursorProjectCount: adjusted(stats.cursorProjectCount, minus: droppedProjects[.cursor] ?? 0),
            cursorSessionCount: adjusted(stats.cursorSessionCount, minus: droppedProjects[.cursor] ?? 0),
            cursorMessageCount: adjusted(stats.cursorMessageCount, minus: droppedMessages[.cursor] ?? 0),
            codexProjectCount: adjusted(stats.codexProjectCount, minus: droppedProjects[.codex] ?? 0),
            codexSessionCount: adjusted(stats.codexSessionCount, minus: droppedProjects[.codex] ?? 0),
            codexMessageCount: adjusted(stats.codexMessageCount, minus: droppedMessages[.codex] ?? 0),
            projects: kept
        )
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
