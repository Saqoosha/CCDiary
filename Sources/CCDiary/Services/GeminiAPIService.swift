import Foundation

/// Service for calling Gemini API
actor GeminiAPIService: AIAPIService {
    private let baseURLTemplate = "https://generativelanguage.googleapis.com/v1beta/models/%@:generateContent"

    /// Generate diary content from activity data
    func generateDiary(activity: DailyActivity, apiKey: String, model: String) async throws -> DiaryContent {
        let userPrompt = DiaryPromptBuilder.buildPromptWithInstruction(activity: activity)

        let urlString = String(format: baseURLTemplate, model)
        guard let baseURL = URL(string: urlString) else {
            throw AIAPIError.invalidResponse(provider: .gemini)
        }
        var urlComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        var request = URLRequest(url: urlComponents.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180 // 3 minutes for long diary generation
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "system_instruction": [
                "parts": [
                    ["text": DiaryPromptBuilder.systemPrompt]
                ]
            ],
            "contents": [
                [
                    "parts": [
                        ["text": userPrompt]
                    ]
                ]
            ],
            "generationConfig": [
                "maxOutputTokens": 8192,
                "temperature": 0.7
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIAPIError.invalidResponse(provider: .gemini)
        }

        guard httpResponse.statusCode == 200 else {
            if let errorBody = String(data: data, encoding: .utf8) {
                throw AIAPIError.apiError(provider: .gemini, statusCode: httpResponse.statusCode, message: errorBody)
            }
            throw AIAPIError.apiError(provider: .gemini, statusCode: httpResponse.statusCode, message: "Unknown error")
        }

        let responseBody = String(data: data, encoding: .utf8)
        let responseJSON = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let candidates = responseJSON?["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw AIAPIError.invalidResponseFormat(provider: .gemini, responseBody: responseBody)
        }

        return DiaryContent(
            date: activity.date,
            rawMarkdown: text
        )
    }
}
