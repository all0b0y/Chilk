import Foundation

/// Slice 9b (SPEC «Срез 9», decisions 13, 15, 17): what the day plan's own moments remember — `plan.json` in the state
/// dir. Days are local ISO `yyyy-MM-dd`. Every field decodes on its own: a file from an older build keeps the rest.
public struct PlanBook: Codable, Equatable, Sendable {
    /// The day whose morning summary was seen (or had nothing to say).
    public var morningShown: String?
    /// The day whose evening «Подведём день?» was seen.
    public var eveningOffered: String?
    /// Days summed up with «Готово» in the review sheet, newest last, at most `keep`.
    public var reviewed: [String] = []
    /// The calendar day the «спланируем день целиком?» offer was made: at most once a day (decision 13).
    public var offered: String?
    /// Single reminders confirmed lately: their day and when (the 30-minute rule of decision 13).
    public var recent: [Recent] = []

    public struct Recent: Codable, Equatable, Sendable {
        public var day: String
        public var at: Date
        public init(day: String, at: Date) {
            self.day = day
            self.at = at
        }
    }

    public static let keep = 14
    public static let offerWindow: TimeInterval = 30 * 60

    public init() {}

    private enum CodingKeys: String, CodingKey { case morningShown, eveningOffered, reviewed, offered, recent }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        morningShown = try? c.decodeIfPresent(String.self, forKey: .morningShown)
        eveningOffered = try? c.decodeIfPresent(String.self, forKey: .eveningOffered)
        reviewed = (try? c.decodeIfPresent([String].self, forKey: .reviewed)) ?? []
        offered = try? c.decodeIfPresent(String.self, forKey: .offered)
        recent = (try? c.decodeIfPresent([Recent].self, forKey: .recent)) ?? []
    }

    public mutating func markReviewed(_ day: String) {
        reviewed.removeAll { $0 == day }
        reviewed.append(day)
        if reviewed.count > Self.keep { reviewed.removeFirst(reviewed.count - Self.keep) }
    }

    /// Decision 13: a single reminder was written for `day`. `true` — it is the second one for the same day within 30
    /// minutes and nothing was offered on `today` yet: offer to plan that day whole. The offer is spent only once it is
    /// really shown (`markOffered`), whatever the answer (review 9b: not when Reminders are off or it lapsed unseen).
    public mutating func reminderWritten(day: String, now: Date, today: String) -> Bool {
        recent.removeAll { now.timeIntervalSince($0.at) > Self.offerWindow || $0.at > now }
        let second = recent.contains { $0.day == day }
        recent.append(Recent(day: day, at: now))
        if recent.count > 8 { recent.removeFirst(recent.count - 8) }
        return second && offered != today
    }

    public mutating func markOffered(_ today: String) { offered = today }
}

/// Slice 9b: the pure rules of the plan's morning summary, evening review and its reaction.
public enum PlanNotice {
    /// Chilk's day turns at 05:00 (decision 15): before it, it is still the evening before.
    public static let dayStartHour = 5
    /// «The first activity»: input within this many seconds, the screen unlocked.
    public static let activeWithin: TimeInterval = 20

    public static func chilkDay(_ now: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: now.addingTimeInterval(-Double(dayStartHour) * 3600))
    }

    /// Decision 15: the morning summary is due — after 05:00, not yet on this day, and the user is at the Mac now.
    public static func morningDue(now: Date, idle: TimeInterval, locked: Bool, book: PlanBook, calendar: Calendar) -> Bool {
        let day = chilkDay(now, calendar: calendar)
        guard calendar.isDate(day, inSameDayAs: now) else { return false }       // 00:00–05:00: still the night
        return !locked && idle < activeWithin && book.morningShown != PlanDay.iso(day, calendar: calendar)
    }

    public struct Thing: Equatable, Sendable {
        public var title: String
        public var time: PlanTime?
        public var done: Bool
        public init(title: String, time: PlanTime? = nil, done: Bool = false) {
            self.title = title
            self.time = time
            self.done = done
        }
    }

    public struct Morning: Equatable, Sendable {
        public var total: Int
        public var timedCount: Int
        /// The first three timed things, by time («и ещё N» for the rest).
        public var timed: [Thing]
        /// Yesterday has things left open and was not summed up (decision 17): «Вчера не подвели итоги — подвести?».
        public var reviewYesterday: Bool
    }

    /// Decision 15: nothing today and nothing to sum up from yesterday — no summary at all.
    public static func morning(today: [Thing], yesterday: [Thing], yesterdayReviewed: Bool) -> Morning? {
        let review = !yesterdayReviewed && yesterday.contains { !$0.done }
        guard !today.isEmpty || review else { return nil }
        let timed = today.filter { $0.time != nil }.sorted { $0.time! < $1.time! }
        return Morning(total: today.count, timedCount: timed.count, timed: Array(timed.prefix(3)), reviewYesterday: review)
    }

    /// Decision 17: what is left open gets one of these in the review; the default is «→ Завтра».
    public enum Choice: String, Equatable, Sendable { case tomorrow, drop }

    public struct ReviewRow: Equatable, Sendable {
        public var id: String
        public var title: String
        public var done: Bool
        public init(id: String, title: String, done: Bool) {
            self.id = id
            self.title = title
            self.done = done
        }
    }

    public enum ReviewOp: Equatable, Sendable { case setDone(String, Bool), move(String, title: String), drop(String) }

    /// Decision 17: what «Готово» writes — the ticks that changed in the review, then every open thing moved to the next
    /// day (the default) or dropped. A thing dropped needs no tick first.
    public static func reviewOps(_ rows: [ReviewRow], original: [String: Bool], choices: [String: Choice]) -> [ReviewOp] {
        var ops: [ReviewOp] = []
        for row in rows {
            let choice = choices[row.id] ?? .tomorrow
            if row.done != (original[row.id] ?? row.done), row.done || choice == .tomorrow { ops.append(.setDone(row.id, row.done)) }
            guard !row.done else { continue }
            ops.append(choice == .tomorrow ? .move(row.id, title: row.title) : .drop(row.id))
        }
        return ops
    }

    /// Decision 17: the reaction after «Готово».
    public enum Result: Equatable, Sendable { case all, most, some, none }

    public static func result(done: Int, total: Int) -> Result {
        guard total > 0, done > 0 else { return .none }
        if done >= total { return .all }
        return Double(done) / Double(total) >= 0.6 ? .most : .some
    }
}
