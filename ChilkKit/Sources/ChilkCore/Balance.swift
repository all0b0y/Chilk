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

/// How far the ladder may climb (В16). Soft is the default; Strict is switched on by the user (2026-10-05).
public enum BalanceMode: String, CaseIterable, Codable, Sendable {
    case strict, soft, silent

    /// Highest stage: Strict — 4 «блокирует», Soft — 2 «настаивает», Silence — 0 pantomime only.
    public var cap: Int {
        switch self {
        case .strict: 4
        case .soft: 2
        case .silent: 0
        }
    }
}

/// Why the engine refused a request from the user.
public enum BalanceRefusal: Error, Equatable, Sendable {
    /// «Договор с собой»: no softer mode on stages 3–4, only the emergency exit.
    case softeningDuringEscalation
    /// The emergency exit is for stages 3–4.
    case nothingToExit
    case reasonRequired
    case badDuration
    /// No exits left: the button must be held for `BalanceConfig.emergencyHold` seconds.
    case holdRequired
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
    /// «Через 10 мин»: same stage in 10 minutes. Counts towards the deferral limit.
    case snooze
    /// «Я занят»: once per request, 15/30/60 minutes (the app asks), back at «настаивает» or higher.
    case busy
}

public enum GuidedKind: String, Sendable, Equatable { case warmup, walk }

/// Where a guided break came from (decides what «Прервать» costs).
public enum GuidedOrigin: String, Sendable, Equatable { case voluntary, request, pause }

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
    case deferred(Need, minutes: Int)
    /// «Попил» too soon after the last glass (decision 2026-10-05): not counted, the request stays.
    case tooSoon(Need)
    /// Emergency exit taken: no interventions for `minutes`; the need comes back at «настаивает».
    case released(Need, minutes: Int)
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
    /// Deferrals («Через 10 мин» + «Я занят» together) per request; only a counted rest resets them (2026-10-05).
    public var maxDeferrals = 2
    /// «Через сколько вернуться?» after «Я занят»; the default is the first.
    public var busyMinutes = [15, 30, 60]
    /// Water on the user's word at most this often.
    public var waterMinGap: TimeInterval = 20 * 60
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
    /// Emergency exits (В13): how many, for how long, and the hold once they are spent.
    public var emergencyExits = 3
    public var exitMinutes = [15, 30, 60]
    public var emergencyHold: TimeInterval = 10
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
    /// After «Заканчиваю» and after an emergency exit: the next episode starts at «настаивает».
    public var debt = false
    /// Deferrals of the current request («Через 10 мин» + «Я занят»); only a counted rest resets them.
    public var deferrals = 0
    /// «Я занят» is once per request.
    public var busyUsed = false
    /// A deferral pauses the ladder: the request comes back at this stage.
    public var resumeStage = 0
    /// No new episode before this engine-clock time.
    public var quietUntil: TimeInterval = 0
    /// Due since (engine clock), waiting for a convenient moment.
    public var pendingSince: TimeInterval?
    /// Engine clock of the last counted rest (water on the word: not again within `waterMinGap`).
    public var lastCredit: TimeInterval?

    public init(threshold: TimeInterval) { self.threshold = threshold }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threshold = try c.decodeIfPresent(TimeInterval.self, forKey: .threshold) ?? 0
        sitting = try c.decodeIfPresent(TimeInterval.self, forKey: .sitting) ?? 0
        debt = try c.decodeIfPresent(Bool.self, forKey: .debt) ?? false
        deferrals = try c.decodeIfPresent(Int.self, forKey: .deferrals)
            ?? (try? decoder.container(keyedBy: Legacy.self).decodeIfPresent(Int.self, forKey: .snoozesInRow)) ?? 0
        busyUsed = try c.decodeIfPresent(Bool.self, forKey: .busyUsed) ?? false
        resumeStage = try c.decodeIfPresent(Int.self, forKey: .resumeStage) ?? 0
        quietUntil = try c.decodeIfPresent(TimeInterval.self, forKey: .quietUntil) ?? 0
        pendingSince = try c.decodeIfPresent(TimeInterval.self, forKey: .pendingSince)
        lastCredit = try c.decodeIfPresent(TimeInterval.self, forKey: .lastCredit)
    }

    private enum Legacy: String, CodingKey { case snoozesInRow }
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
    public var exits: [EmergencyExit] = []

    public init(key: String) { self.key = key }
}

/// One emergency exit, kept for the weekly summary (В13). The reason stays on this Mac.
public struct EmergencyExit: Codable, Sendable, Equatable {
    public var at: Date
    public var need: Need
    public var minutes: Int
    public var reason: String
    /// Taken with no exits left (the 10-second hold).
    public var held: Bool
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
    public var mode = BalanceMode.soft
    public var exitsLeft = 3
    /// After an emergency exit: no new episode or mood before this engine-clock time.
    public var releasedUntil: TimeInterval = 0
    /// Finished days, newest last (the weekly summary reads them).
    public var history: [DayStats] = []
}

// Files written by older builds lack newer fields: every field falls back to its default instead of the whole
// state being dropped.
extension BalanceState {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func field<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        self.init(needs: try field(.needs, [:]), nextMood: try field(.nextMood, 0))
        clock = try field(.clock, 0)
        lastNow = try c.decodeIfPresent(Date.self, forKey: .lastNow)
        episode = try c.decodeIfPresent(Episode.self, forKey: .episode)
        day = try field(.day, DayStats(key: ""))
        starts = try field(.starts, [])
        lastFront = try c.decodeIfPresent(String.self, forKey: .lastFront)
        restLevel = try field(.restLevel, 0)
        forceEndOfDay = try field(.forceEndOfDay, false)
        mode = try field(.mode, .soft)
        exitsLeft = try field(.exitsLeft, 3)
        releasedUntil = try field(.releasedUntil, 0)
        history = try field(.history, [])
    }
}

extension DayStats {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try c.decodeIfPresent(String.self, forKey: .key) ?? "")
        firstActivity = try c.decodeIfPresent(Date.self, forKey: .firstActivity)
        active = try c.decodeIfPresent(TimeInterval.self, forKey: .active) ?? 0
        credited = try c.decodeIfPresent([Need: Int].self, forKey: .credited) ?? [:]
        snoozes = try c.decodeIfPresent(Int.self, forKey: .snoozes) ?? 0
        busy = try c.decodeIfPresent(Int.self, forKey: .busy) ?? 0
        exits = try c.decodeIfPresent([EmergencyExit].self, forKey: .exits) ?? []
    }
}

// MARK: - Engine

/// «Режиссёр» (В11) + «лестница» (В12): when to step in, how hard, and when rest counts.
/// Deterministic for a given RNG and signal sequence — every rule is a scenario test.
@MainActor
public final class BalanceEngine {
    public var config: BalanceConfig
    public private(set) var state: BalanceState
    /// A guided break in progress (not persisted): the engine stands still meanwhile — no sitting, no stages.
    public private(set) var guided: GuidedOrigin?
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
            for n in Need.allCases where state.needs[n] == nil { state.needs[n] = NeedTrack(threshold: threshold(n)) }
        } else {
            for n in Need.allCases { state.needs[n] = NeedTrack(threshold: threshold(n)) }
            state.nextMood = self.rng.uniform(config.moodEvery.lowerBound, config.moodEvery.upperBound)
            state.exitsLeft = config.emergencyExits
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

    /// Stage 4 is the pause: no buttons, only the emergency exit (the app draws it).
    public func buttons(for n: Need, stage: Int = 1) -> [Reaction] {
        guard stage < 4 else { return [] }
        var b: [Reaction] = [n.restsOnWord && n != .eyes ? .done : .going]
        let t = state.needs[n]
        if (t?.deferrals ?? 0) < config.maxDeferrals {
            b.append(.snooze)
            if t?.busyUsed != true { b.append(.busy) }
        }
        return b
    }

    /// The pause is up (stage 4, showing): the rest that ends it, in seconds away from the keyboard.
    public var pauseRest: TimeInterval? {
        guard let e = state.episode, e.stage >= 4, e.phase == .showing else { return nil }
        return e.need == .stretch ? config.stretchRest : config.walkRest
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
        if guided != nil {                         // the screen is dark and Chilk leads: neither work nor rest
            state.lastFront = s.frontApp
            return out
        }

        // Under the pause a video in the background is not being watched: it must not block the rest.
        let paused = state.episode.map { $0.stage >= 4 && $0.phase == .showing } ?? false
        let video = s.video && !paused
        // Idle is never scaled: a typing pause must stay a pause even when minutes run in seconds.
        let idle = s.idle
        let atMac = !s.locked && (idle < config.activeWithin || s.inCall || video)
        let sat = atMac && realDt <= 10 ? dt : 0          // a long gap is the Mac asleep, not sitting
        if sat > 0 {
            for n in Need.body { state.needs[n]?.sitting += sat }
            if state.day.firstActivity == nil { state.day.firstActivity = s.now }
            state.day.active += sat
        }

        // Rest (В10): away from the keyboard counts, unless a call or a video keeps the user busy.
        if realDt > 10 { creditRest(away: dt, into: &out) }
        if !s.inCall && !video && (s.locked || idle >= config.activeWithin) {
            creditRest(away: idle, into: &out)
        } else if atMac {
            state.restLevel = 0
        }

        let appSwitched = state.lastFront != nil && s.frontApp != state.lastFront
        state.lastFront = s.frontApp
        let endOfDayDue = endOfDayIsDue(s.now)
        let blocked = s.inCall || s.fullscreen || !atMac

        if var e = state.episode {
            // The pause stays up while the user is away (that is the rest); only a call takes it down.
            let off = e.stage >= 4
                ? s.inCall
                : blocked || (e.need == .endOfDay && (s.category == .leisure || !endOfDayDue))
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
                        // A broken promise costs a step (2026-10-05): «Иду» is not a free 90-second snooze.
                        e.stage = max(min(e.stage + 1, cap(e.need)), min(1, cap(e.need)))
                        e.workOnStage = 0
                        e.nextAfter = nextStageDelay()
                        out.append(stageEvent(e, again: true))
                        if e.stage >= 2 { out.append(.bounceDock); e.sinceBounce = 0 }
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
        guard !blocked, state.clock >= state.releasedUntil else { return out }
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
        r == .busy ? deferBusy(minutes: config.busyMinutes[0]) : react(r)
    }

    /// «Я занят» → «Через сколько вернуться?» → this (15/30/60). Once per request, inside the deferral limit.
    public func deferBusy(minutes: Int) -> [BalanceEvent] {
        guard let e = state.episode, e.stage < 4, var t = state.needs[e.need], !t.busyUsed,
              t.deferrals < config.maxDeferrals, config.busyMinutes.contains(minutes) else { return [] }
        t.deferrals += 1
        t.busyUsed = true
        t.resumeStage = max(e.stage, min(2, cap(e.need)))           // back at «настаивает» or higher
        t.quietUntil = state.clock + Double(minutes) * 60
        state.needs[e.need] = t
        state.episode = nil
        state.day.busy += 1
        return [.deferred(e.need, minutes: minutes)]
    }

    private func react(_ r: Reaction) -> [BalanceEvent] {
        var out: [BalanceEvent] = []
        guard var e = state.episode, e.stage < 4 else { return out }       // the pause has no buttons
        let n = e.need
        switch r {
        case .done where n.restsOnWord:
            creditOnWord(n, into: &out)
        case .done, .going:
            e.phase = .promised
            e.promiseWork = 0
            state.episode = e
            out.append(.promised(n))
        case .snooze:
            guard var t = state.needs[n], t.deferrals < config.maxDeferrals else { return out }
            t.deferrals += 1
            t.resumeStage = max(t.resumeStage, e.stage)               // the ladder pauses, it does not reset
            t.quietUntil = state.clock + config.snooze
            state.needs[n] = t
            state.episode = nil
            state.day.snoozes += 1
            out.append(.snoozed(n))
        case .busy:
            break                                                      // `deferBusy(minutes:)`
        }
        return out
    }

    // MARK: Guided breaks (decisions 2026-10-05)

    /// Starts a guided break. The origin decides what «Прервать» costs: nothing when the user asked for it,
    /// a broken promise when he chose «Разминка со мной» after «Иду», back to the pause when it came from there.
    @discardableResult
    public func beginGuided(_ kind: GuidedKind) -> GuidedOrigin {
        let need: Need = kind == .warmup ? .stretch : .walk
        let origin: GuidedOrigin
        if let e = state.episode, e.need == need || (kind == .walk && e.need == .stretch) {
            origin = e.stage >= 4 && e.phase == .showing ? .pause : (e.phase == .promised ? .request : .voluntary)
        } else {
            origin = .voluntary
        }
        guided = origin
        return origin
    }

    /// Finished: credits what the break counts (by rest — a finished walk refills the emergency exits).
    public func finishGuided(_ session: GuidedSession) -> [BalanceEvent] {
        guard guided != nil else { return [] }
        guided = nil
        state.restLevel = session.credits.contains(.walk) ? 2 : max(state.restLevel, 1)
        var out: [BalanceEvent] = []
        for n in session.credits { credit(n, byRest: true, into: &out) }
        return out
    }

    /// «Прервать»: nothing is counted. After «Иду» it is a broken promise (a stage up, like 90 s of work);
    /// from the pause, the pause comes back.
    public func interruptGuided() -> [BalanceEvent] {
        guard let origin = guided else { return [] }
        guided = nil
        guard var e = state.episode else { return [] }
        switch origin {
        case .voluntary:
            return e.phase == .showing ? [stageEvent(e, again: true)] : []
        case .pause:
            e.phase = .showing
            state.episode = e
            return [stageEvent(e, again: true)]
        case .request:
            guard e.phase == .promised else { return [] }
            e.phase = .showing
            e.promiseWork = 0
            e.stage = max(min(e.stage + 1, cap(e.need)), min(1, cap(e.need)))
            e.workOnStage = 0
            e.nextAfter = nextStageDelay()
            state.episode = e
            var out = [stageEvent(e, again: true)]
            if e.stage >= 2 { out.append(.bounceDock); e.sinceBounce = 0; state.episode = e }
            return out
        }
    }

    // MARK: Modes and the emergency exit

    /// «Договор с собой» (В16): stricter at once; softer only outside stages 3–4. A stage above the new
    /// ceiling comes down to it right away.
    public func setMode(_ mode: BalanceMode) throws -> [BalanceEvent] {
        guard mode != state.mode else { return [] }
        if mode.cap < state.mode.cap, let e = state.episode, e.stage >= 3 {
            throw BalanceRefusal.softeningDuringEscalation
        }
        state.mode = mode
        guard var e = state.episode, e.stage > cap(e.need) else { return [] }
        e.stage = cap(e.need)
        e.workOnStage = 0
        state.episode = e
        return e.phase == .showing ? [stageEvent(e, again: false)] : []
    }

    /// Emergency exit (В13) on stages 3–4: a reason is required; 3 exits, refilled by a walk; with none left
    /// the app makes the user hold the button for `emergencyHold` seconds and passes `held`. Never impossible.
    public func emergencyExit(reason: String, minutes: Int, held: Bool = false, now: Date) throws -> [BalanceEvent] {
        guard let e = state.episode, e.stage >= 3 else { throw BalanceRefusal.nothingToExit }
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { throw BalanceRefusal.reasonRequired }
        guard config.exitMinutes.contains(minutes) else { throw BalanceRefusal.badDuration }
        let spent = state.exitsLeft <= 0
        guard !spent || held else { throw BalanceRefusal.holdRequired }
        if !spent { state.exitsLeft -= 1 }
        state.day.exits.append(EmergencyExit(at: now, need: e.need, minutes: minutes,
                                             reason: String(reason.prefix(200)), held: spent))
        state.needs[e.need]?.debt = true
        state.needs[e.need]?.pendingSince = nil
        state.releasedUntil = state.clock + Double(minutes) * 60
        state.episode = nil
        return [.released(e.need, minutes: minutes)]
    }

    /// «Попил» / «Сделал» outside a bubble (Dock menu, later «Чилк, попил») — only for rest taken on the word.
    public func tookRest(_ n: Need) -> [BalanceEvent] {
        guard n.restsOnWord else { return [] }
        var out: [BalanceEvent] = []
        creditOnWord(n, into: &out)
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

    private func cap(_ n: Need) -> Int { min(n.stageCap, state.mode.cap) }

    private func threshold(_ n: Need) -> TimeInterval {
        let r = config.minutes(n)
        return rng.uniform(r.lowerBound, r.upperBound) * 60
    }

    private func nextStageDelay() -> TimeInterval {
        rng.uniform(config.nextStageAfter.lowerBound, config.nextStageAfter.upperBound)
    }

    private func stageEvent(_ e: Episode, again: Bool) -> BalanceEvent {
        e.stage == 0 ? .hint(e.need) : .ask(e.need, stage: e.stage, buttons: buttons(for: e.need, stage: e.stage), again: again)
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
        let stage = min(max(t.resumeStage, t.debt ? 2 : 0), cap(n))
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

    /// Water and eyes on the user's word; water not again within `waterMinGap` («Ты же только что пил»).
    private func creditOnWord(_ n: Need, into out: inout [BalanceEvent]) {
        if n == .water, let last = state.needs[n]?.lastCredit, state.clock - last < config.waterMinGap {
            out.append(.tooSoon(n))
            return
        }
        credit(n, byRest: false, into: &out)
    }

    private func credit(_ n: Need, byRest: Bool, into out: inout [BalanceEvent]) {
        var t = state.needs[n] ?? NeedTrack(threshold: threshold(n))
        t.sitting = 0
        t.threshold = threshold(n)
        t.deferrals = 0
        t.busyUsed = false
        t.resumeStage = 0
        t.lastCredit = state.clock
        t.pendingSince = nil
        if n == .endOfDay {
            // Finished for today: quiet for a while, then work apps meet him at «настаивает» right away.
            t.quietUntil = state.clock + config.endOfDayQuiet
            t.debt = true
        } else {
            t.quietUntil = 0
            t.debt = false
        }
        if n == .walk && byRest { state.exitsLeft = config.emergencyExits }     // «пополняются после прогулки»
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
        if !state.day.key.isEmpty {
            state.history.append(state.day)
            if state.history.count > 35 { state.history.removeFirst(state.history.count - 35) }
        }
        state.day = DayStats(key: key)
        state.forceEndOfDay = false
        state.needs[.endOfDay] = NeedTrack(threshold: 0)
        if state.episode?.need == .endOfDay {
            state.episode = nil
            out.append(.withdraw)
        }
    }
}
