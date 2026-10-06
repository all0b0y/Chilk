import Foundation

public enum VoiceContext {
    /// No app/window names, documents or transcript history; explicit date and timezone prevent relative-date guesses.
    /// The user's name (slice 5a) is the one they gave Chilk, so he can address them.
    public static func text(sittingMinutes: Int, now: Date = Date(), zone: TimeZone = .autoupdatingCurrent,
                            name: String? = nil, balance: BalanceBrief? = nil, hidden: Bool = false) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = zone
        let who = name.flatMap(UserProfile.cleanName).map { "; пользователя зовут \($0)" } ?? ""
        let brief = balance.map { "; " + $0.text(zone: zone) } ?? ""
        let hideout = hidden ? "; Чилк спрятан за краем экрана" : ""     // slice 6d
        return "[контекст: сейчас \(f.string(from: now)); timezone \(zone.identifier); пользователь за Mac без перерыва \(max(0, sittingMinutes)) мин\(who)\(brief)\(hideout)]\n"
    }

    /// Slice 5b: the same [контекст] for a question typed in the chat window (Persona: read there, may be longer).
    public static func chat(_ context: String) -> String { adding("написано в чате", to: context) }

    /// One more note inside [контекст] (slice 6d+: an open hour or date in the user's words).
    public static func adding(_ note: String, to context: String) -> String {
        guard context.hasSuffix("]\n") else { return context + "[\(note)]\n" }
        return String(context.dropLast(2)) + "; \(note)]\n"
    }
}

/// What Codex needs to judge a persuasion or a focus request (slice 4b): the request on screen, its limits, the focus.
/// Aggregates only (В24): no apps, windows or reasons.
public struct BalanceBrief: Equatable, Sendable {
    public var need: Need?
    public var stage = 0
    public var deferralsLeft = 0
    /// Persuasions of this need today.
    public var persuadedToday = 0
    /// The longest persuasion now (`nil` = none: the pause or the deferrals are spent).
    public var maxMinutes: Int?
    public var focusUntil: Date?
    public var focusLeftMinutes = 0

    public init(need: Need? = nil, stage: Int = 0, deferralsLeft: Int = 0, persuadedToday: Int = 0, maxMinutes: Int? = nil,
                focusUntil: Date? = nil, focusLeftMinutes: Int = 0) {
        self.need = need
        self.stage = stage
        self.deferralsLeft = deferralsLeft
        self.persuadedToday = persuadedToday
        self.maxMinutes = maxMinutes
        self.focusUntil = focusUntil
        self.focusLeftMinutes = focusLeftMinutes
    }

    static let asks: [Need: String] = [.water: "попить воды", .stretch: "размяться", .eyes: "дать отдых глазам",
                                       .walk: "прогуляться", .endOfDay: "закончить день"]

    func text(zone: TimeZone) -> String {
        var parts: [String] = []
        if let need, let ask = Self.asks[need] {
            var p = "на экране просьба «\(ask)», ступень \(stage) из 4"
            if stage >= 4 { p += " (пауза, только экстренный выход)" }
            else if let m = maxMinutes { p += ", отсрочек осталось \(deferralsLeft), уговором можно до \(m) мин" }
            else if deferralsLeft > 0 { p += ", уговор для неё уже был — осталась только кнопка «Через 10 мин»" }
            else { p += ", отсрочки кончились" }
            if persuadedToday > 0 { p += ", сегодня её уже откладывали уговором \(persuadedToday) раз" }
            parts.append(p)
        } else {
            parts.append("просьбы на экране нет")
        }
        if let until = focusUntil {
            let f = DateFormatter()
            f.timeZone = zone
            f.dateFormat = "HH:mm"
            parts.append("фокус до \(f.string(from: until)), на сегодня ещё \(focusLeftMinutes) мин фокуса")
        } else {
            parts.append("фокуса нет, на сегодня осталось \(focusLeftMinutes) мин фокуса")
        }
        return parts.joined(separator: "; ")
    }
}
