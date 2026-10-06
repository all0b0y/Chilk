import ChilkBrain
import ChilkCore
import Foundation

/// Slice 6d+ (SPEC Т1–Т4): the user's latest words, for the time check. An hour left open («в 3») or «завтра» after
/// midnight adds a hint to [контекст], and a reminder on that side is refused until the user's next words answer it.
/// Voice and chat keep their own words: a voice question asked during a chat turn must not judge the chat's reminder.
@MainActor
enum ClockCheck {
    enum Channel: CaseIterable { case voice, chat }
    private enum Kind { case hour, day }
    private struct Said {
        let text: String
        let at: Date
        /// Refused on this channel's previous words: these words answer it (Т4 — «8-го», «завтра, после сна»).
        let answering: Set<Kind>
    }

    private static var last: [Channel: Said] = [:]
    private static var refused: [Channel: Set<Kind>] = [:]
    /// Channels whose Codex turn is running: a tool call belongs to one of them.
    private static var inFlight: Set<Channel> = []
    static var log: (String) -> Void = { _ in }

    /// The user's words of the turn being sent: remembered, and [контекст] with the hint if needed.
    static func question(_ text: String, context: String, channel: Channel, now: Date = Date()) -> String {
        let answering = refused[channel] ?? []
        refused[channel] = nil
        last[channel] = Said(text: text, at: now, answering: answering)
        inFlight.insert(channel)
        guard let hint = ClockWords.hint(for: text, now: now, zone: .autoupdatingCurrent,
                                         dayOpen: !answering.contains(.day)) else { return context }
        log("time left open in the question: hint for Codex")
        return VoiceContext.adding(hint, to: context)
    }

    /// The channel's Codex turn is over (answered or failed).
    static func turnEnded(_ channel: Channel) { inFlight.remove(channel) }

    /// `chilk_reminder` / `chilk_schedule` on a side the user left open → the refusal Codex gets; else nil.
    static func refusal(for call: CodexToolCall, now: Date = Date()) -> CodexToolResult? {
        guard call.name == "chilk_reminder" || call.name == "chilk_schedule" else { return nil }
        // Two turns at once (a voice question during a chat turn): the stricter reading — a needless question is
        // cheaper than a reminder at the wrong hour.
        let channels = inFlight.isEmpty
            ? (last.max { $0.value.at < $1.value.at }.map { [$0.key] } ?? [])
            : Channel.allCases.filter(inFlight.contains)
        for channel in channels {
            if let refusal = refusal(for: call, channel: channel, now: now) { return refusal }
        }
        return nil
    }

    private static func refusal(for call: CodexToolCall, channel: Channel, now: Date) -> CodexToolResult? {
        guard let said = last[channel], now.timeIntervalSince(said.at) < 15 * 60 else { return nil }
        // Read `at` loosely: a timestamp the tool would refuse (past, no zone) is still a guess at the open hour; one
        // that cannot be read at all, while the user left an hour open, is treated as that hour.
        let raw = call.arguments["at"]?.string
        let zone = TimeZone.autoupdatingCurrent
        var conflict: ClockWords.Conflict?
        if let raw, let hour = ClockWords.localHour(ofTimestamp: raw, zone: zone) {
            conflict = ClockWords.conflict(question: said.text, hour: hour, now: now, zone: zone)
        } else {
            log("tool \(call.name): unreadable at «\(raw ?? "none")»")
            conflict = ClockWords.ambiguousHours(in: said.text).first.map { .hour($0) }
        }
        if conflict == .day, said.answering.contains(.day) { conflict = nil }   // «завтра, после сна» is the answer
        switch conflict {
        case .hour(let h):
            refused[channel, default: []].insert(.hour)
            log("tool \(call.name) refused: ambiguous_time \(h)")
            return .failure(String(format: "ambiguous_time: the user said %d without утра/дня/вечера/ночи. Nothing was set. "
                                   + "Ask them briefly which one: %02d:00 or %02d:00 (e.g. «%@»), "
                                   + "and set it after the answer.", h, h % 12, h % 12 + 12, ClockWords.askBack(hour: h)))
        case .day:
            refused[channel, default: []].insert(.day)
            log("tool \(call.name) refused: ambiguous_day")
            return .failure("ambiguous_day: it is after midnight and the user said «завтра». Nothing was set. Ask which "
                            + "date they mean (today after sleep, or the day after — name both dates), then set it.")
        case nil:
            return nil
        }
    }
}
