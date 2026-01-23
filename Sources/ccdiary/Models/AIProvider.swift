import Foundation

/// Available AI providers for diary generation
enum AIProvider: String, CaseIterable {
    case claudeCLI = "claudeCLI"
    case claudeAPI = "claudeAPI"
    case gemini = "gemini"

    var displayName: String {
        switch self {
        case .claudeCLI:
            return "Claude CLI"
        case .claudeAPI:
            return "Claude API"
        case .gemini:
            return "Gemini"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .claudeCLI:
            return false
        case .claudeAPI, .gemini:
            return true
        }
    }

    var keychainService: String? {
        switch self {
        case .claudeCLI:
            return nil
        case .claudeAPI:
            return KeychainHelper.claudeAPIService
        case .gemini:
            return KeychainHelper.geminiAPIService
        }
    }
}
