import Foundation

/// Service for calling OpenAI API
actor OpenAIAPIService: AIAPIService {
    // Use Responses API endpoint (not Chat Completions API).
    private let baseURL = URL(string: "https://api.openai.com/v1/responses")!

    /// Generate diary content from activity data
    func generateDiary(activity: DailyActivity, apiKey: String, model: String) async throws -> DiaryContent {
        let userPrompt = DiaryPromptBuilder.buildPromptWithInstruction(activity: activity)

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 180 // 3 minutes for long diary generation
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "max_output_tokens": 8000,
            "input": [
                [
                    "role": "system",
                    "content": DiaryPromptBuilder.systemPrompt
                ],
                [
                    "role": "user",
                    "content": userPrompt
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIAPIError.invalidResponse(provider: .openai)
        }

        guard httpResponse.statusCode == 200 else {
            if let errorBody = String(data: data, encoding: .utf8) {
                throw AIAPIError.apiError(provider: .openai, statusCode: httpResponse.statusCode, message: errorBody)
            }
            throw AIAPIError.apiError(provider: .openai, statusCode: httpResponse.statusCode, message: "Unknown error")
        }

        let responseBody = String(data: data, encoding: .utf8) ?? "<non-UTF8 response>"
        let responseJSON = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        if let status = responseJSON?["status"] as? String, status == "incomplete" {
            let reason = (responseJSON?["incomplete_details"] as? [String: Any])?["reason"] as? String ?? "unknown"
            throw AIAPIError.incompleteResponse(provider: .openai, reason: reason, responseBody: responseBody)
        }

        // Prefer output_text for text-only responses.
        if let outputText = responseJSON?["output_text"] as? String, !outputText.isEmpty {
            return DiaryContent(
                date: activity.date,
                rawMarkdown: outputText
            )
        }

        // Fallback for responses where text appears in output message blocks.
        guard let output = responseJSON?["output"] as? [[String: Any]] else {
            throw AIAPIError.invalidResponseFormat(provider: .openai, responseBody: responseBody)
        }

        let messageText = output
            .filter { ($0["type"] as? String) == "message" }
            .compactMap { item -> String? in
                guard let content = item["content"] as? [[String: Any]] else {
                    return nil
                }

                let text = content
                    .compactMap { $0["text"] as? String }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                return text.isEmpty ? nil : text
            }
            .first

        guard let messageText else {
            throw AIAPIError.invalidResponseFormat(provider: .openai, responseBody: responseBody)
        }

        return DiaryContent(
            date: activity.date,
            rawMarkdown: messageText
        )
    }
}
