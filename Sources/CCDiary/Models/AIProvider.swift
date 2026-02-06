import Foundation

/// Available AI providers for diary generation
enum AIProvider: String, CaseIterable {
    case claudeAPI = "claudeAPI"
    case gemini = "gemini"
    case openai = "openai"

    var displayName: String {
        switch self {
        case .claudeAPI:
            return "Claude API"
        case .gemini:
            return "Gemini"
        case .openai:
            return "OpenAI API"
        }
    }

    var keychainService: String {
        switch self {
        case .claudeAPI:
            return KeychainHelper.claudeAPIService
        case .gemini:
            return KeychainHelper.geminiAPIService
        case .openai:
            return KeychainHelper.openAIAPIService
        }
    }
}
