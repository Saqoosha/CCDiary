import Foundation

/// Service for calling Claude API
actor ClaudeAPIService: AIAPIService {
    private let baseURL = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Generate diary content from activity data
    func generateDiary(activity: DailyActivity, apiKey: String, model: String) async throws -> DiaryContent {
        let userPrompt = DiaryPromptBuilder.buildPromptWithInstruction(activity: activity)

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 180 // 3 minutes for long diary generation
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
            throw AIAPIError.invalidResponse(provider: .claudeAPI)
        }

        guard httpResponse.statusCode == 200 else {
            if let errorBody = String(data: data, encoding: .utf8) {
                throw AIAPIError.apiError(provider: .claudeAPI, statusCode: httpResponse.statusCode, message: errorBody)
            }
            throw AIAPIError.apiError(provider: .claudeAPI, statusCode: httpResponse.statusCode, message: "Unknown error")
        }

        let responseBody = String(data: data, encoding: .utf8)
        let responseJSON = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let content = responseJSON?["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw AIAPIError.invalidResponseFormat(provider: .claudeAPI, responseBody: responseBody)
        }

        return DiaryContent(
            date: activity.date,
            rawMarkdown: text
        )
    }
}
