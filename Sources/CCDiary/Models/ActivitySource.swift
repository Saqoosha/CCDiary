import Foundation
import SwiftUI

/// Source of activity data
enum ActivitySource: String, CaseIterable, Codable, Sendable {
    case all = "All"
    case claudeCode = "Claude Code"
    case codex = "Codex"
    case cursor = "Cursor"

    /// SF Symbol name for the source
    var iconName: String {
        switch self {
        case .all:
            return "square.stack.3d.up"
        case .claudeCode:
            return "terminal"
        case .codex:
            return "sparkles"
        case .cursor:
            return "cursorarrow.rays"
        }
    }

    /// Brand color for the source
    var color: Color {
        switch self {
        case .all:
            return .primary
        case .claudeCode:
            return Color(red: 0.58, green: 0.44, blue: 0.86) // Claude purple
        case .codex:
            return Color(red: 0.0, green: 0.55, blue: 0.42) // OpenAI green
        case .cursor:
            return Color(red: 0.0, green: 0.48, blue: 1.0) // Cursor blue
        }
    }
}
