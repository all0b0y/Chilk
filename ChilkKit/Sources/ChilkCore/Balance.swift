import Foundation

// MARK: - Vocabulary

/// What Чилк looks after (В11). Declaration order = priority when several are due at once.
public enum Need: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable, Comparable {
    case endOfDay, walk, stretch, water, eyes

    public static func < (a: Need, b: Need) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// Needs whose pressure grows while the user sits at the Mac (end of day has its own clock).
    public static let body: [Need] = [.walk, .stretch, .water, .eyes]

    /// Highest ladder stage the need may ever reach (В12): water and eyes never go past «настаивает».
    public var stageCap: Int { self == .water || self == .eyes ? 2 : 4 }

    /// Rest taken on the user's word (В10). The others are confirmed by actually being away from the Mac.
    public var restsOnWord: Bool { self == .water || self == .eyes }
}

public enum AppCategory: String, Codable, Sendable {
    case work, leisure
}

/// One look at the user's situation, taken about once a second (all without extra permissions, spike 001).
public struct Signals: Sendable, Equatable {
    public var now: Date
    /// Seconds since the last keyboard/mouse input (keeps growing while the screen is locked).
    public var idle: TimeInterval
    public var locked: Bool
    public var frontApp: String?
    public var category: AppCategory
    public var fullscreen: Bool
    /// Microphone/camera used by another app, or a call power assertion.
    public var inCall: Bool
    /// Something keeps the display awake for video playback.
    public var video: Bool

    public init(now: Date, idle: TimeInterval = 0, locked: Bool = false, frontApp: String? = nil,
                category: AppCategory = .work, fullscreen: Bool = false, inCall: Bool = false, video: Bool = false) {
        self.now = now
        self.idle = idle
        self.locked = locked
        self.frontApp = frontApp
        self.category = category
        self.fullscreen = fullscreen
        self.inCall = inCall
        self.video = video
    }
}

/// The user's answer to a bubble.
public enum Reaction: String, Codable, Sendable {
    /// «Попил» / «Сделал» — counted on the user's word (water, eyes).
    case done
    /// «Иду» / «Заканчиваю» / «Давай гимнастику» — counted once the rest really happens.
    case going
    /// «Через 10 мин» — at most twice in a row.
    case snooze
    /// «Я занят» — deferred with a debt: next time he starts at «настаивает».
    case busy
}

public enum BalanceEvent: Equatable, Sendable {
    /// Ladder stage 0: silent pantomime (drinks from a mug, stretches…).
    case hint(Need)
    /// Stage ≥ 1: a bubble with buttons. `again` = after a pause or a broken promise.
    case ask(Need, stage: Int, buttons: [Reaction], again: Bool)
    case bounceDock
    /// Tact: call, fullscreen, user away, leisure after hours — hide the bubble, keep the episode.
    case withdraw
    /// The user agreed to go; show the matching activity and wait for the real rest.
    case promised(Need)
    case credited(Need, byRest: Bool, endedEpisode: Bool)
    case snoozed(Need)
    case deferred(Need)
    /// Mood channel: time for a joke or a bigger antic.
    case mood
}

/// Starting values (В11, В12, В17); everything is tunable later in settings.
public struct BalanceConfig: Sendable, Equatable {
    /// Minutes of sitting before a need is due — random inside the range, re-rolled after every rest.
    public var waterMinutes = 40.0...70.0
    public var stretchMinutes = 45.0...75.0
    public var eyesMinutes = 30.0...50.0
    public var walkMinutes = 120.0...180.0
    /// Input this recent means "at the Mac".
    public var activeWithin: TimeInterval = 60
    public var stretchRest: TimeInterval = 3 * 60
    public var walkRest: TimeInterval = 15 * 60
    /// Seconds of continued work without a reaction before the next ladder stage.
    public var nextStageAfter = 300.0...600.0
    public var snooze: TimeInterval = 10 * 60
    public var maxSnoozesInRow = 2
    public var busyDefer: TimeInterval = 15 * 60
    /// Interventions (new episodes + mood) per sliding hour.
    public var budgetPerHour = 4
    /// Gap between mood moments: ≈ 2–3 per hour, never closer than the lower bound.
    public var moodEvery = 15.0 * 60...30.0 * 60
    /// Longest wait for a convenient moment (app switch or a pause in typing).
    public var convenientWait: TimeInterval = 3 * 60
    public var weekdayBudget: TimeInterval = 8 * 3600
    public var weekendBudget: TimeInterval = 4 * 3600
    /// The day (and its budget) starts at this local hour; working past midnight is «конец дня».
    public var dayStartsAtHour = 5
    /// Mode ceiling. Slice 2 stops at «настаивает»; Strict mode (slice 4) raises it to 4.
    public var modeCap = 2
    /// «Иду», but keeps working this long → he asks again.
    public var promiseGrace: TimeInterval = 90
    public var bounceEvery: TimeInterval = 5 * 60
    /// After «Заканчиваю» and a real stop: quiet this long, then work apps start at «настаивает».
    public var endOfDayQuiet: TimeInterval = 20 * 60
    /// Manual testing: 60 = one real second of sitting counts as a minute (rest is still measured in real time).
    public var timeScale = 1.0

    public init() {}

    func minutes(_ n: Need) -> ClosedRange<Double> {
        switch n {
        case .water: waterMinutes
        case .stretch: stretchMinutes
        case .eyes: eyesMinutes
        case .walk: walkMinutes
        case .endOfDay: 1e9...1e9
        }
    }
}

// MARK: - State (persisted between launches)

public struct NeedTrack: Codable, Sendable, Equatable {
    /// Seconds sat since the last rest.
    public var sitting: TimeInterval = 0
    public var threshold: TimeInterval
    /// Deferred with «Я занят»: next episode starts at «настаивает».
    public var debt = false
    public var snoozesInRow = 0
    /// No new episode before this engine-clock time.
    public var quietUntil: TimeInterval = 0
    /// Due since (engine clock), waiting for a convenient moment.
    public var pendingSince: TimeInterval?
}

public struct Episode: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case showing, withdrawn, promised }

    public var need: Need
    public var stage: Int
    public var phase: Phase
    public var workOnStage: TimeInterval = 0
    public var nextAfter: TimeInterval
    public var sinceBounce: TimeInterval = 0
    public var promiseWork: TimeInterval = 0
}

public struct DayStats: Codable, Sendable, Equatable {
    public var key: String
    public var firstActivity: Date?
    public var active: TimeInterval = 0
    public var credited: [Need: Int] = [:]
    public var snoozes = 0
    public var busy = 0
}

public struct BalanceState: Codable, Sendable, Equatable {
    /// Engine time in seconds (scaled by `timeScale`); all timers use it.
    public var clock: TimeInterval = 0
    public var lastNow: Date?
    public var needs: [Need: NeedTrack]
    public var episode: Episode?
    public var day = DayStats(key: "")
    /// Engine-clock times of interventions in the last hour.
    public var starts: [TimeInterval] = []
    public var nextMood: TimeInterval
    public var lastFront: String?
    /// Rest already counted for the current stretch away from the keyboard: 0 none, 1 stretch, 2 walk.
    public var restLevel = 0
    public var forceEndOfDay = false
}

// MARK: - Engine

/// «Режиссёр» (В11) + «лестница» (В12): when to step in, how hard, and when rest counts.
/// Deterministic for a given RNG and signal sequence — every rule is a scenario test.
@MainActor
public final class BalanceEngine {
    public var config: BalanceConfig
    public private(set) var state: BalanceState
    private var rng: any RandomSource
    private let calendar: Calendar

    public init(config: BalanceConfig = BalanceConfig(), restoring saved: BalanceState? = nil,
                rng: any RandomSource = SystemRandom(), calendar: Calendar = .current) {
        self.config = config
        self.rng = rng
        self.calendar = calendar
        self.state = BalanceState(needs: [:], nextMood: 0)
        if var s = saved {
            s.lastNow = nil          // time while Chilk was not running is unknown — not rest, not sitting
            state = s
        } else {
            for n in Need.allCases { state.needs[n] = NeedTrack(threshold: threshold(n)) }
            state.nextMood = self.rng.uniform(config.moodEvery.lowerBound, config.moodEvery.upperBound)
        }
    }

    // MARK: Queries

    /// 0 = just rested, 1 = due.
    public func pressure(_ n: Need) -> Double {
        if n == .endOfDay, let now = state.lastNow { return state.day.active / budget(for: now) }
        guard let t = state.needs[n], t.threshold > 0 else { return 0 }
        return t.sitting / t.threshold
    }

    /// The sprout mirrors the user (В20): fresh until half-way to a need, fully wilted at 120 %.
    public var leafFatigue: Double {
        Need.body.map { min(1, max(0, (pressure($0) - 0.5) / 0.7)) }.max() ?? 0
    }

    public func buttons(for n: Need) -> [Reaction] {
        var b: [Reaction] = [n.restsOnWord && n != .eyes ? .done : .going]
        if (state.needs[n]?.snoozesInRow ?? 0) < config.maxSnoozesInRow { b.append(.snooze) }
        b.append(.busy)
        return b
    }

    // MARK: Inputs

    public func tick(_ s: Signals) -> [BalanceEvent] {
        var out: [BalanceEvent] = []
        let realDt = state.lastNow.map { max(0, s.now.timeIntervalSince($0)) } ?? 0
        state.lastNow = s.now
        let dt = realDt * config.timeScale
        state.clock += dt
        let hourAgo = state.clock - 3600
        state.starts.removeAll { $0 <= hourAgo }
        rollDay(s.now, into: &out)

        // Idle is never scaled: a typing pause must stay a pause even when minutes run in seconds.
        let idle = s.idle
        let atMac = !s.locked && (idle < config.activeWithin || s.inCall || s.video)
        let sat = atMac && realDt <= 10 ? dt : 0          // a long gap is the Mac asleep, not sitting
        if sat > 0 {
            for n in Need.body { state.needs[n]?.sitting += sat }
            if state.day.firstActivity == nil { state.day.firstActivity = s.now }
            state.day.active += sat
        }

        // Rest (В10): away from the keyboard counts, unless a call or a video keeps the user busy.
        if realDt > 10 { creditRest(away: dt, into: &out) }
        if !s.inCall && !s.video && (s.locked || idle >= config.activeWithin) {
            creditRest(away: idle, into: &out)
        } else if atMac {
            state.restLevel = 0
        }

        let appSwitched = state.lastFront != nil && s.frontApp != state.lastFront
        state.lastFront = s.frontApp
        let endOfDayDue = endOfDayIsDue(s.now)
        let blocked = s.inCall || s.fullscreen || !atMac

        if var e = state.episode {
            let off = blocked || (e.need == .endOfDay && (s.category == .leisure || !endOfDayDue))
            if off {
                if e.phase == .showing {
                    e.phase = .withdrawn
                    out.append(.withdraw)
                }
            } else {
                switch e.phase {
                case .withdrawn:
                    e.phase = .showing
                    out.append(stageEvent(e, again: true))
                case .promised:
                    e.promiseWork += sat
                    if e.promiseWork >= config.promiseGrace {
                        e.phase = .showing
                        e.promiseWork = 0
                        e.stage = max(e.stage, min(1, cap(e.need)))     // a broken promise is never just a mime
                        out.append(stageEvent(e, again: true))
                    }
                case .showing:
                    e.workOnStage += sat
                    e.sinceBounce += sat
                    if e.workOnStage >= e.nextAfter, e.stage < cap(e.need) {
                        e.stage += 1
                        e.workOnStage = 0
                        e.nextAfter = nextStageDelay()
                        out.append(stageEvent(e, again: false))
                        if e.stage >= 2 { out.append(.bounceDock); e.sinceBounce = 0 }
                    } else if e.stage >= 2, e.sinceBounce >= config.bounceEvery {
                        out.append(.bounceDock)
                        e.sinceBounce = 0
                    }
                }
            }
            state.episode = e
            return out
        }

        let due = dueNeeds(category: s.category, endOfDayDue: endOfDayDue)
        let clock = state.clock
        for n in due where state.needs[n]?.pendingSince == nil { state.needs[n]?.pendingSince = clock }
        guard !blocked else { return out }
        let typingPause = s.idle >= 2 && s.idle <= 30
        let convenient = appSwitched || typingPause
        let budgetLeft = state.starts.count < config.budgetPerHour
        if let n = due.min() {
            let waited = state.clock - (state.needs[n]?.pendingSince ?? state.clock)
            if budgetLeft && (convenient || waited >= config.convenientWait) { start(n, into: &out) }
        } else if budgetLeft, convenient, state.clock >= state.nextMood {
            state.starts.append(state.clock)
            state.nextMood = state.clock + rng.uniform(config.moodEvery.lowerBound, config.moodEvery.upperBound)
            out.append(.mood)
        }
        return out
    }

    public func handle(_ r: Reaction) -> [BalanceEvent] {
        var out: [BalanceEvent] = []
        guard var e = state.episode else { return out }
        let n = e.need
        switch r {
        case .done where n.restsOnWord:
            credit(n, byRest: false, into: &out)
        case .done, .going:
            e.phase = .promised
            e.promiseWork = 0
            state.episode = e
            out.append(.promised(n))
        case .snooze:
            guard (state.needs[n]?.snoozesInRow ?? 0) < config.maxSnoozesInRow else { return out }
            let until = state.clock + config.snooze
            state.needs[n]?.snoozesInRow += 1
            state.needs[n]?.quietUntil = until
            state.episode = nil
            state.day.snoozes += 1
            out.append(.snoozed(n))
        case .busy:
            state.needs[n]?.debt = true
            let until = state.clock + config.busyDefer
            state.needs[n]?.snoozesInRow = 0
            state.needs[n]?.quietUntil = until
            state.episode = nil
            state.day.busy += 1
            out.append(.deferred(n))
        }
        return out
    }

    /// «Попил» / «Сделал» outside a bubble (Dock menu, later «Чилк, попил») — only for rest taken on the word.
    public func tookRest(_ n: Need) -> [BalanceEvent] {
        guard n.restsOnWord else { return [] }
        var out: [BalanceEvent] = []
        credit(n, byRest: false, into: &out)
        return out
    }

    /// Commit explicit on-word rest only after the app has persisted the resulting aggregates.
    public func tookRest(_ n: Need, persisting write: (BalanceState) throws -> Void) throws -> [BalanceEvent] {
        let before = state
        let events = tookRest(n)
        do { try write(state) } catch { state = before; throw error }
        return events
    }

    /// The prompt to show again after something else had the stage (a conversation), if any.
    public func currentPrompt() -> BalanceEvent? {
        guard let e = state.episode, e.phase == .showing else { return nil }
        return stageEvent(e, again: true)
    }

    /// Clicked on Чилк while he pantomimes: skip straight to the bubble.
    public func pokedDuringHint() -> [BalanceEvent] {
        guard var e = state.episode, e.stage == 0, e.phase == .showing else { return [] }
        e.stage = 1
        e.workOnStage = 0
        state.episode = e
        return [stageEvent(e, again: false)]
    }

    // MARK: Manual testing (Dock «Проверка»)

    public func makeDue(_ n: Need) {
        if n == .endOfDay {
            state.forceEndOfDay = true
        } else if let t = state.needs[n] {
            state.needs[n]?.sitting = max(t.sitting, t.threshold)
        }
        state.needs[n]?.quietUntil = 0
        let since = state.clock - config.convenientWait
        state.needs[n]?.pendingSince = since
        state.starts = []                     // manual testing must not run into the hourly budget
        state.episode = nil
    }

    public func resetAll() {
        for n in Need.allCases { state.needs[n] = NeedTrack(threshold: threshold(n)) }
        state.episode = nil
        state.starts = []
        state.forceEndOfDay = false
    }

    // MARK: Rules

    private func cap(_ n: Need) -> Int { min(n.stageCap, config.modeCap) }

    private func threshold(_ n: Need) -> TimeInterval {
        let r = config.minutes(n)
        return rng.uniform(r.lowerBound, r.upperBound) * 60
    }

    private func nextStageDelay() -> TimeInterval {
        rng.uniform(config.nextStageAfter.lowerBound, config.nextStageAfter.upperBound)
    }

    private func stageEvent(_ e: Episode, again: Bool) -> BalanceEvent {
        e.stage == 0 ? .hint(e.need) : .ask(e.need, stage: e.stage, buttons: buttons(for: e.need), again: again)
    }

    private func dueNeeds(category: AppCategory, endOfDayDue: Bool) -> [Need] {
        var due = Need.body.filter { n in
            guard let t = state.needs[n] else { return false }
            return t.sitting >= t.threshold && state.clock >= t.quietUntil
        }
        if endOfDayDue, category == .work, state.clock >= (state.needs[.endOfDay]?.quietUntil ?? 0) {
            due.append(.endOfDay)
        }
        return due
    }

    private func start(_ n: Need, into out: inout [BalanceEvent]) {
        guard let t = state.needs[n] else { return }
        let stage = min(t.debt ? 2 : (t.snoozesInRow > 0 ? 1 : 0), cap(n))
        let e = Episode(need: n, stage: stage, phase: .showing, nextAfter: nextStageDelay())
        state.episode = e
        state.needs[n]?.pendingSince = nil
        state.starts.append(state.clock)
        out.append(stageEvent(e, again: false))
        if stage >= 2 { out.append(.bounceDock) }
    }

    private func creditRest(away: TimeInterval, into out: inout [BalanceEvent]) {
        if away >= config.walkRest, state.restLevel < 2 {
            state.restLevel = 2
            for n in [Need.walk, .stretch, .eyes] { credit(n, byRest: true, into: &out) }
            if state.episode?.need == .endOfDay { credit(.endOfDay, byRest: true, into: &out) }
        } else if away >= config.stretchRest, state.restLevel < 1 {
            state.restLevel = 1
            credit(.stretch, byRest: true, into: &out)
        }
    }

    private func credit(_ n: Need, byRest: Bool, into out: inout [BalanceEvent]) {
        var t = state.needs[n] ?? NeedTrack(threshold: threshold(n))
        t.sitting = 0
        t.threshold = threshold(n)
        t.snoozesInRow = 0
        t.pendingSince = nil
        if n == .endOfDay {
            // Finished for today: quiet for a while, then work apps meet him at «настаивает» right away.
            t.quietUntil = state.clock + config.endOfDayQuiet
            t.debt = true
        } else {
            t.quietUntil = 0
            t.debt = false
        }
        state.needs[n] = t
        state.day.credited[n, default: 0] += 1
        let ended = state.episode?.need == n
        if ended { state.episode = nil }
        out.append(.credited(n, byRest: byRest, endedEpisode: ended))
    }

    // MARK: Day

    private func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date.addingTimeInterval(-Double(config.dayStartsAtHour) * 3600))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func budget(for now: Date) -> TimeInterval {
        let dayDate = now.addingTimeInterval(-Double(config.dayStartsAtHour) * 3600)
        return calendar.isDateInWeekend(dayDate) ? config.weekendBudget : config.weekdayBudget
    }

    private func endOfDayIsDue(_ now: Date) -> Bool {
        if state.forceEndOfDay { return true }
        if state.day.active >= budget(for: now) { return true }
        // «или 00:00»: still at work after midnight (the day itself lasts until dayStartsAtHour).
        return calendar.component(.hour, from: now) < config.dayStartsAtHour && state.day.firstActivity != nil
    }

    private func rollDay(_ now: Date, into out: inout [BalanceEvent]) {
        let key = dayKey(now)
        guard key != state.day.key else { return }
        state.day = DayStats(key: key)
        state.forceEndOfDay = false
        state.needs[.endOfDay] = NeedTrack(threshold: 0)
        if state.episode?.need == .endOfDay {
            state.episode = nil
            out.append(.withdraw)
        }
    }
}
