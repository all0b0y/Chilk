import Foundation

public enum ChilkAction: Equatable, Sendable {
    case status, water, timers
    case cancel(id: String)
    case schedule(at: Date, title: String, message: String)
    case timer(seconds: Int, title: String)
}

/// Parse again on the host. Model-supplied JSON schema is a guide, not authorization or validation.
public enum ChilkToolCatalog {
    public enum ToolError: Error { case invalidArguments, unknownTool }

    public static let tools: [CodexTool] = {
        let title: JSON = ["type": "string", "minLength": 1, "maxLength": 80]
        return [
            tool("chilk_status", "Read Chilk balance aggregates, no apps/windows/private files.", [:]),
            tool("chilk_water", "Credit water ONLY when the user confirms they drank it. Do not credit a promise.", [:]),
            tool("chilk_timer", "Create a local Chilk timer. App must run; overdue notices return on next launch.",
                 ["seconds": ["type": "integer", "minimum": 1, "maximum": 31622400], "title": title]),
            tool("chilk_schedule", "Schedule a short prepared message in Chilk at an explicit ISO-8601 timestamp with timezone. Not Apple Reminders; app must run.",
                 ["at": ["type": "string", "maxLength": 64], "title": title,
                  "message": ["type": "string", "minLength": 1, "maxLength": 240]]),
            tool("chilk_timers", "List local Chilk timers with exact ids and deadlines; use before cancelling an ambiguous name.", [:]),
            tool("chilk_cancel_timer", "Cancel one local Chilk timer by its exact id, only on the user's request.",
                 ["id": ["type": "string", "minLength": 1, "maxLength": 128]]),
        ]
    }()

    private static func tool(_ name: String, _ description: String, _ properties: [String: JSON]) -> CodexTool {
        CodexTool(name: name, description: description, inputSchema: [
            "type": "object", "properties": .object(properties),
            "required": .array(properties.keys.sorted().map(JSON.string)), "additionalProperties": false,
        ])
    }

    private static func validTitle(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 80
        && !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    public static func parse(name: String, arguments: JSON) throws -> ChilkAction {
        guard case .object(let fields) = arguments else { throw ToolError.invalidArguments }
        switch name {
        case "chilk_status", "chilk_water", "chilk_timers":
            guard fields.isEmpty else { throw ToolError.invalidArguments }
            if name == "chilk_status" { return .status }
            return name == "chilk_water" ? .water : .timers
        case "chilk_cancel_timer":
            guard Set(fields.keys) == ["id"], let id = fields["id"]?.string, !id.isEmpty, id.count <= 128 else {
                throw ToolError.invalidArguments
            }
            return .cancel(id: id)
        case "chilk_schedule":
            guard Set(fields.keys) == ["at", "title", "message"],
                  let text = fields["at"]?.string, text.count <= 64,
                  text.range(of: "T.*(Z|[+-][0-9]{2}:[0-9]{2})$", options: .regularExpression) != nil,
                  let title = fields["title"]?.string, validTitle(title),
                  let message = fields["message"]?.string, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  message.count <= 240 else { throw ToolError.invalidArguments }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var date = f.date(from: text)
            if date == nil { f.formatOptions = [.withInternetDateTime]; date = f.date(from: text) }
            guard let date else { throw ToolError.invalidArguments }
            return .schedule(at: date, title: title, message: message)
        case "chilk_timer":
            guard Set(fields.keys) == ["seconds", "title"],
                  case .number(let seconds) = fields["seconds"], seconds.isFinite, seconds.rounded(.towardZero) == seconds,
                  seconds >= 1, seconds <= 366 * 24 * 60 * 60,
                  let title = fields["title"]?.string, validTitle(title) else {
                throw ToolError.invalidArguments
            }
            return .timer(seconds: Int(seconds), title: title)
        default: throw ToolError.unknownTool
        }
    }
}
