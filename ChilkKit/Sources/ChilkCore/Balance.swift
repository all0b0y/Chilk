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

/// Work / leisure come automatically; call and «не трогать» only from the user's Settings (slice 5c).
/// Call: Chilk keeps quiet and idle is not rest, like during a real call. Untouchable: quiet while it is in front.
public enum AppCategory: String, Codable, Sendable {
    case work, leisure, call, untouchable
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

    /// Where a request starts (slice 6, decision 33): Soft and Strict say it at once — a bubble on stage 1, the
    /// pantomime only as its intro; only Silence keeps the wordless stage 0.
    public var floor: Int { self == .silent ? 0 : 1 }
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
    /// Persuasion (slice 4b): no request to defer.
    case nothingToDefer
    /// Persuasion on the pause: only the emergency exit leaves it.
    case pauseInProgress
    /// The request's deferrals are spent, or its «Я занят» is used: only a break helps.
    case deferralsSpent
    /// Today's focus time (`BalanceConfig.focusPerDay`) is spent.
    case focusSpent
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
    /// Stage ≥ 2 «настаивает»: the tray icon wiggles once (was the Dock bounce until slice 5a).
    case nudge
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
    /// Focus mode is over (its time is up or the user ended it): what piled up comes back at «настаивает».
    case focusEnded
    /// «Лежит» (slice 6b): every body need is empty — he lies down; the «Помоги мне…» bubble shows (again).
    case slumped
    /// He is back up: a rest counted or «Встряхнуться».
    case roseUp
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
    /// Needs switched off in Settings (slice 5c): no pressure, no requests.
    public var needsOff: Set<Need> = []
    /// Focus mode (slice 4b, decision 3): at most this long at a time and per day.
    public var focusMax: TimeInterval = 3 * 3600
    public var focusPerDay: TimeInterval = 4 * 3600
    /// Persuasion (slice 4b, decision 4): the longest deferral of the 1st, 2nd, 3rd+ persuasion of a need per day.
    public var persuasionMinutes = [60, 30, 15]

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
    /// This request already counted as «дожимал» (slice 5c, decision 18); a counted rest or an exit resets it.
    public var pushed = false

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
        pushed = try c.decodeIfPresent(Bool.self, forKey: .pushed) ?? false
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
    /// Requests that had to be pushed: reached stage 2+ or ended by an emergency exit (decision 18).
    public var pushed: [Need: Int] = [:]
    public var snoozes = 0
    public var busy = 0
    public var exits: [EmergencyExit] = []
    /// «Конец дня» switched back on mid-day counts its budget from here, not from the morning (slice 5c).
    public var budgetFrom: TimeInterval = 0
    /// Focus time granted today, in seconds (slice 4b); an early end gives the unused part back.
    public var focus: TimeInterval = 0
    /// Persuasions per need today (slice 4b): each next one may defer less.
    public var persuaded: [Need: Int] = [:]

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
    /// Seconds at the Mac since the last rest of at least `stretchRest` (Today: «без перерыва»).
    public var streak: TimeInterval = 0
    /// Settings → «Забота» (slice 5c). Kept with the engine's state, like the mode, so «договор с собой» has one owner.
    public var care = CareSettings()
    /// Focus mode until this moment (slice 4b); survives a restart.
    public var focusUntil: Date?
    /// «Лежит» (slice 6b): `false` after «Встряхнуться» — he does not lie down again until a rest re-arms him.
    public var slumpArmed = true
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
        streak = try field(.streak, 0)
        care = (try? c.decodeIfPresent(CareSettings.self, forKey: .care)) ?? CareSettings()   // a bad care keeps the rest
        focusUntil = (try? c.decodeIfPresent(Date.self, forKey: .focusUntil)) ?? nil
        slumpArmed = try field(.slumpArmed, true)
    }
}

extension DayStats {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try c.decodeIfPresent(String.self, forKey: .key) ?? "")
        firstActivity = try c.decodeIfPresent(Date.self, forKey: .firstActivity)
        active = try c.decodeIfPresent(TimeInterval.self, forKey: .active) ?? 0
        credited = try c.decodeIfPresent([Need: Int].self, forKey: .credited) ?? [:]
        pushed = try c.decodeIfPresent([Need: Int].self, forKey: .pushed) ?? [:]
        snoozes = try c.decodeIfPresent(Int.self, forKey: .snoozes) ?? 0
        busy = try c.decodeIfPresent(Int.self, forKey: .busy) ?? 0
        exits = try c.decodeIfPresent([EmergencyExit].self, forKey: .exits) ?? []
        budgetFrom = try c.decodeIfPresent(TimeInterval.self, forKey: .budgetFrom) ?? 0
        focus = try c.decodeIfPresent(TimeInterval.self, forKey: .focus) ?? 0
        persuaded = (try? c.decodeIfPresent([Need: Int].self, forKey: .persuaded)) ?? [:]
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
    /// «Лежит» as the app last heard of it, and whether its bubble is hidden (a call, full screen, away). Not saved:
    /// after a restart the first tick says `.slumped` again.
    private var reportedSlump = false
    private var slumpHidden = false

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
            // A pantomime left by a build without the mode floor (slice 6, decision 33) becomes its bubble.
            if var e = state.episode, e.stage < state.mode.floor {
                e.stage = min(state.mode.floor, cap(e.need))
                state.episode = e
            }
        } else {
            for n in Need.allCases { state.needs[n] = NeedTrack(threshold: threshold(n)) }
            state.nextMood = self.rng.uniform(config.moodEvery.lowerBound, config.moodEvery.upperBound)
            state.exitsLeft = config.emergencyExits
        }
    }

    // MARK: Queries

    /// 0 = just rested, 1 = due.
    public func pressure(_ n: Need) -> Double {
        if config.needsOff.contains(n) { return 0 }
        if n == .endOfDay, let now = state.lastNow { return (state.day.active - state.day.budgetFrom) / budget(for: now) }
        guard let t = state.needs[n], t.threshold > 0 else { return 0 }
        return t.sitting / t.threshold
    }

    /// The sprout mirrors the user (В20): fresh until half-way to a need, fully wilted at 120 %.
    public var leafFatigue: Double {
        Need.body.map { min(1, max(0, (pressure($0) - 0.5) / 0.7)) }.max() ?? 0
    }

    /// The eyes mirror (slice 6a, decision 4): from half-way to the eyes need it grows, 1 at the threshold.
    /// Smaller eyes and bags under them are the eyes' own signal; the general tiredness no longer touches the eyes.
    public var eyeStrain: Double {
        guard !config.needsOff.contains(.eyes) else { return 0 }
        return min(1, max(0, (pressure(.eyes) - 0.5) / 0.5))
    }

    /// «Договор с собой» (decision 20): while a request is on stage 3–4 nothing may soften care.
    public var settingsLocked: Bool { (state.episode?.stage ?? 0) >= 3 }

    /// Focus mode is on (slice 4b): every request stays on stages 0–1 until `state.focusUntil`.
    public var focusing: Bool { state.focusUntil != nil }

    /// «Лежит» (slice 6b, decision 7): every body need that is on is empty (≥ 100 %), at least two are on, and no
    /// «Встряхнуться» since the last rest.
    public var slumped: Bool { state.slumpArmed && slumpCondition }

    /// Lying, he answers only with a ready line, without Codex (decision 8) — except in Silence (decision 10).
    public var refusesToTalk: Bool { slumped && state.mode != .silent }

    private var slumpCondition: Bool {
        let on = Need.body.filter { !config.needsOff.contains($0) }
        return on.count >= 2 && on.allSatisfy { pressure($0) >= 1 }
    }

    /// Focus time left for today, in seconds.
    public var focusLeftToday: TimeInterval { max(0, config.focusPerDay - state.day.focus) }

    /// The longest a persuasion may defer the request on screen now (slice 4b, decisions 2 and 4): the request's own
    /// «Я занят» inside the shared deferral limit, and less with every persuasion of the same need today.
    public func maxPersuasion() throws(BalanceRefusal) -> Int {
        guard let e = state.episode else { throw .nothingToDefer }
        guard e.stage < 4 else { throw .pauseInProgress }
        guard let t = state.needs[e.need], !t.busyUsed, t.deferrals < config.maxDeferrals else { throw .deferralsSpent }
        let done = state.day.persuaded[e.need] ?? 0
        return config.persuasionMinutes[min(done, config.persuasionMinutes.count - 1)]
    }

    /// For Codex's [контекст] (slice 4b): the request on screen, its limits and the focus — aggregates only (В24).
    public func brief() -> BalanceBrief {
        var b = BalanceBrief(focusUntil: state.focusUntil, focusLeftMinutes: Int(focusLeftToday / 60))
        guard let e = state.episode, let t = state.needs[e.need] else { return b }
        b.need = e.need
        b.stage = e.stage
        b.deferralsLeft = max(0, config.maxDeferrals - t.deferrals)
        b.persuadedToday = state.day.persuaded[e.need] ?? 0
        b.maxMinutes = try? maxPersuasion()
        return b
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
        if let until = state.focusUntil, s.now >= until { finishFocus(into: &out) }
        if guided != nil {                         // the screen is dark and Chilk leads: neither work nor rest
            state.lastFront = s.frontApp
            return out
        }

        // Under the pause a video in the background is not being watched: it must not block the rest.
        let paused = state.episode.map { $0.stage >= 4 && $0.phase == .showing } ?? false
        let video = s.video && !paused
        // An app the user marked «Созвон» counts as a call (slice 5c).
        let inCall = s.inCall || s.category == .call
        // Idle is never scaled: a typing pause must stay a pause even when minutes run in seconds.
        let idle = s.idle
        let atMac = !s.locked && (idle < config.activeWithin || inCall || video)
        let sat = atMac && realDt <= 10 ? dt : 0          // a long gap is the Mac asleep, not sitting
        if sat > 0 {
            for n in Need.body where !config.needsOff.contains(n) { state.needs[n]?.sitting += sat }
            if state.day.firstActivity == nil { state.day.firstActivity = s.now }
            state.day.active += sat
            state.streak += sat
        }

        // Rest (В10): away from the keyboard counts, unless a call or a video keeps the user busy.
        if realDt > 10 { creditRest(away: dt, into: &out) }
        if !inCall && !video && (s.locked || idle >= config.activeWithin) {
            creditRest(away: idle, into: &out)
        } else if atMac {
            state.restLevel = 0
        }

        let appSwitched = state.lastFront != nil && s.frontApp != state.lastFront
        state.lastFront = s.frontApp
        let endOfDayDue = endOfDayIsDue(s.now)
        let blocked = inCall || s.fullscreen || !atMac || s.category == .untouchable

        // «Лежит» (6b): Soft and Silence pause the ladder and the mood while he lies; Strict keeps counting under him,
        // so lying never gets round the shade and the pause (decision 10).
        refreshSlump(blocked: blocked, into: &out)
        if slumped && state.mode != .strict { return out }

        if var e = state.episode {
            // The pause stays up while the user is away (that is the rest); only a call takes it down.
            let off = e.stage >= 4
                ? inCall
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
                        if e.stage >= 2 { out.append(.nudge); e.sinceBounce = 0; markPushed(e.need) }
                    }
                case .showing:
                    e.workOnStage += sat
                    e.sinceBounce += sat
                    if e.workOnStage >= e.nextAfter, e.stage < cap(e.need) {
                        e.stage += 1
                        e.workOnStage = 0
                        e.nextAfter = nextStageDelay()
                        out.append(stageEvent(e, again: false))
                        if e.stage >= 2 { out.append(.nudge); e.sinceBounce = 0; markPushed(e.need) }
                    } else if e.stage >= 2, e.sinceBounce >= config.bounceEvery {
                        out.append(.nudge)
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
        } else if budgetLeft, convenient, !slumped, state.clock >= state.nextMood {
            state.starts.append(state.clock)
            state.nextMood = state.clock + rng.uniform(config.moodEvery.lowerBound, config.moodEvery.upperBound)
            out.append(.mood)
        }
        return out
    }

    public func handle(_ r: Reaction) -> [BalanceEvent] {
        r == .busy ? deferBusy(minutes: config.busyMinutes[0]) : react(r)
    }

    // MARK: «Лежит» (slice 6b)

    /// After a rest the app credited outside `tick` (a button): `.roseUp` right away instead of a second later.
    @discardableResult
    public func updateSlump() -> [BalanceEvent] {
        var out: [BalanceEvent] = []
        refreshSlump(blocked: slumpHidden, into: &out)
        return out
    }

    /// «Встряхнуться» done (decision 9): he gets up, the warm-up need is NOT credited.
    public func shakeUp() -> [BalanceEvent] {
        guard slumped else { return [] }
        state.slumpArmed = false
        reportedSlump = false
        slumpHidden = false
        return [.roseUp]
    }

    private func refreshSlump(blocked: Bool, into out: inout [BalanceEvent]) {
        if !slumpCondition { state.slumpArmed = true }
        let now = slumped
        if now != reportedSlump {
            reportedSlump = now
            slumpHidden = now && blocked
            if !now { out.append(.roseUp) } else if !blocked { out.append(.slumped) }
        } else if now, blocked != slumpHidden {
            slumpHidden = blocked
            out.append(blocked ? .withdraw : .slumped)
        }
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

    /// Persuaded by voice or in the chat (slice 4b, decisions 1, 2, 4): Codex chose `minutes` (15 / 30 / 60), the engine
    /// holds the frame — it is this request's «Я занят», cut down to `maxPersuasion()`.
    public func persuade(minutes: Int) throws(BalanceRefusal) -> [BalanceEvent] {
        let most = try maxPersuasion()
        guard config.busyMinutes.contains(minutes), let n = state.episode?.need else { throw .badDuration }
        let events = deferBusy(minutes: min(minutes, most))
        guard !events.isEmpty else { throw .deferralsSpent }
        state.day.persuaded[n, default: 0] += 1
        return events
    }

    // MARK: Focus mode (slice 4b, decision 3)

    /// What `startFocus` granted.
    public struct FocusStart: Equatable, Sendable {
        public var until: Date
        /// Cut to `focusMax` at a time or to what is left of today's `focusPerDay`.
        public var shortened: Bool
        public var events: [BalanceEvent]
    }

    /// Until the focus ends every request stays on stages 0–1 (a stage above comes down at once); what piles up comes
    /// back at «настаивает». Refused on stages 3–4 («договор с собой») and when today's focus time is spent. A new focus
    /// replaces the running one; the running one's unused time is given back first.
    public func startFocus(seconds: TimeInterval, now: Date) throws(BalanceRefusal) -> FocusStart {
        guard !settingsLocked else { throw .softeningDuringEscalation }
        guard seconds >= 60 else { throw .badDuration }
        let unused = state.focusUntil.map { max(0, $0.timeIntervalSince(now)) } ?? 0
        let used = max(0, state.day.focus - unused)
        let left = max(0, config.focusPerDay - used)
        guard left >= 60 else { throw .focusSpent }
        let granted = min(seconds, config.focusMax, left)
        state.day.focus = used + granted
        state.focusUntil = now.addingTimeInterval(granted)
        var events: [BalanceEvent] = []
        if var e = state.episode, e.stage > cap(e.need) {
            e.stage = cap(e.need)
            e.workOnStage = 0
            state.episode = e
            if e.phase == .showing { events.append(stageEvent(e, again: false)) }
        }
        return FocusStart(until: now.addingTimeInterval(granted), shortened: granted < seconds, events: events)
    }

    /// «Закончить» early: the unused time goes back to today's allowance; the debt is the same as at the end.
    public func endFocus(now: Date) -> [BalanceEvent] {
        guard let until = state.focusUntil else { return [] }
        let unused = max(0, until.timeIntervalSince(now))
        state.day.focus = max(0, state.day.focus - unused)
        var out: [BalanceEvent] = []
        finishFocus(into: &out)
        return out
    }

    /// The debt of the focus: needs that came due start at «настаивает», the request on screen goes there at once.
    private func finishFocus(into out: inout [BalanceEvent]) {
        state.focusUntil = nil
        out.append(.focusEnded)
        for n in Need.allCases where !config.needsOff.contains(n) {
            let due = n == .endOfDay ? (state.lastNow.map(endOfDayIsDue) ?? false) : pressure(n) >= 1   // or past midnight
            if due { state.needs[n]?.debt = true }
        }
        guard var e = state.episode, e.stage < min(2, cap(e.need)) else { return }
        e.stage = min(2, cap(e.need))
        e.workOnStage = 0
        e.nextAfter = nextStageDelay()
        e.sinceBounce = 0
        state.episode = e
        markPushed(e.need)
        if e.phase == .showing {
            out.append(stageEvent(e, again: false))
            out.append(.nudge)
        }
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
        state.streak = 0
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
            if e.stage >= 2 { out.append(.nudge); e.sinceBounce = 0; state.episode = e; markPushed(e.need) }
            return out
        }
    }

    // MARK: Modes and the emergency exit

    /// «Договор с собой» (В16): stricter at once; softer only outside stages 3–4. A stage above the new
    /// ceiling comes down to it right away; a pantomime under a stricter mode's floor becomes its bubble (6a).
    public func setMode(_ mode: BalanceMode) throws -> [BalanceEvent] {
        guard mode != state.mode else { return [] }
        if mode.cap < state.mode.cap, let e = state.episode, e.stage >= 3 {
            throw BalanceRefusal.softeningDuringEscalation
        }
        state.mode = mode
        guard var e = state.episode else { return [] }
        let stage = min(max(e.stage, mode.floor), cap(e.need))
        guard stage != e.stage else { return [] }
        e.stage = stage
        e.workOnStage = 0
        state.episode = e
        return e.phase == .showing ? [stageEvent(e, again: false)] : []
    }

    // MARK: Settings (slice 5c, decisions 19–20)

    /// Settings → «Забота». «Договор с собой» (decision 20) lives here, not in the UI: while a request is on stage 3–4
    /// softer care is refused; tightening always goes through.
    @discardableResult
    public func setCare(_ new: CareSettings) throws(BalanceRefusal) -> [BalanceEvent] {
        if settingsLocked && state.care.isSofter(new) { throw .softeningDuringEscalation }
        state.care = new
        return applyCare()
    }

    /// The engine's numbers follow `state.care` (the app calls this once at launch for the care saved with the state).
    @discardableResult
    public func applyCare() -> [BalanceEvent] {
        var c = config
        state.care.apply(to: &c)
        return updateConfig(c)
    }

    /// Thresholds are clamped into the new ranges at once, so tightening acts immediately; a request of a need that is
    /// off goes quietly; a need switched back on starts from scratch («Конец дня» — its budget counts from now).
    @discardableResult
    func updateConfig(_ c: BalanceConfig) -> [BalanceEvent] {
        let wasOff = config.needsOff
        config = c
        var out: [BalanceEvent] = []
        for n in Need.allCases where c.needsOff.contains(n) != wasOff.contains(n) {
            state.needs[n] = NeedTrack(threshold: n == .endOfDay ? 0 : threshold(n))
            if n == .endOfDay && !c.needsOff.contains(n) { state.day.budgetFrom = state.day.active }
        }
        if let e = state.episode, c.needsOff.contains(e.need) {
            state.episode = nil
            out.append(.withdraw)
        }
        for n in Need.body where !c.needsOff.contains(n) {
            guard var t = state.needs[n] else { continue }
            let r = c.minutes(n)
            t.threshold = min(max(t.threshold, r.lowerBound * 60), r.upperBound * 60)
            if t.sitting < t.threshold { t.pendingSince = nil }
            state.needs[n] = t
        }
        return out
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
        markPushed(e.need)                        // «снята экстренным выходом» (decision 18), once per request
        state.needs[e.need]?.pushed = false       // the request is over; the next one counts again
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

    /// Persuasion and focus from a conversation (slice 4b): the change counts only once it is on disk — otherwise
    /// a restart would hand the limits back. On a failed write the state is as before and the error goes up.
    public func committing<T>(_ write: (BalanceState) throws -> Void, _ body: () throws -> T) throws -> T {
        let before = state
        do {
            let result = try body()
            try write(state)
            return result
        } catch {
            state = before
            throw error
        }
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

    /// «Проверка ▸ Лежит» (slice 6b): every body need that is on becomes empty.
    public func makeSlumped() {
        for n in Need.body where !config.needsOff.contains(n) {
            if let t = state.needs[n] { state.needs[n]?.sitting = max(t.sitting, t.threshold) }
        }
        state.slumpArmed = true
    }

    public func resetAll() {
        for n in Need.allCases { state.needs[n] = NeedTrack(threshold: threshold(n)) }
        state.episode = nil
        state.starts = []
        state.forceEndOfDay = false
    }

    // MARK: Rules

    private func cap(_ n: Need) -> Int { min(n.stageCap, state.mode.cap, focusing ? 1 : 4) }

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
            guard !config.needsOff.contains(n), let t = state.needs[n] else { return false }
            return t.sitting >= t.threshold && state.clock >= t.quietUntil
        }
        if endOfDayDue, category == .work, !config.needsOff.contains(.endOfDay), state.clock >= (state.needs[.endOfDay]?.quietUntil ?? 0) {
            due.append(.endOfDay)
        }
        return due
    }

    private func start(_ n: Need, into out: inout [BalanceEvent]) {
        guard let t = state.needs[n] else { return }
        let stage = min(max(t.resumeStage, t.debt ? 2 : state.mode.floor), cap(n))
        let e = Episode(need: n, stage: stage, phase: .showing, nextAfter: nextStageDelay())
        state.episode = e
        state.needs[n]?.pendingSince = nil
        state.starts.append(state.clock)
        out.append(stageEvent(e, again: false))
        if stage >= 2 { out.append(.nudge); markPushed(n) }
    }

    private func markPushed(_ n: Need) {
        guard state.needs[n]?.pushed == false else { return }
        state.needs[n]?.pushed = true
        state.day.pushed[n, default: 0] += 1
    }

    private func creditRest(away: TimeInterval, into out: inout [BalanceEvent]) {
        if away >= config.stretchRest { state.streak = 0 }
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
        t.pushed = false
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

    private func dayKey(_ date: Date) -> String { config.dayKey(date, calendar: calendar) }

    private func budget(for now: Date) -> TimeInterval {
        config.budget(forDay: now.addingTimeInterval(-Double(config.dayStartsAtHour) * 3600), calendar: calendar)
    }

    /// «Сегодня» and «Неделя» of the main window (slice 5c), on the engine's own calendar.
    public func today(now: Date) -> TodaySummary { Summaries.today(state, config: config, now: now, calendar: calendar) }
    public func week(now: Date) -> WeekSummary { Summaries.week(state, config: config, now: now, calendar: calendar) }

    private func endOfDayIsDue(_ now: Date) -> Bool {
        if state.forceEndOfDay { return true }
        if state.day.active - state.day.budgetFrom >= budget(for: now) { return true }
        // «или 00:00»: still at work after midnight (the day itself lasts until dayStartsAtHour).
        return calendar.component(.hour, from: now) < config.dayStartsAtHour && state.day.firstActivity != nil
    }

    private func rollDay(_ now: Date, into out: inout [BalanceEvent]) {
        let key = dayKey(now)
        guard key != state.day.key else { return }
        // A focus running across the day boundary belongs to the new day from the boundary on (not from this tick:
        // after a restart the first tick can come hours later), and leaves the old day's record.
        var carried: TimeInterval = 0
        if let until = state.focusUntil {
            let hour = Double(config.dayStartsAtHour) * 3600
            let boundary = calendar.startOfDay(for: now.addingTimeInterval(-hour)).addingTimeInterval(hour)
            carried = max(0, until.timeIntervalSince(boundary))
            state.day.focus = max(0, state.day.focus - carried)
        }
        if !state.day.key.isEmpty {
            state.history.append(state.day)
            if state.history.count > 35 { state.history.removeFirst(state.history.count - 35) }
        }
        state.day = DayStats(key: key)
        state.day.focus = carried
        state.forceEndOfDay = false
        state.needs[.endOfDay] = NeedTrack(threshold: 0)
        if state.episode?.need == .endOfDay {
            state.episode = nil
            out.append(.withdraw)
        }
    }
}
