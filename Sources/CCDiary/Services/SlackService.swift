import Foundation

/// Posts generated diaries to Slack via `chat.postMessage`.
///
/// - Requires a bot token (`xoxb-...`); user tokens are not supported.
/// - Renders the diary as Block Kit blocks (header + sections + context) so
///   Slack's mrkdwn limitations don't expose raw `#` and `**` characters.
/// - `text` is set to a short notification fallback ("{date} — CCDiary").
actor SlackService {
    private let postMessageURL = URL(string: "https://slack.com/api/chat.postMessage")!

    func postDiary(_ entry: DiaryEntry, channel: String, botToken: String) async throws -> SlackPostResult {
        let message = SlackMessageBuilder.build(from: entry)

        var request = URLRequest(url: postMessageURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "channel": channel,
            "text": message.fallbackText,
            "blocks": message.blocks,
            "unfurl_links": false,
            "unfurl_media": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SlackServiceError.invalidResponse
        }

        // Check HTTP status before parsing JSON: Slack/CDN errors often return HTML, which
        // would otherwise surface as a confusing JSON-parse error instead of the real status.
        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SlackServiceError.apiError(statusCode: httpResponse.statusCode, message: message)
        }

        guard let responseJSON = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SlackServiceError.invalidResponseFormat
        }

        guard responseJSON["ok"] as? Bool == true else {
            throw SlackServiceError.slackError(
                responseJSON["error"] as? String ?? "unknown_error",
                needed: responseJSON["needed"] as? String,
                provided: responseJSON["provided"] as? String
            )
        }

        guard let postedChannel = responseJSON["channel"] as? String,
              let timestamp = responseJSON["ts"] as? String else {
            throw SlackServiceError.invalidResponseFormat
        }

        return SlackPostResult(channel: postedChannel, timestamp: timestamp, truncated: message.truncated)
    }
}

struct SlackPostResult: Sendable {
    let channel: String
    let timestamp: String
    let truncated: Bool
}

enum SlackServiceError: LocalizedError, Sendable {
    case missingBotToken
    case invalidBotTokenFormat(prefix: String)
    case missingChannel
    case invalidResponse
    case invalidResponseFormat
    case apiError(statusCode: Int, message: String)
    case slackError(String, needed: String?, provided: String?)

    var errorDescription: String? {
        switch self {
        case .missingBotToken:
            return "Slack bot token not configured (set SLACK_BOT_TOKEN or store in Keychain service sh.saqoo.CCDiary.slack-bot-token)"
        case .invalidBotTokenFormat(let prefix):
            return "Slack bot token must start with 'xoxb-' (got '\(prefix)…'). User tokens (xoxp-) and app tokens (xapp-) are not supported."
        case .missingChannel:
            return "Slack channel not configured (pass --slack-channel CHANNEL_ID or set CCDIARY_SLACK_CHANNEL)"
        case .invalidResponse:
            return "Invalid response from Slack API"
        case .invalidResponseFormat:
            return "Unexpected response format from Slack API"
        case .apiError(let statusCode, let message):
            return "Slack API error (\(statusCode)): \(message)"
        case .slackError(let error, let needed, let provided):
            var message = "Slack error: \(error)"
            if let needed {
                message += " (needed: \(needed))"
            }
            if let provided {
                message += " (provided: \(provided))"
            }
            return message
        }
    }
}
