import Foundation

/// Available AI providers for diary generation
enum AIProvider: String, CaseIterable {
    case claudeAPI = "claudeAPI"
    case gemini = "gemini"

    var displayName: String {
        switch self {
        case .claudeAPI:
            return "Claude API"
        case .gemini:
            return "Gemini"
        }
    }

    var requiresAPIKey: Bool {
        return true
    }

    var keychainService: String? {
        switch self {
        case .claudeAPI:
            return KeychainHelper.claudeAPIService
        case .gemini:
            return KeychainHelper.geminiAPIService
        }
    }
}
