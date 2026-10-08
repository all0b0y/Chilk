import Foundation

/// Slice 9c (SPEC «Срез 9», decisions 19–26): the clock of the night. One bedtime for every day, 20:00–03:00; the night
/// lasts from bedtime to 05:00 — the turn of Chilk's day, so a night always belongs to the day it started in.
public struct SleepClock: Equatable, Sendable {
    /// Minutes after midnight.
    public var bedtime: Int
    public var dayStartsAtHour: Int

    public init(bedtime: Int, dayStartsAtHour: Int = 5) {
        self.bedtime = bedtime
        self.dayStartsAtHour = dayStartsAtHour
    }

    public static let earliest = 20 * 60
    public static let latest = 3 * 60

    /// Minutes after 05:00: orders bedtimes across midnight (20:00 < 23:00 < 01:00).
    public static func order(_ minutes: Int, dayStartsAtHour: Int = 5) -> Int {
        ((minutes - dayStartsAtHour * 60) % 1440 + 1440) % 1440
    }

    /// 20:00–03:00 (decision 19).
    public static func isValid(_ minutes: Int) -> Bool {
        (0..<1440).contains(minutes) && order(minutes) >= order(earliest) && order(minutes) <= order(latest)
    }

    public static func text(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    /// The night of the day `now` belongs to (the day starts at 05:00): bedtime → the next 05:00. A bedtime after midnight
    /// falls on the next calendar date.
    public func night(for now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let day = calendar.startOfDay(for: now.addingTimeInterval(-Double(dayStartsAtHour) * 3600))
        let offset = bedtime >= dayStartsAtHour * 60 ? bedtime : bedtime + 1440
        let start = calendar.date(byAdding: .minute, value: offset, to: day) ?? day
        let end = calendar.date(byAdding: .hour, value: 24 + dayStartsAtHour, to: day) ?? day
        return (start, end)
    }

    public func isNight(_ now: Date, calendar: Calendar) -> Bool {
        let n = night(for: now, calendar: calendar)
        return now >= n.start && now < n.end
    }
}

/// «Сегодня лягу в час» (decision 26): this night only.
public struct TonightBedtime: Codable, Equatable, Sendable {
    /// The day key (`BalanceConfig.dayKey`) of the night.
    public var day: String
    public var minutes: Int

    public init(day: String, minutes: Int) {
        self.day = day
        self.minutes = minutes
    }
}

/// What the popover, the main window and Codex need to know about tonight.
public struct SleepStatus: Equatable, Sendable {
    public var bedtime: Date
    public var warning: Date
    /// 05:00.
    public var end: Date
    public var night: Bool
    /// From the warning until 05:00 later and «off» are refused (decision 26).
    public var locked: Bool
    /// Tonight's bedtime moved once («сегодня лягу в час»).
    public var shifted: Bool
}

/// «Сегодня»: last night (or tonight, once it started) — decision 27.
public struct SleepNight: Equatable, Sendable {
    public var bedtime: Int
    public var lastActivity: Date?
    /// Stage 2+ or an emergency exit.
    public var pushed: Bool
}
