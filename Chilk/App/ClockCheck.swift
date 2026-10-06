import ChilkBrain
import ChilkCore
import Foundation

/// Slice 6d+ (SPEC Т1–Т4): the user's latest words, for the time check. An hour left open («в 3») or «завтра» after
/// midnight adds a hint to [контекст], and a reminder on that side is refused until the user's next words answer it.
@MainActor
enum ClockCheck {
    private static var last: (text: String, at: Date)?
    static var log: (String) -> Void = { _ in }

    /// The user's words of the turn being sent (voice or chat): remembered, and [контекст] with the hint if needed.
    static func question(_ text: String, context: String, now: Date = Date()) -> String {
        last = (text, now)
        guard let hint = ClockWords.hint(for: text, now: now, zone: .autoupdatingCurrent) else { return context }
        log("time left open in the question: hint for Codex")
        return VoiceContext.adding(hint, to: context)
    }

    /// `chilk_reminder` / `chilk_schedule` on a side the user left open → the refusal Codex gets; else nil.
    static func refusal(for call: CodexToolCall, now: Date = Date()) -> CodexToolResult? {
        // Read `at` loosely: a timestamp the tool would refuse (past, no zone) is still a guess at the open hour; one
        // that cannot be read at all, while the user left an hour open, is treated as that hour.
        guard call.name == "chilk_reminder" || call.name == "chilk_schedule",
              let (text, at) = last, now.timeIntervalSince(at) < 15 * 60 else { return nil }
        let raw = call.arguments["at"]?.string
        let zone = TimeZone.autoupdatingCurrent
        let conflict: ClockWords.Conflict?
        if let raw, let hour = ClockWords.localHour(ofTimestamp: raw, zone: zone) {
            conflict = ClockWords.conflict(question: text, hour: hour, now: now, zone: zone)
        } else {
            log("tool \(call.name): unreadable at «\(raw ?? "none")»")
            conflict = ClockWords.ambiguousHours(in: text).first.map { .hour($0) }
        }
        switch conflict {
        case .hour(let h):
            log("tool \(call.name) refused: ambiguous_time \(h)")
            return .failure(String(format: "ambiguous_time: the user said %d without утра/дня/вечера/ночи. Nothing was set. "
                                   + "Ask them briefly which one: %02d:00 or %02d:00 (e.g. «В %d ночи или в %d:00?»), "
                                   + "and set it after the answer.", h, h % 12, h % 12 + 12, h, h % 12 + 12))
        case .day:
            log("tool \(call.name) refused: ambiguous_day")
            return .failure("ambiguous_day: it is after midnight and the user said «завтра». Nothing was set. Ask which "
                            + "date they mean (today after sleep, or the day after — name both dates), then set it.")
        case nil:
            return nil
        }
    }
}
