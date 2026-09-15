import Foundation

/// Normalized chat message from any supported coding agent.
struct AgentActivityMessage: Identifiable, Sendable {
    let id = UUID()
    let role: MessageRole
    let content: String
    let timestamp: Date
    let sessionId: String?
}

/// Normalized project-level activity from Claude Code, Codex, Cursor, or future agents.
struct AgentProjectActivity: Identifiable, Sendable {
    let id = UUID()
    let source: ActivitySource
    let path: String
    let name: String
    let userInputs: [String]
    let messages: [AgentActivityMessage]
    let sessionIds: Set<String>
    let timeRange: ClosedRange<Date>

    func toProjectActivity(maxContentLength: Int, maxMessagesPerProject: Int) -> ProjectActivity {
        let sortedMessages = messages.sorted { $0.timestamp < $1.timestamp }
        let conversations = ActivityDigestBuilder.conversations(
            from: sortedMessages,
            source: source,
            projectName: name,
            projectPath: path,
            maxContentLength: maxContentLength,
            maxMessagesPerProject: maxMessagesPerProject
        )

        let totalChars = sortedMessages.reduce(0) { $0 + $1.content.count }
        let usedChars = conversations.reduce(0) { $0 + $1.content.count }
        let contentTruncatedCount = sortedMessages.filter { $0.content.count > maxContentLength }.count
        let digestCondensedCount = max(0, sortedMessages.count - conversations.count)

        let stats = ProjectStats(
            totalMessages: sortedMessages.count,
            usedMessages: conversations.count,
            totalChars: totalChars,
            usedChars: usedChars,
            truncatedCount: contentTruncatedCount + digestCondensedCount
        )

        var project = ProjectActivity(
            path: path,
            name: name,
            userInputs: userInputs,
            conversations: conversations,
            timeRange: timeRange,
            stats: stats
        )
        project.source = source
        return project
    }

    func toProjectSummary() -> ProjectSummary {
        var summary = ProjectSummary(
            name: name,
            path: path,
            messageCount: messages.count,
            timeRangeStart: timeRange.lowerBound,
            timeRangeEnd: timeRange.upperBound
        )
        summary.source = source
        return summary
    }
}

enum AgentActivityUtilities {
    /// What a git worktree path resolves to. `parentPath` is nil when the shape
    /// names the project but not where the repository lives.
    struct WorktreeInfo: Equatable {
        let projectName: String
        let parentPath: String?
    }

    /// Repository a linked worktree belongs to, or nil when `path` is not a worktree.
    static func worktreeParentPath(for path: String) -> String? {
        worktreeInfo(for: path)?.parentPath
    }

    static func isWorktreePath(_ path: String) -> Bool {
        worktreeInfo(for: path) != nil
    }

    /// Project name for a session cwd: the parent repository's name when `path`
    /// is a worktree, else the last path component, else `fallback`.
    static func projectName(from path: String, fallback: String) -> String {
        let standardized = (path as NSString).standardizingPath
        if let info = worktreeInfo(for: standardized) {
            return info.projectName
        }
        let lastComponent = (standardized as NSString).lastPathComponent
        return lastComponent.isEmpty ? fallback : lastComponent
    }

    /// `<path>/.git` is authoritative when present: a directory is a plain
    /// checkout, a file is a linked worktree whose `gitdir:` names the repository
    /// (submodules also use a file, but point at `.git/modules/`, so they are not
    /// matched). Only when `.git` is absent — the worktree has been deleted — is
    /// the path shape consulted.
    static func worktreeInfo(for path: String) -> WorktreeInfo? {
        let standardized = (path as NSString).standardizingPath
        let gitPath = (standardized as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        if !isUnderTCCProtectedFolder(standardized),
           FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return nil }
            return linkedWorktreeInfo(gitFile: gitPath, worktreeDir: standardized)
        }
        return shapeWorktreeInfo(components: pathComponents(standardized))
    }

    private static func linkedWorktreeInfo(gitFile: String, worktreeDir: String) -> WorktreeInfo? {
        guard let contents = try? String(contentsOfFile: gitFile, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("gitdir: ") else { return nil }
        var target = String(trimmed.dropFirst("gitdir: ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !target.hasPrefix("/") {
            // `git worktree add --relative-paths` writes `../../.git/worktrees/<name>`.
            target = ((worktreeDir as NSString).appendingPathComponent(target) as NSString).standardizingPath
        }
        guard let range = target.range(of: "/.git/worktrees/") else { return nil }
        let repo = String(target[..<range.lowerBound])
        let name = (repo as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        return WorktreeInfo(projectName: name, parentPath: repo)
    }

    /// Shapes recognised without touching the filesystem:
    /// - `~/.claude/worktrees/<Project>/<name>` — any dot-directory directly under
    ///   the home directory (`.cursor`, `.superset`, …) is treated the same way;
    ///   the repository path is unknown.
    /// - `<Repo>/.claude/worktrees/<name>` — Claude Code's earlier, repo-local layout.
    /// - `<Repo>/worktrees/<name>` and `<Repo>/.worktrees/<name>`.
    /// Deeper paths (a session started in a subdirectory of the worktree) match too.
    private static func shapeWorktreeInfo(components: [String]) -> WorktreeInfo? {
        guard let index = components.lastIndex(where: { $0 == "worktrees" || $0 == ".worktrees" }),
              index >= 1, index < components.count - 1 else { return nil }
        let container = components[index - 1]
        if components[index] == "worktrees", container.hasPrefix(".") {
            let containerParent = "/" + components[..<(index - 1)].joined(separator: "/")
            if containerParent == homeDirectory {
                return WorktreeInfo(projectName: components[index + 1], parentPath: nil)
            }
            guard index >= 2 else { return nil }
            return WorktreeInfo(projectName: components[index - 2], parentPath: containerParent)
        }
        return WorktreeInfo(projectName: container, parentPath: "/" + components[..<index].joined(separator: "/"))
    }

    private static let homeDirectory = (NSHomeDirectory() as NSString).standardizingPath

    /// The 04:00 LaunchAgent runs headless; opening a file under these folders
    /// would raise a TCC prompt nobody can answer (see AGENTS.md, "Unattended runs").
    private static func isUnderTCCProtectedFolder(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return ["Documents", "Desktop", "Downloads"].contains { folder in
            let prefix = (homeDirectory as NSString).appendingPathComponent(folder)
            return resolved == prefix || resolved.hasPrefix(prefix + "/")
        }
    }

    private static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func commonAncestor(for paths: [String]) -> String? {
        let components = paths
            .filter { !$0.isEmpty }
            .map { path -> [String] in
                let url = URL(fileURLWithPath: path)
                let candidate = pathHasFileExtension(path) ? url.deletingLastPathComponent().path : url.path
                return candidate.split(separator: "/").map(String.init)
            }

        guard var common = components.first, !common.isEmpty else { return nil }

        for pathComponents in components.dropFirst() {
            var prefixLength = 0
            while prefixLength < common.count &&
                  prefixLength < pathComponents.count &&
                  common[prefixLength] == pathComponents[prefixLength] {
                prefixLength += 1
            }
            common = Array(common.prefix(prefixLength))
            if common.isEmpty { return nil }
        }

        return "/" + common.joined(separator: "/")
    }

    private static func pathHasFileExtension(_ path: String) -> Bool {
        !(path as NSString).pathExtension.isEmpty
    }
}
