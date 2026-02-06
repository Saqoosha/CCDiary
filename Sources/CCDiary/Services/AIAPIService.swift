import Foundation

/// Common interface for provider-specific AI API services.
protocol AIAPIService: Sendable {
    func generateDiary(activity: DailyActivity, apiKey: String, model: String) async throws -> DiaryContent
}

enum AIAPIError: LocalizedError {
    case invalidResponse(provider: AIProvider)
    case invalidResponseFormat(provider: AIProvider, responseBody: String?)
    case incompleteResponse(provider: AIProvider, reason: String, responseBody: String?)
    case apiError(provider: AIProvider, statusCode: Int, message: String)
    case missingAPIKey(provider: AIProvider)

    var isRetryable: Bool {
        switch self {
        case .apiError(_, let statusCode, _):
            return statusCode == 429 || (500...599).contains(statusCode)
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let provider):
            return "Invalid response from \(provider.displayName)"
        case .invalidResponseFormat(let provider, let responseBody):
            guard let responseBody else {
                return "Unexpected response format from \(provider.displayName)"
            }
            let snippet = responseBody.count > 600 ? String(responseBody.prefix(600)) + "..." : responseBody
            return "Unexpected response format from \(provider.displayName): \(snippet)"
        case .incompleteResponse(let provider, let reason, _):
            return "\(provider.displayName) response was incomplete (\(reason)). Try again or increase max output tokens."
        case .apiError(let provider, let statusCode, let message):
            return "\(provider.displayName) error (\(statusCode)): \(message)"
        case .missingAPIKey(let provider):
            return "\(provider.displayName) key not configured. Open Settings to add your API key."
        }
    }
}
