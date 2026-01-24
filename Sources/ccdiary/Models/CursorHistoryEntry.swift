import Foundation

/// Cursor composer session metadata (from composerData:{composerId})
struct CursorComposerData: Codable, Sendable {
    let composerId: String
    let createdAt: Int64? // milliseconds timestamp
    let context: CursorContext?

    struct CursorContext: Codable, Sendable {
        let fileSelections: [FileSelection]?

        struct FileSelection: Codable, Sendable {
            let uri: CursorUri?
        }

        struct CursorUri: Codable, Sendable {
            let path: String?
            let fsPath: String?
        }
    }

    /// Extract project path from file selections
    var projectPath: String? {
        guard let selections = context?.fileSelections,
              let firstFile = selections.first,
              let path = firstFile.uri?.fsPath ?? firstFile.uri?.path else {
            return nil
        }
        // Find git root or use parent directory
        return CursorComposerData.findProjectRoot(from: path)
    }

    /// Find project root from a file path
    private static func findProjectRoot(from path: String) -> String? {
        var current = URL(fileURLWithPath: path).deletingLastPathComponent()
        let fileManager = FileManager.default

        // Walk up to find .git directory
        while current.path != "/" {
            let gitPath = current.appendingPathComponent(".git").path
            if fileManager.fileExists(atPath: gitPath) {
                return current.path
            }
            current = current.deletingLastPathComponent()
        }

        // Fallback: use parent directory of the file
        return URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    /// Session start time
    var startDate: Date? {
        guard let ts = createdAt else { return nil }
        return Date(timeIntervalSince1970: Double(ts) / 1000.0)
    }
}

/// Cursor message bubble (from bubbleId:{composerId}:{bubbleId})
struct CursorBubbleData: Codable, Sendable {
    let type: Int? // 1=user, 2=assistant
    let text: String?
    let tokenCount: TokenCount?
    let timingInfo: TimingInfo?
    let rawPrompt: String? // Tool calls etc.

    struct TokenCount: Codable, Sendable {
        let inputTokens: Int?
        let outputTokens: Int?
    }

    struct TimingInfo: Codable, Sendable {
        let clientStartTime: Int64? // milliseconds
        let clientEndTime: Int64?
    }

    /// Message role
    var role: MessageRole? {
        switch type {
        case 1:
            return .user
        case 2:
            return .assistant
        default:
            return nil
        }
    }

    /// Message content
    var content: String? {
        text
    }

    /// Message timestamp
    var timestamp: Date? {
        guard let timing = timingInfo,
              let ts = timing.clientStartTime else {
            return nil
        }
        return Date(timeIntervalSince1970: Double(ts) / 1000.0)
    }
}

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

/// Aggregated Cursor session for a project
struct CursorSession: Sendable {
    let composerId: String
    let projectPath: String
    let projectName: String
    let messages: [CursorBubbleData]
    let timeRange: ClosedRange<Date>
}
