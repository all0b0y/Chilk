import Foundation

/// A day's batch of Codex-written lines (decision 2026-10-05): needles for each need on the polite (stage ≤ 1)
/// and insisting (stage 2) step, plus ideas for a break away from the screen by time of day. The hand-written
/// library stays: batch lines join it, and without a batch (offline, error) only the library speaks.
public struct PhraseBatch: Codable, Equatable, Sendable {
    public enum Period: String, CaseIterable, Codable, Sendable { case morning, day, evening, night }

    /// Local calendar day it was written for, «2026-10-05».
    public var day: String
    public var lines: [Need: [Step: [String]]]
    public var ideas: [Period: [String]]
    /// Slice 7b (decision 32): what he says putting the basketball away when the user's call starts («тсс»).
    public var shush: [String] = []

    public enum Step: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable { case polite, insist }

    public init(day: String, lines: [Need: [Step: [String]]] = [:], ideas: [Period: [String]] = [:], shush: [String] = []) {
        self.day = day
        self.lines = lines
        self.ideas = ideas
        self.shush = shush
    }

    private enum CodingKeys: String, CodingKey { case day, lines, ideas, shush }

    /// Field by field: a batch saved before 7b (no `shush`) still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        lines = (try? c.decodeIfPresent([Need: [Step: [String]]].self, forKey: .lines)) ?? [:]
        ideas = (try? c.decodeIfPresent([Period: [String]].self, forKey: .ideas)) ?? [:]
        shush = (try? c.decodeIfPresent([String].self, forKey: .shush)) ?? []
    }

    public func lines(for need: Need, stage: Int) -> [String] { lines[need]?[stage >= 2 ? .insist : .polite] ?? [] }

    public func ideas(hour: Int) -> [String] { ideas[Self.period(hour: hour)] ?? [] }

    /// Same split as the hand-written ideas.
    public static func period(hour: Int) -> Period {
        switch hour {
        case 5..<11: .morning
        case 11..<17: .day
        case 17..<23: .evening
        default: .night
        }
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `outputSchema` for the batch turn: every need × step and every period, nothing else.
    public static var schema: [String: Any] {
        let list: [String: Any] = ["type": "array", "items": ["type": "string"]]
        let steps: [String: Any] = ["type": "object", "properties": ["polite": list, "insist": list],
                                    "required": ["polite", "insist"], "additionalProperties": false]
        let needs = Need.allCases.map(\.rawValue)
        let periods = Period.allCases.map(\.rawValue)
        return [
            "type": "object",
            "properties": [
                "lines": ["type": "object", "properties": Dictionary(uniqueKeysWithValues: needs.map { ($0, steps) }),
                          "required": needs, "additionalProperties": false],
                "ideas": ["type": "object", "properties": Dictionary(uniqueKeysWithValues: periods.map { ($0, list) }),
                          "required": periods, "additionalProperties": false],
                "shush": list,
            ],
            "required": ["lines", "ideas", "shush"],
            "additionalProperties": false,
        ]
    }

    /// The model's JSON → a clean batch: plain text, one short line each, no links, no repeats, at most 6 per slot.
    /// `nil` when nothing usable came back.
    public static func parse(_ message: String, day: String) -> PhraseBatch? {
        guard let data = message.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var batch = PhraseBatch(day: day)
        let lines = root["lines"] as? [String: Any] ?? [:]
        for need in Need.allCases {
            let steps = lines[need.rawValue] as? [String: Any] ?? [:]
            for step in Step.allCases {
                let clean = tidy(steps[step.rawValue])
                if !clean.isEmpty { batch.lines[need, default: [:]][step] = clean }
            }
        }
        let ideas = root["ideas"] as? [String: Any] ?? [:]
        for period in Period.allCases {
            let clean = tidy(ideas[period.rawValue]).map { $0.hasPrefix(ideaPrefix) ? $0 : ideaPrefix + lowercasedFirst($0) }
            if !clean.isEmpty { batch.ideas[period] = clean }
        }
        batch.shush = tidy(root["shush"])
        return batch.lines.isEmpty && batch.ideas.isEmpty ? nil : batch
    }

    public static let ideaPrefix = "Идея: "

    private static func tidy(_ raw: Any?) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for case let line as String in raw as? [Any] ?? [] {
            let text = Dialogue.plain(line).trimmingCharacters(in: CharacterSet(charactersIn: "«»\"' ").union(.whitespacesAndNewlines))
            guard (6...120).contains(text.count), !text.contains("\n"), !text.lowercased().contains("http"),
                  seen.insert(text.lowercased()).inserted else { continue }
            out.append(text)
            if out.count == 6 { break }
        }
        return out
    }

    private static func lowercasedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.lowercased() + s.dropFirst()
    }
}
