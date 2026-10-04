import Foundation

/// A function executed by Chilk, not a shell command or an MCP server.
public struct CodexTool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSON

    public init(name: String, description: String, inputSchema: JSON) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    var descriptor: JSON {
        ["type": "function", "name": .string(name), "description": .string(description), "inputSchema": inputSchema]
    }
}

public struct CodexToolCall: Sendable, Equatable {
    public let threadId: String
    public let turnId: String
    public let callId: String
    public let name: String
    public let arguments: JSON

    init?(_ params: JSON) {
        guard let thread = params["threadId"]?.string, !thread.isEmpty,
              let turn = params["turnId"]?.string, !turn.isEmpty,
              let call = params["callId"]?.string, !call.isEmpty,
              let tool = params["tool"]?.string, !tool.isEmpty,
              let arguments = params["arguments"],
              params["namespace"] == nil || params["namespace"] == .null else { return nil }
        threadId = thread; turnId = turn; callId = call; name = tool; self.arguments = arguments
    }
}

public struct CodexToolResult: Sendable {
    public let success: Bool
    public let value: JSON

    public static func ok(_ value: JSON) -> Self { Self(success: true, value: value) }
    public static func failure(_ message: String) -> Self { Self(success: false, value: ["error": .string(message)]) }

    var response: JSON {
        ["success": .bool(success), "contentItems": [["type": "inputText", "text": .string(value.serialized())]]]
    }
}

public typealias CodexToolHandler = @Sendable (CodexToolCall) async -> CodexToolResult
