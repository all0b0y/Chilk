import Foundation

// MARK: - Slice 9b (SPEC «Срез 9», decisions 9–18): the day plan

/// A time of day on the plan's day («09:30»).
public struct PlanTime: Equatable, Hashable, Comparable, Sendable, Codable {
    public let hour: Int
    public let minute: Int

    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    /// «9:30» or «09:30»; anything else is nil.
    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        self.init(hour: h, minute: m)
    }

    public init(of date: Date, calendar: Calendar) {
        hour = calendar.component(.hour, from: date)
        minute = calendar.component(.minute, from: date)
    }

    /// «09:30».
    public var text: String { String(format: "%02d:%02d", hour, minute) }

    public static func < (a: PlanTime, b: PlanTime) -> Bool { (a.hour, a.minute) < (b.hour, b.minute) }

    /// This time on `day` (local).
    public func date(on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.startOfDay(for: day))
            ?? calendar.startOfDay(for: day).addingTimeInterval(Double(hour * 3600 + minute * 60))
    }
}

/// One thing to do on the plan's day (decision 9: the time is optional).
public struct PlanItem: Equatable, Hashable, Sendable, Codable {
    public var title: String
    /// nil — «без времени»: a reminder on the date only (no alarm; it waits in «Сегодня»).
    public var time: PlanTime?
    /// Decision 11: a vague time taken by the rule (утром 9:00, днём 13:00, вечером 19:00) or an hour said without
    /// утра / дня / вечера — the card marks it.
    public var guessed: Bool

    public init(title: String, time: PlanTime? = nil, guessed: Bool = false) {
        self.title = title
        self.time = time
        self.guessed = guessed && time != nil
    }

    /// Decision 8 for the plan (acceptance 9b): 00:00–05:59 is a night hour only when the user's words say so (ночи,
    /// ночью, утра, утром, рано, полночь); otherwise it is the day's hour (+12 h), marked as a guess. Dictation writes «в три
    /// часа» as «03:00», and the model may take it literally.
    public func dayHour(words: String) -> PlanItem {
        guard let t = time, t.hour < 6, let day = PlanTime(hour: t.hour + 12, minute: t.minute) else { return self }
        let w = words.lowercased()
        if ["ночи", "ночью", "утра", "утром", "рано", "полноч"].contains(where: { w.contains($0) }) { return self }
        return PlanItem(title: title, time: day, guessed: true)
    }

    /// Like an open hour of a single reminder (slice 8c): a guessed hour that landed in 00:00–05:59 is a day hour.
    public var daytime: PlanItem {
        guard guessed, let t = time, t.hour < 6, let day = PlanTime(hour: t.hour + 12, minute: t.minute) else { return self }
        return PlanItem(title: title, time: day, guessed: true)
    }
}

/// What «Да» on a plan card writes, one reminder per item.
public struct PlanEntry: Equatable, Sendable {
    public let title: String
    /// The moment (with a time) or the day's local midnight (a date only).
    public let due: Date
    public let timed: Bool
}

public enum PlanDay {
    /// Chilk's day turns at 05:00 (decisions 10, 22).
    public static let turnHour = 5
    /// Decision 10: a plan asked for without a day is for today until 17:00, for tomorrow after it.
    public static let eveningHour = 17

    /// Decision 10: no day said — 00:00–17:00 the calendar today (at night that is the day after sleep), later tomorrow.
    public static func defaultDay(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        guard calendar.component(.hour, from: now) >= eveningHour else { return today }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400)
    }

    /// The day a plan is for. `said` nil: the default. Between 00:00 and 05:00 «завтра» means the day after sleep — the
    /// calendar today; the model often takes the calendar tomorrow, so the user's words decide.
    public static func resolve(_ said: Date?, words: String, now: Date, calendar: Calendar) -> (day: Date, nightTomorrow: Bool) {
        guard let said else { return (defaultDay(now: now, calendar: calendar), false) }
        let day = calendar.startOfDay(for: said)
        let today = calendar.startOfDay(for: now)
        if calendar.component(.hour, from: now) < turnHour, saysTomorrow(words),
           let next = calendar.date(byAdding: .day, value: 1, to: today), calendar.isDate(day, inSameDayAs: next) {
            return (today, true)
        }
        return (day, false)
    }

    /// «завтра» as a word («послезавтра» is another day).
    static func saysTomorrow(_ words: String) -> Bool {
        words.lowercased().split { !$0.isLetter }.contains("завтра")
    }

    /// A plan is for today or a day ahead, at most a year.
    public static func inRange(_ day: Date, now: Date, calendar: Calendar) -> Bool {
        let today = calendar.startOfDay(for: now)
        guard let limit = calendar.date(byAdding: .day, value: 366, to: today) else { return false }
        let d = calendar.startOfDay(for: day)
        return d >= today && d <= limit
    }

    /// Decision 10: «четверг, 9 октября»; another year — «четверг, 9 октября 2027». `accusative`: «на пятницу, 9 октября»
    /// (среда, пятница, суббота change; the other days do not).
    public static func title(_ day: Date, now: Date, calendar: Calendar, accusative: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = calendar.isDate(day, equalTo: now, toGranularity: .year) ? "EEEE, d MMMM" : "EEEE, d MMMM yyyy"
        let text = f.string(from: day)
        guard accusative, let comma = text.firstIndex(of: ","), text[..<comma].hasSuffix("а") else { return text }
        return text[..<text.index(before: comma)] + "у" + text[comma...]
    }

    /// «2026-10-09» (for the model).
    public static func iso(_ day: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Timed items by time (the order said is kept for equal times), then the ones without a time in the order said.
    public static func ordered(_ items: [PlanItem]) -> (timed: [PlanItem], untimed: [PlanItem]) {
        let timed = items.enumerated().filter { $0.element.time != nil }
            .sorted { ($0.element.time!, $0.offset) < ($1.element.time!, $1.offset) }.map(\.element)
        return (timed, items.filter { $0.time == nil })
    }

    /// A timed item of today whose time has passed is written without a time (it would ring at once).
    public static func passed(_ item: PlanItem, day: Date, now: Date, calendar: Calendar) -> Bool {
        guard let t = item.time else { return false }
        return t.date(on: day, calendar: calendar) <= now
    }

    /// What «Да» writes: one reminder per item — a time and an alarm, or the date only.
    public static func entries(day: Date, items: [PlanItem], now: Date, calendar: Calendar) -> [PlanEntry] {
        let (timed, untimed) = ordered(items)
        let midnight = calendar.startOfDay(for: day)
        return timed.map { item in
            passed(item, day: day, now: now, calendar: calendar)
                ? PlanEntry(title: item.title, due: midnight, timed: false)
                : PlanEntry(title: item.title, due: item.time!.date(on: day, calendar: calendar), timed: true)
        } + untimed.map { PlanEntry(title: $0.title, due: midnight, timed: false) }
    }

    /// Decision 12: at most this many timed lines on the card (the rest is in «Изменить»).
    public static let cardTimedLines = 8
}

/// Slice 9b: the plan being collected in a conversation (decision 11) — the model sends the whole list each time.
public struct PlanDraft: Equatable, Sendable {
    public let day: Date
    public private(set) var items: [PlanItem] = []
    /// Titles already in the plan for that day (decision 13: «Уже в плане: …», not created again).
    public let already: [String]

    public init(day: Date, already: [String]) {
        self.day = day
        self.already = already
    }

    /// The whole list as the model has it now (corrections applied): a guessed night hour becomes a day hour, an item
    /// already in the plan is not added twice.
    public mutating func update(_ list: [PlanItem]) {
        let known = Set(already.map(Self.key))
        var seen = Set<String>()
        items = list.map(\.daytime).filter { item in
            let k = Self.key(item.title)
            guard !known.contains(k) else { return false }
            return seen.insert(k + "|" + (item.time?.text ?? "")).inserted
        }
    }

    /// Decision 12: one card for the whole plan (nil: nothing to plan).
    public func card() -> ActionCard? {
        items.isEmpty ? nil : ActionCard(kind: .plan(day: day, items: items, already: already))
    }

    static func key(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: "ё", with: "е").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
