import Foundation

/// Service for calling Gemini API
actor GeminiAPIService {
    private let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")!

    /// Generate diary content from activity data
    func generateDiary(activity: DailyActivity, apiKey: String) async throws -> DiaryContent {
        let userPrompt = DiaryPromptBuilder.buildPromptWithInstruction(activity: activity)

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
            throw GeminiAPIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorBody = String(data: data, encoding: .utf8) {
                throw GeminiAPIError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
            }
            throw GeminiAPIError.apiError(statusCode: httpResponse.statusCode, message: "Unknown error")
        }

        let responseJSON = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let candidates = responseJSON?["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw GeminiAPIError.invalidResponseFormat
        }

        return DiaryContent(
            date: activity.date,
            rawMarkdown: text
        )
    }
}

enum GeminiAPIError: LocalizedError {
    case invalidResponse
    case invalidResponseFormat
    case apiError(statusCode: Int, message: String)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Gemini API"
        case .invalidResponseFormat:
            return "Unexpected response format from Gemini API"
        case .apiError(let statusCode, let message):
            return "Gemini API error (\(statusCode)): \(message)"
        case .missingAPIKey:
            return "Gemini API key not configured"
        }
    }
}
