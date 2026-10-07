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
        for key in names {
            if let schema = props[key], let value = fields[key], let problem = problem(key, value, schema) {
                return "invalid_arguments: \(key) — \(problem)"
            }
        }
        return "invalid_arguments: a value is malformed or out of range"
    }

    private static func problem(_ key: String, _ value: JSON, _ schema: JSON) -> String? {
        let type = schema["type"]?.string
        if case .array(let allowed)? = schema["enum"], !allowed.contains(value) {
            return "must be one of " + allowed.map(describe).joined(separator: ", ")
        }
        switch type {
        case "string":
            guard let text = value.string else { return "must be a string" }
            if key == "at" {
                return timestamp(text) == nil ? "needs an ISO-8601 time with a timezone offset, e.g. 2026-10-09T10:00:00+03:00" : nil
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "must not be empty" }
            if text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                return "must be one line without control characters"
            }
            if key == "path" { return "a path inside the folder: relative, no leading / or ~, no . or .. parts" }
            if text.count > 80 { return "too long (keep it under 80 characters)" }
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
