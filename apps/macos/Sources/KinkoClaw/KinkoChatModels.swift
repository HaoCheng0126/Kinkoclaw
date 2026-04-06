import Foundation

struct ChatUsageCost: Codable, Hashable, Sendable {
    let input: Double?
    let output: Double?
    let cacheRead: Double?
    let cacheWrite: Double?
    let total: Double?
}

struct ChatUsage: Decodable, Hashable, Sendable {
    let input: Int?
    let output: Int?
    let cacheRead: Int?
    let cacheWrite: Int?
    let cost: ChatUsageCost?
    let total: Int?

    enum CodingKeys: String, CodingKey {
        case input
        case output
        case cacheRead
        case cacheWrite
        case cost
        case total
        case totalTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.input = try container.decodeIfPresent(Int.self, forKey: .input)
        self.output = try container.decodeIfPresent(Int.self, forKey: .output)
        self.cacheRead = try container.decodeIfPresent(Int.self, forKey: .cacheRead)
        self.cacheWrite = try container.decodeIfPresent(Int.self, forKey: .cacheWrite)
        self.cost = try container.decodeIfPresent(ChatUsageCost.self, forKey: .cost)
        self.total =
            try container.decodeIfPresent(Int.self, forKey: .total) ??
            container.decodeIfPresent(Int.self, forKey: .totalTokens)
    }
}

struct ChatMessageContent: Codable, Hashable, Sendable {
    let type: String?
    let text: String?
    let thinking: String?
    let thinkingSignature: String?
    let mimeType: String?
    let fileName: String?
    let content: AnyCodable?
    let id: String?
    let name: String?
    let arguments: AnyCodable?

    init(
        type: String?,
        text: String?,
        thinking: String? = nil,
        thinkingSignature: String? = nil,
        mimeType: String?,
        fileName: String?,
        content: AnyCodable?,
        id: String? = nil,
        name: String? = nil,
        arguments: AnyCodable? = nil)
    {
        self.type = type
        self.text = text
        self.thinking = thinking
        self.thinkingSignature = thinkingSignature
        self.mimeType = mimeType
        self.fileName = fileName
        self.content = content
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case thinking
        case thinkingSignature
        case mimeType
        case fileName
        case content
        case id
        case name
        case arguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.thinking = try container.decodeIfPresent(String.self, forKey: .thinking)
        self.thinkingSignature = try container.decodeIfPresent(String.self, forKey: .thinkingSignature)
        self.mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        self.fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.arguments = try container.decodeIfPresent(AnyCodable.self, forKey: .arguments)

        if let value = try container.decodeIfPresent(AnyCodable.self, forKey: .content) {
            self.content = value
        } else if let text = try container.decodeIfPresent(String.self, forKey: .content) {
            self.content = AnyCodable(text)
        } else {
            self.content = nil
        }
    }
}

struct ChatMessage: Decodable, Identifiable, Sendable {
    var id: UUID = .init()
    let role: String
    let content: [ChatMessageContent]
    let timestamp: Double?
    let toolCallId: String?
    let toolName: String?
    let usage: ChatUsage?
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case timestamp
        case toolCallId
        case tool_call_id
        case toolName
        case tool_name
        case usage
        case stopReason
    }

    init(
        id: UUID = .init(),
        role: String,
        content: [ChatMessageContent],
        timestamp: Double?,
        toolCallId: String? = nil,
        toolName: String? = nil,
        usage: ChatUsage? = nil,
        stopReason: String? = nil)
    {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.usage = usage
        self.stopReason = stopReason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decode(String.self, forKey: .role)
        self.timestamp = try container.decodeIfPresent(Double.self, forKey: .timestamp)
        self.toolCallId =
            try container.decodeIfPresent(String.self, forKey: .toolCallId) ??
            container.decodeIfPresent(String.self, forKey: .tool_call_id)
        self.toolName =
            try container.decodeIfPresent(String.self, forKey: .toolName) ??
            container.decodeIfPresent(String.self, forKey: .tool_name)
        self.usage = try container.decodeIfPresent(ChatUsage.self, forKey: .usage)
        self.stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)

        if let decoded = try? container.decode([ChatMessageContent].self, forKey: .content) {
            self.content = decoded
        } else if let text = try? container.decode(String.self, forKey: .content) {
            self.content = [
                ChatMessageContent(
                    type: "text",
                    text: text,
                    mimeType: nil,
                    fileName: nil,
                    content: nil),
            ]
        } else {
            self.content = []
        }
    }
}

struct ChatHistoryResponse: Codable, Sendable {
    let sessionKey: String
    let sessionId: String?
    let messages: [AnyCodable]?
    let thinkingLevel: String?
}

struct ChatSendResponse: Codable, Sendable {
    let runId: String
    let status: String
}

struct ChatEventPayload: Codable, Sendable {
    let runId: String?
    let sessionKey: String?
    let state: String?
    let message: AnyCodable?
    let errorMessage: String?
}

struct AgentEventPayload: Codable, Sendable, Identifiable {
    var id: String { "\(self.runId)-\(self.seq ?? -1)" }

    let runId: String
    let seq: Int?
    let stream: String
    let ts: Int?
    let data: [String: AnyCodable]
}

struct GatewayHealthOK: Codable, Sendable {
    let ok: Bool?
}

struct ChatAttachmentPayload: Codable, Sendable, Hashable {
    let type: String
    let mimeType: String
    let fileName: String
    let content: String
}

struct ChatModelChoice: Identifiable, Codable, Sendable, Hashable {
    var id: String { self.selectionID }

    let modelID: String
    let name: String
    let provider: String
    let contextWindow: Int?

    var selectionID: String {
        let trimmedProvider = self.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProvider.isEmpty else { return self.modelID }
        let providerPrefix = "\(trimmedProvider)/"
        if self.modelID.hasPrefix(providerPrefix) {
            return self.modelID
        }
        return "\(trimmedProvider)/\(self.modelID)"
    }
}

struct ChatSessionDefaults: Codable, Sendable {
    let model: String?
    let contextTokens: Int?
    let mainSessionKey: String?
}

struct SessionSummary: Codable, Identifiable, Sendable, Hashable {
    var id: String { self.key }

    let key: String
    let kind: String?
    let displayName: String?
    let surface: String?
    let subject: String?
    let room: String?
    let space: String?
    let updatedAt: Double?
    let sessionId: String?
    let systemSent: Bool?
    let abortedLastRun: Bool?
    let thinkingLevel: String?
    let verboseLevel: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    let modelProvider: String?
    let model: String?
    let contextTokens: Int?
}

struct ChatSessionsListResponse: Codable, Sendable {
    let ts: Double?
    let path: String?
    let count: Int?
    let defaults: ChatSessionDefaults?
    let sessions: [SessionSummary]
}
