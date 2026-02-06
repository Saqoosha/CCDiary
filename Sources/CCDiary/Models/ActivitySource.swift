import Foundation
import SwiftUI

/// Source of activity data
enum ActivitySource: String, CaseIterable, Codable, Sendable {
    case all = "All"
    case claudeCode = "Claude Code"
    case cursor = "Cursor"
    case codex = "Codex"

    /// SF Symbol name for the source
    var iconName: String {
        switch self {
        case .all:
            return "square.stack.3d.up"
        case .claudeCode:
            return "terminal"
        case .cursor:
            return "cursorarrow.rays"
        case .codex:
            return "terminal.fill"
        }
    }

    /// Brand color for the source
    var color: Color {
        switch self {
        case .all:
            return .primary
        case .claudeCode:
            return Color(red: 0.58, green: 0.44, blue: 0.86) // Claude purple
        case .cursor:
            return Color(red: 0.0, green: 0.48, blue: 1.0) // Cursor blue
        case .codex:
            return Color(red: 0.08, green: 0.65, blue: 0.62) // Codex teal
        }
    }
}
