import Foundation

/// Posts generated diaries to Slack via `chat.postMessage`.
///
/// - Requires a bot token (`xoxb-...`); user tokens are not supported.
/// - Sends the diary as plain markdown text with link/media unfurling disabled.
/// - Truncates messages to ~39,000 UTF-8 bytes (Slack's hard limit is 40,000).
actor SlackService {
    private let postMessageURL = URL(string: "https://slack.com/api/chat.postMessage")!

    func postDiary(_ entry: DiaryEntry, channel: String, botToken: String) async throws -> SlackPostResult {
        let trimmed = entry.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let (text, truncated) = Self.truncateForSlack(trimmed)

        var request = URLRequest(url: postMessageURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "channel": channel,
            "text": text,
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

        return SlackPostResult(channel: postedChannel, timestamp: timestamp, truncated: truncated)
    }

    // Slack's `text` limit is 40,000 UTF-8 bytes. We truncate at 39,000 bytes to leave room
    // for the suffix and avoid edge cases. `String.count` counts grapheme clusters and is
    // unreliable for Japanese/emoji content, which can be ~3 bytes per character.
    static func truncateForSlack(_ markdown: String) -> (text: String, truncated: Bool) {
        let maxBytes = 39_000
        let suffix = "\n\n...(truncated)"
        let utf8 = markdown.utf8
        guard utf8.count > maxBytes else {
            return (markdown, false)
        }

        let budget = maxBytes - suffix.utf8.count
        var bytes = Array(utf8.prefix(budget))
        // Drop trailing UTF-8 continuation bytes (10xxxxxx) so we land on a code-point boundary.
        while let last = bytes.last, (last & 0b1100_0000) == 0b1000_0000 {
            bytes.removeLast()
        }
        let prefix = String(bytes: bytes, encoding: .utf8) ?? markdown
        return (prefix + suffix, true)
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
