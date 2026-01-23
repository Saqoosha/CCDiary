import Foundation

/// Service for calling Claude API
actor ClaudeAPIService {
    private let baseURL = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Generate diary content from activity data
    func generateDiary(activity: DailyActivity, apiKey: String, model: String = "claude-sonnet-4-20250514") async throws -> DiaryContent {
        let userPrompt = DiaryPromptBuilder.buildPromptWithInstruction(activity: activity)

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2000,
            "system": DiaryPromptBuilder.systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": userPrompt
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorBody = String(data: data, encoding: .utf8) {
                throw ClaudeAPIError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
            }
            throw ClaudeAPIError.apiError(statusCode: httpResponse.statusCode, message: "Unknown error")
        }

        let responseJSON = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = responseJSON?["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw ClaudeAPIError.invalidResponseFormat
        }

        return DiaryContent(
            date: activity.date,
            rawMarkdown: text
        )
    }
}

enum ClaudeAPIError: LocalizedError {
    case invalidResponse
    case invalidResponseFormat
    case apiError(statusCode: Int, message: String)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from API"
        case .invalidResponseFormat:
            return "Unexpected response format"
        case .apiError(let statusCode, let message):
            return "API error (\(statusCode)): \(message)"
        case .missingAPIKey:
            return "API key not configured"
        }
    }
}
