import Foundation

/// Slice 8a (decision 13): when a tool call does not parse, Codex is told which field is wrong and how to fix it,
/// instead of «Unknown tool or invalid arguments» (it retried blindly or gave up). Read from the tool's own schema;
/// no argument text is echoed back except the offending key's name.
extension ChilkToolCatalog {
    public static func explain(name: String, arguments: JSON) -> String {
        guard let tool = tools.first(where: { $0.name == name }) else { return "unknown_tool: \(name)" }
        guard case .object(let fields) = arguments else { return "invalid_arguments: the arguments must be a JSON object" }
        guard case .object(let props)? = tool.inputSchema["properties"] else { return "invalid_arguments" }
        let names = props.keys.sorted()
        if let extra = fields.keys.sorted().first(where: { props[$0] == nil }) {
            return "invalid_arguments: \(extra) — not a field of \(name); its fields: \(names.isEmpty ? "none" : names.joined(separator: ", "))"
        }
        if let missing = names.first(where: { fields[$0] == nil }) { return "invalid_arguments: \(missing) — missing" }
        if let problem = actionProblem(name, fields) { return problem }
        for key in names {
            if let schema = props[key], let value = fields[key], let problem = problem(name, key, value, schema) {
                return "invalid_arguments: \(key) — \(problem)"
            }
        }
        if let problem = crossFieldProblem(name, fields) { return problem }
        return "invalid_arguments: a value is malformed or out of range"
    }

    /// The change tools leave unused fields empty: a field the action needs must not be.
    private static func actionProblem(_ tool: String, _ fields: [String: JSON]) -> String? {
        guard tool == "chilk_reminder_change" || tool == "chilk_event_change", let action = fields["action"]?.string else { return nil }
        if ["move", "move_rename"].contains(action), fields["at"]?.string?.isEmpty == true {
            return "invalid_arguments: at — \(action) needs the new time, e.g. 2026-10-09T10:00:00+03:00"
        }
        if ["rename", "move_rename"].contains(action),
           fields["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            return "invalid_arguments: title — \(action) needs the new title"
        }
        return nil
    }

    /// Slice 8e: rules that tie two fields together.
    private static func crossFieldProblem(_ tool: String, _ fields: [String: JSON]) -> String? {
        switch tool {
        case "chilk_event":
            guard let minutes = wholeNumber(fields["minutes"]), let allDay = fields["all_day"]?.bool,
                  !validEventLength(minutes, allDay: allDay) else { return nil }
            return "invalid_arguments: minutes — the length, 1–1439 for an event with a time (0 only with all_day=true)"
        case "chilk_events":
            guard let a = fields["from"]?.string, let from = timestamp(a), let b = fields["to"]?.string, let to = timestamp(b),
                  !validEventRange(from: from, to: to) else { return nil }
            return "invalid_arguments: to — must be later than from, at most 366 days after it"
        default:
            return nil
        }
    }

    private static func problem(_ tool: String, _ key: String, _ value: JSON, _ schema: JSON) -> String? {
        let type = schema["type"]?.string
        if case .array(let allowed)? = schema["enum"], !allowed.contains(value) {
            return "must be one of " + allowed.map(describe).joined(separator: ", ")
        }
        switch type {
        case "string":
            guard let text = value.string else { return "must be a string" }
            let changeTool = tool == "chilk_reminder_change" || tool == "chilk_event_change"
            if key == "at" {
                if changeTool, text.isEmpty { return nil }
                return timestamp(text) == nil ? "needs an ISO-8601 time, e.g. 2026-10-09T10:00:00+03:00 (without an offset it is local time)" : nil
            }
            if tool == "chilk_events", key == "from" || key == "to" {
                return timestamp(text) == nil ? "needs an ISO-8601 time, e.g. 2026-10-09T00:00:00+03:00 (without an offset it is local time)" : nil
            }
            if changeTool, key == "title", text.isEmpty { return nil }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "must not be empty" }
            if text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                return "must be one line without control characters"
            }
            if case .number(let lo)? = schema["minLength"], Double(text.count) < lo { return "too short (at least \(clean(lo)) characters)" }
            if case .number(let hi)? = schema["maxLength"], Double(text.count) > hi { return "too long (at most \(clean(hi)) characters)" }
            if key == "path", tool == "chilk_request_folder", !validFolderPath(text) {
                return "a full folder path: absolute or starting with ~/, without . or .. parts"
            }
            if key == "path", tool != "chilk_request_folder", !validRelativePath(text) {
                return "a path inside the folder: relative, no leading / or ~, no . or .. parts"
            }
            return nil
        case "integer", "number":
            guard case .number(let n) = value else { return "must be a number" }
            if type == "integer", n.rounded(.towardZero) != n { return "must be a whole number" }
            if case .number(let lo)? = schema["minimum"], n < lo { return "must be at least \(clean(lo))" }
            if case .number(let hi)? = schema["maximum"], n > hi { return "must be at most \(clean(hi))" }
            return nil
        case "boolean":
            return value.bool == nil ? "must be true or false" : nil
        default:
            return nil
        }
    }

    private static func describe(_ v: JSON) -> String {
        switch v {
        case .string(let s): "\"\(s)\""
        case .number(let n): clean(n)
        default: "\(v)"
        }
    }

    private static func clean(_ n: Double) -> String { n.rounded() == n ? String(Int(n)) : String(n) }
}
