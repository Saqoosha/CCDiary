import Foundation

/// Content block types in conversation messages
enum ContentBlock: Codable, Sendable {
    case text(String)
    case image(source: AnyCodable)
    case toolUse(id: String, name: String, input: AnyCodable)
    case toolResult(toolUseId: String, content: AnyCodable)
    case unknown

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case source
        case id
        case name
        case input
        case toolUseId = "tool_use_id"
        case content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "image":
            let source = try container.decode(AnyCodable.self, forKey: .source)
            self = .image(source: source)
        case "tool_use":
            let id = try container.decode(String.self, forKey: .id)
            let name = try container.decode(String.self, forKey: .name)
            let input = try container.decode(AnyCodable.self, forKey: .input)
            self = .toolUse(id: id, name: name, input: input)
        case "tool_result":
            let toolUseId = try container.decode(String.self, forKey: .toolUseId)
            let content = try container.decode(AnyCodable.self, forKey: .content)
            self = .toolResult(toolUseId: toolUseId, content: content)
        default:
            self = .unknown
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let source):
            try container.encode("image", forKey: .type)
            try container.encode(source, forKey: .source)
        case .toolUse(let id, let name, let input):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case .toolResult(let toolUseId, let content):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseId, forKey: .toolUseId)
            try container.encode(content, forKey: .content)
        case .unknown:
            break
        }
    }
}

/// Message content can be either a string or array of content blocks
enum MessageContent: Codable, Sendable {
    case string(String)
    case blocks([ContentBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let blocks = try? container.decode([ContentBlock].self) {
            self = .blocks(blocks)
        } else {
            self = .string("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let str):
            try container.encode(str)
        case .blocks(let blocks):
            try container.encode(blocks)
        }
    }

    /// Extract text content from message
    var textContent: String? {
        switch self {
        case .string(let str):
            return str.isEmpty ? nil : str
        case .blocks(let blocks):
            let texts = blocks.compactMap { block -> String? in
                if case .text(let text) = block {
                    return text
                }
                return nil
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
    }
}

/// Message in conversation
struct Message: Codable, Sendable {
    let role: MessageRole
    let content: MessageContent
}

enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
}

/// Entry type in conversation
enum ConversationEntryType: String, Codable, Sendable {
    case user
    case assistant
    case fileHistorySnapshot = "file-history-snapshot"
    case summary
}

/// Conversation entry from project files
struct ConversationEntry: Codable, Sendable {
    let type: ConversationEntryType
    let message: Message?
    let timestamp: String  // ISO 8601
    let sessionId: String?
    let uuid: String?
    let parentUuid: String?
    let isSidechain: Bool?
    let isMeta: Bool?
    let cwd: String?
    let version: String?

    var date: Date? {
        DateFormatting.parseISO8601(timestamp)
    }

    /// Extract text content from this entry
    var textContent: String? {
        message?.content.textContent
    }
}
