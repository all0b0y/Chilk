import ChilkBrain
import ChilkCore
import Foundation

/// Slice 6d+ (SPEC Т1–Т4), revised by 8c (decision 8): the user's latest words. An hour left open («в 3») or «завтра»
/// after midnight adds a hint to [контекст]; nothing is refused any more — the card shows the guess.
/// Voice and chat keep their own words: a voice question asked during a chat turn must not judge the chat's reminder.
@MainActor
enum ClockCheck {
    enum Channel: CaseIterable { case voice, chat }
    private struct Said {
        let text: String
        let at: Date
    }

    private static var last: [Channel: Said] = [:]
    /// Channels whose Codex turn is running: a tool call belongs to one of them.
    private static var inFlight: Set<Channel> = []
    static var log: (String) -> Void = { _ in }

    /// The user's words of the turn being sent: remembered, and [контекст] with the hint if needed.
    static func question(_ text: String, context: String, channel: Channel, now: Date = Date()) -> String {
        last[channel] = Said(text: text, at: now)
        inFlight.insert(channel)
        guard let hint = ClockWords.hint(for: text, now: now, zone: .autoupdatingCurrent, dayOpen: true) else { return context }
        log("time left open in the question: hint for Codex")
        return VoiceContext.adding(hint, to: context)
    }

    /// Slice 9b: the channel whose turn is running (a tool call belongs to it); the latest one when none or both run.
    static var turnChannel: Channel {
        if inFlight.count == 1, let c = inFlight.first { return c }
        return last.max { $0.value.at < $1.value.at }?.key ?? .voice
    }

    /// The user's words of that turn (the plan's night «завтра» rule).
    static func lastWords() -> String { last[turnChannel]?.text ?? "" }

    /// The channel's Codex turn is over (answered or failed).
    static func turnEnded(_ channel: Channel) { inFlight.remove(channel) }

    /// Slice 8c (decision 8): no question first — the card marks what was guessed. `part`: the user's latest words
    /// named this hour without утра / дня / вечера / ночи; `day`: «завтра» said after midnight.
    static func guess(for date: Date, now: Date = Date()) -> (part: Bool, day: Bool) {
        let channels = inFlight.isEmpty ? (last.max { $0.value.at < $1.value.at }.map { [$0.key] } ?? [])
                                        : Channel.allCases.filter(inFlight.contains)
        var out = (part: false, day: false)
        let zone = TimeZone.autoupdatingCurrent
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let hour = cal.component(.hour, from: date)
        for channel in channels {
            guard let said = last[channel], now.timeIntervalSince(said.at) < 15 * 60 else { continue }
            if ClockWords.ambiguousHours(in: said.text).contains(where: { $0 % 12 == hour % 12 })
                || ClockWords.looseOpenHour(in: said.text, hour: hour) { out.part = true }
            if ClockWords.dayOpen(question: said.text, now: now, zone: zone) { out.day = true }
        }
        return out
    }
}
