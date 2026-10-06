import Foundation

// Slice 5c (SPEC «Срез 5», decision 18): «Сегодня» and «Неделя» in the main window, from the aggregates the engine
// already keeps in `balance.json` (no raw activity).

/// Per need: rests counted and requests that had to be pushed («дожимал»).
public struct NeedTally: Equatable, Sendable {
    public var need: Need
    public var credited: Int
    public var pushed: Int
}

public struct DaySummary: Equatable, Sendable {
    public var key: String
    /// Noon of that day (for labels).
    public var date: Date
    public var active: TimeInterval
    public var budget: TimeInterval
}

public struct TodaySummary: Equatable, Sendable {
    /// At the Mac since the last rest of at least 3 minutes.
    public var streak: TimeInterval
    public var active: TimeInterval
    public var budget: TimeInterval
    public var tallies: [NeedTally]
    /// «Через 10 мин» + «Я занят».
    public var deferrals: Int
    /// Newest first.
    public var exits: [EmergencyExit]

    /// Of the day's budget, as «Конец дня» counts it (from re-enabling, if it was switched off). Negative = over.
    public var left: TimeInterval

    public static let empty = TodaySummary(streak: 0, active: 0, budget: 0, tallies: [], deferrals: 0, exits: [], left: 0)
}

public struct WeekSummary: Equatable, Sendable {
    /// Oldest first, the last one is today.
    public var days: [DaySummary]
    public var tallies: [NeedTally]
    public var deferrals: Int
    /// Newest first.
    public var exits: [EmergencyExit]

    public static let empty = WeekSummary(days: [], tallies: [], deferrals: 0, exits: [])
}

extension BalanceConfig {
    /// The day a moment belongs to: it starts at `dayStartsAtHour`, so 02:00 is still yesterday.
    public func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date.addingTimeInterval(-Double(dayStartsAtHour) * 3600))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Noon of the day `key` names.
    public func dayDate(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    public func budget(forDay date: Date, calendar: Calendar) -> TimeInterval {
        calendar.isDateInWeekend(date) ? weekendBudget : weekdayBudget
    }
}

public enum Summaries {
    /// The order of the hero card: Вода, Бодрость, Глаза, Прогулка, Запас дня.
    public static let order: [Need] = HeroCard.order

    public static func today(_ state: BalanceState, config: BalanceConfig, now: Date, calendar: Calendar) -> TodaySummary {
        let key = config.dayKey(now, calendar: calendar)
        let day = state.day.key == key ? state.day : DayStats(key: key)
        let date = config.dayDate(key, calendar: calendar) ?? now
        let budget = config.budget(forDay: date, calendar: calendar)
        return TodaySummary(streak: state.streak, active: day.active, budget: budget,
                            tallies: tallies([day]), deferrals: day.snoozes + day.busy,
                            exits: day.exits.sorted { $0.at > $1.at }, left: budget - (day.active - day.budgetFrom))
    }

    public static func week(_ state: BalanceState, config: BalanceConfig, now: Date, calendar: Calendar) -> WeekSummary {
        let todayKey = config.dayKey(now, calendar: calendar)
        let today = config.dayDate(todayKey, calendar: calendar) ?? now
        var known: [String: DayStats] = [:]
        for d in state.history { known[d.key] = d }
        if !state.day.key.isEmpty { known[state.day.key] = state.day }
        var days: [DaySummary] = []
        var stats: [DayStats] = []
        for back in stride(from: 6, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let key = config.dayKey(date.addingTimeInterval(Double(config.dayStartsAtHour) * 3600), calendar: calendar)
            let d = known[key] ?? DayStats(key: key)
            stats.append(d)
            days.append(DaySummary(key: key, date: date, active: d.active, budget: config.budget(forDay: date, calendar: calendar)))
        }
        return WeekSummary(days: days, tallies: tallies(stats), deferrals: stats.reduce(0) { $0 + $1.snoozes + $1.busy },
                           exits: stats.flatMap(\.exits).sorted { $0.at > $1.at })
    }

    private static func tallies(_ days: [DayStats]) -> [NeedTally] {
        order.map { n in
            NeedTally(need: n, credited: days.reduce(0) { $0 + ($1.credited[n] ?? 0) },
                      pushed: days.reduce(0) { $0 + ($1.pushed[n] ?? 0) })
        }
    }
}
