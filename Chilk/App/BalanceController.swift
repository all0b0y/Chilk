import AppKit
import ChilkBrain
import ChilkCore

/// Slice 2 in the app: signals → `BalanceEngine` → what Чилк does (pantomime, bubble with buttons,
/// standing out, the tray-icon wiggle) and the breaks themselves (eye gymnastics, breathing, water, walk).
@MainActor
final class BalanceController {
    let engine: BalanceEngine
    private let sim: CharacterSim
    private let edge: EdgeController
    private let monitor = SignalMonitor()
    /// Stage 3 shade and stage 4 pause (slice 4).
    let escalation = Escalation()
    private var timer: Timer?
    private var activityTimer: Timer?
    private var settleTimer: Timer?
    /// Slice 6a (decision 33): the pantomime plays first, the bubble comes when it ends; a click shows it at once.
    private var introTimer: Timer?
    private var introShow: (() -> Void)?
    /// He cheers when the user is back from a walk that counted (decision 6).
    private var cheerOnReturn = false
    /// What each button of the current bubble does.
    private var buttonActions: [() -> Void] = []
    private var lastPantomime = Date.distantPast
    private var lastSave = Date()
    /// Said when the user comes back from a walk/stretch that was part of an episode.
    private var returnLine: String?
    private var walking = false
    private var activity: Activity?
    private(set) var lastSignals: Signals?
    private var ticks = 0
    /// CHILK_BALANCE_LOG=/abs/path: signals every 10 s and every director event (for acceptance and debugging).
    private let logURL = ProcessInfo.processInfo.environment["CHILK_BALANCE_LOG"].map { URL(fileURLWithPath: $0) }
    private let env = ProcessInfo.processInfo.environment
    private var demoExitScheduled = false
    /// CHILK_DEMO_PRESS=0,0 (acceptance only): press these bubble buttons in turn, 2 s after each appears.
    private lazy var demoPresses: [Int] = (env["CHILK_DEMO_PRESS"] ?? "").split(separator: ",").compactMap { Int($0) }
    private var demoPressSince: Date?

    func log(_ line: String) {
        guard let url = logURL else { return }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    private enum Activity { case eyeGym, breathing, guided }

    /// Guided warm-up / walk in progress (decisions 2026-10-05).
    private struct GuidedRun {
        let session: GuidedSession
        let kind: GuidedKind
        let origin: GuidedOrigin
        let idea: String
        let source: WarmupSource.Origin?
        var step = -1
        var lastMove: TimeInterval = 0
    }
    private var guidedRun: GuidedRun?
    private var guideTimer: Timer?
    /// A break asked for by voice: it starts when the conversation closes.
    private var pendingBreak: (ChilkBreak, Date)?
    /// Codex-written warm-ups with the library as the fallback (set by the app).
    var warmups: WarmupSource?
    /// CHILK_GUIDE_SCALE (acceptance only): guided time runs this many times faster.
    private lazy var guideScale = env["CHILK_GUIDE_SCALE"].flatMap(Double.init) ?? 1

    /// While Чилк talks with the user the stage is theirs: balance keeps counting but shows nothing.
    var isBusy: () -> Bool = { false }
    /// Stage ≥ 2 insists: the tray icon wiggles (slice 5a; was the Dock bounce). Also while the stage is busy.
    var onNudge: () -> Void = {}

    /// Something of the balance holds Chilk at the edge right now: a break, a walk, a bubble of the ladder, the
    /// shade or the pause. The tray then leaves him there (decision 7).
    var isOccupied: Bool {
        if activity != nil || walking || escalation.level != .none { return true }
        if let e = engine.state.episode, e.phase == .showing, e.stage >= 1 { return true }
        return false
    }

    /// The stage of the request on screen (`nil` = none) — the dot on the tray icon.
    var shownStage: Int? {
        engine.state.episode.flatMap { $0.phase == .showing ? $0.stage : nil }
    }

    /// After a conversation: show the current prompt again (if any).
    func resume() {
        if let (b, at) = pendingBreak {
            pendingBreak = nil
            if Date().timeIntervalSince(at) < 300 { return startBreak(b) }
        }
        let focusLine = focusEndedUnsaid
        focusEndedUnsaid = false
        if let prompt = engine.currentPrompt() {
            apply(prompt)
        } else if focusLine {
            apply(.focusEnded)
        } else if engine.state.episode == nil, activity == nil, !walking {
            // Persuaded during a chat turn: the request's bubble and props are still up (events were held back).
            if !buttonActions.isEmpty { hideBubble(); sim.standOut = .docked }
            tidyProps()
        }
    }

    /// Minutes since the last real stretch break — the only activity fact sent to Codex (В24).
    var sittingMinutes: Int { Int((engine.state.needs[.stretch]?.sitting ?? 0) / 60) }

    /// Settings (slice 5c): app categories and the recent-apps list (care is the engine's, in `balance.json`).
    private let settings: SettingsStore

    init(sim: CharacterSim, edge: EdgeController, presence: PresenceMonitor, settings: SettingsStore) {
        var config = BalanceConfig()
        if let scale = ProcessInfo.processInfo.environment["CHILK_TIME_SCALE"].flatMap(Double.init) { config.timeScale = scale }
        engine = BalanceEngine(config: config, restoring: Self.load())
        engine.applyCare()                                  // the care saved with the state (a request of a need now off goes)
        self.settings = settings
        monitor.rules = { [weak settings] in settings?.settings.apps ?? AppRules() }
        self.sim = sim
        self.edge = edge
        edge.onButton = { [weak self] i in self?.pressed(i) }
        edge.onPoke = { [weak self] in self?.poked() }
        presence.greetingOverride = { [weak self] in self?.takeReturnLine() }
        presence.onWake = { [weak self] in self?.backFromAway() }
        escalation.chilkFrame = { [weak edge] in edge?.windowFrame ?? .zero }
        escalation.onExit = { [weak self] reason, minutes, held in self?.emergencyExit(reason: reason, minutes: minutes, held: held) ?? false }
        escalation.onHolding = { [weak sim] holding in sim?.isSad = holding }
        escalation.log = { [weak self] in self?.log($0) }
        escalation.onStartBreak = { [weak self] in self?.startFromPause() }
        escalation.onStopGuide = { [weak self] in self?.stopGuided() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.2
        // Acceptance runs: CHILK_DEMO_DUE=stretch makes a need due 3 s after launch.
        if let raw = env["CHILK_DEMO_DUE"], let n = Need(rawValue: raw) {
            Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.makeDue(n) }
            }
        }
        // CHILK_DEMO_FOCUS=<seconds>: focus mode 4 s after launch (the popover's path, any length ≥ 60 s).
        if let seconds = env["CHILK_DEMO_FOCUS"].flatMap(Double.init) {
            Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    if case .started = self?.startFocus(seconds: seconds) { self?.announceFocus() }
                }
            }
        }
        // CHILK_DEMO_GUIDE=warmup|walk: a guided break 5 s after launch; CHILK_DEMO_GUIDE_STOP=<s>: «Прервать».
        if let raw = env["CHILK_DEMO_GUIDE"], let kind = GuidedKind(rawValue: raw) {
            Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { kind == .warmup ? self?.startWarmup() : self?.startWalk() }
            }
        }
    }

    // MARK: Loop

    private func tick() {
        let s = monitor.snapshot()
        if let front = s.frontApp, front != lastSignals?.frontApp, front != Bundle.main.bundleIdentifier {
            settings.noteFront(front)
        }
        lastSignals = s
        let events = engine.tick(s)
        if logURL != nil {
            if ticks % 10 == 0 {
                log(String(format: "signals idle=%.0fs locked=%d front=%@ %@ fullscreen=%d call=%d video=%d | water %.0f%% stretch %.0f%% eyes %.0f%% walk %.0f%% day %.0f%% | eyes strain %.2f",
                           s.idle, s.locked ? 1 : 0, s.frontApp ?? "-", s.category.rawValue, s.fullscreen ? 1 : 0, s.inCall ? 1 : 0, s.video ? 1 : 0,
                           engine.pressure(.water) * 100, engine.pressure(.stretch) * 100, engine.pressure(.eyes) * 100,
                           engine.pressure(.walk) * 100, engine.pressure(.endOfDay) * 100, engine.eyeStrain))
            }
            for e in events { log("event \(e)") }
        }
        ticks += 1
        apply(events)
        syncEscalation()
        sim.fatigue = engine.leafFatigue
        sim.eyeStrain = engine.eyeStrain
        if let e = engine.state.episode, e.stage == 0, e.phase == .showing, activity == nil, !isBusy(),
           Date().timeIntervalSince(lastPantomime) > 25 {
            pantomime(e.need)
        }
        if Date().timeIntervalSince(lastSave) > 30 { save() }
        if !demoPresses.isEmpty, !buttonActions.isEmpty {
            if let since = demoPressSince, Date().timeIntervalSince(since) >= 2 {
                demoPressSince = nil
                pressed(demoPresses.removeFirst())
            } else if demoPressSince == nil { demoPressSince = Date() }
        } else { demoPressSince = nil }
    }

    private func apply(_ events: [BalanceEvent]) {
        // The end of a focus with a request on screen: «Фокус закончился…» first, the request a moment later.
        guard events.contains(.focusEnded), !isBusy() else {
            for event in events { apply(event) }
            return
        }
        for event in events { if case .ask = event { continue } else { apply(event) } }
        Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isBusy() else { return }        // a new conversation resumes it itself
                self.resume()
            }
        }
    }

    private func apply(_ event: BalanceEvent) {
        if isBusy() {
            if case .nudge = event { onNudge() }
            if event == .focusEnded { focusEndedUnsaid = true }     // said after the conversation
            return
        }
        if event != .nudge { cancelIntro() }
        switch event {
        case .hint(let n):
            hideBubble()
            sim.standOut = .docked
            pantomime(n)

        case .ask(let n, let stage, let buttons, let again):
            guard activity == nil else { return }
            if stage == 1, !again {
                // Soft / Strict start on the bubble; the need's pantomime is its intro (6a, decision 33).
                hideBubble()
                sim.standOut = .docked
                if n == .walk { sim.wear(.hat) }
                let length = pantomime(n)
                log("intro \(n.rawValue) \(String(format: "%.1f", min(length, 4.2)))s")
                introShow = { [weak self] in self?.showAsk(n, stage: stage, buttons: buttons, again: again) }
                introTimer = Timer.scheduledTimer(withTimeInterval: min(length, 4.2), repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finishIntro() }
                }
                return
            }
            showAsk(n, stage: stage, buttons: buttons, again: again)

        case .nudge:
            onNudge()

        default:
            applyOther(event)
        }
    }

    /// The bubble of a request (stage ≥ 1).
    private func showAsk(_ n: Need, stage: Int, buttons: [Reaction], again: Bool) {
            sim.standOut = stage >= 3 ? .center : (stage >= 2 ? .out : .peek)
            if n == .walk { sim.wear(.hat) }
            if n == .endOfDay && stage >= 2 { sim.wear(.backpack) }
            switch stage {
            case 4...:
                buttonActions = []
                sim.say(Lines.pause(n), duration: .infinity)
                edge.raised = true
                escalation.pause(exitsLeft: engine.state.exitsLeft, restNeeded: engine.pauseRest ?? engine.config.walkRest,
                                 breakTitle: n == .stretch ? Lines.startWarmup : (n == .walk ? Lines.goWalk : nil))
                if let after = env["CHILK_DEMO_PAUSE_BREAK"].flatMap(Double.init) {
                    Timer.scheduledTimer(withTimeInterval: after, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated { self?.startFromPause() }
                    }
                }
                scheduleDemoExit()
                if let path = env["CHILK_DEMO_SNAPSHOT"] {
                    Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.escalation.snapshot(to: URL(fileURLWithPath: path), openForm: false)
                            self?.escalation.snapshot(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-form.png")),
                                                      openForm: true)
                        }
                    }
                }
            case 3:
                sim.say(again ? Lines.ask(n, stage: stage, again: true) : Lines.disturb(n), buttons: buttons.map { Lines.button($0, for: n) })
                buttonActions = buttons.map { action(for: $0, need: n) }
                edge.raised = false
                escalation.dim()
            default:
                sim.say(Lines.ask(n, stage: stage, again: again), buttons: buttons.map { Lines.button($0, for: n) })
                buttonActions = buttons.map { action(for: $0, need: n) }
            }
    }

    /// The intro ended (or the user clicked him): the bubble — if the same request is still on screen and free.
    private func finishIntro() {
        guard let show = introShow else { return }
        cancelIntro()
        guard activity == nil, !isBusy(), let e = engine.state.episode, e.phase == .showing, e.stage >= 1 else { return }
        log("intro done: bubble \(e.need.rawValue)")
        show()
    }

    private func cancelIntro() {
        introTimer?.invalidate()
        introTimer = nil
        introShow = nil
    }

    private func applyOther(_ event: BalanceEvent) {
        switch event {
        case .hint, .ask, .nudge:
            break

        case .withdraw:
            guard activity == nil else { return }
            hideBubble()
            sim.standOut = .docked
            if !walking { tidyProps() }

        case .promised(let n):
            buttonActions = []
            switch n {
            case .eyes:
                startEyeGym(forEpisode: true)
            case .stretch:
                // «Иду» → «Разминка со мной» / «Сам» (user decision «2», 2026-10-05).
                sim.standOut = .peek
                sim.say(Lines.stretchHow, buttons: [Lines.warmupWithMe, Lines.onMyOwn])
                buttonActions = [{ [weak self] in self?.startWarmup() }, { [weak self] in self?.stretchOnMyOwn() }]
            case .walk:
                walking = true
                sim.standOut = .out
                sim.wear(.hat)
                sim.wear(.backpack)
                sim.perform(.wave)
                sim.say(Lines.idea(hour: sim.hourOfDay), duration: 8)
                settle(after: 8)
            case .endOfDay:
                sim.perform(.pack)
                sim.say(Lines.endOfDayBye.randomElement()!, duration: 6)
                settle(after: 6)
            case .water:
                break
            }

        case .credited(let n, let byRest, let ended):
            guard ended else { return }
            buttonActions = []
            if byRest {
                // The user is away right now: say it when they are back.
                returnLine = Lines.thanks(n)
                if n == .walk { cheerOnReturn = true }
                sim.clearBubble()
                sim.standOut = .docked
            } else {
                if n == .water { sim.perform(.drink) }
                if n != .eyes { sim.say(Lines.thanks(n), duration: 3.5) }
                settle(after: 3.5)
            }

        case .snoozed:
            buttonActions = []
            sim.say(Lines.snoozed.randomElement()!, duration: 2.8)
            settle(after: 2.8, takeOffProps: true)

        case .deferred(_, let minutes):
            buttonActions = []
            sim.say(Lines.deferred(minutes), duration: 3)
            settle(after: 3, takeOffProps: true)

        case .tooSoon:
            // Not counted: say so, then the request (if any) comes back as it was.
            sim.say(Lines.tooSoonWater, duration: 3)
            Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            }

        case .released(_, let minutes):
            buttonActions = []
            syncEscalation()
            sim.say(Lines.released(minutes), duration: 3.5)
            settle(after: 3.5, takeOffProps: true)

        case .mood:
            guard activity == nil, !sim.isTalking, !sim.isAsleep else { return }
            sim.say(Lines.jokes.randomElement()!, duration: 5)
            if Bool.random() { sim.perform(.wave) }

        case .focusEnded:
            guard activity == nil else { return }
            sim.say(Lines.focusEnded.randomElement()!, duration: 4)
        }
    }

    /// Plays the need's own pantomime; returns how long it lasts.
    @discardableResult
    private func pantomime(_ n: Need) -> Double {
        let act: Act
        switch n {
        case .water: act = .drink
        case .stretch: act = .hops                                  // 6a, decision 5: chaotic hops, not stretches
        case .eyes: act = .lookAway
        case .walk: sim.wear(.hat); act = .wave
        case .endOfDay: act = .pack
        }
        sim.perform(act)
        lastPantomime = Date()
        return act.duration
    }

    private func react(_ r: Reaction) {
        apply(engine.handle(r))
        syncEscalation()
    }

    /// «Я занят» first asks «Через сколько вернуться?» (15 / 30 / 60 мин, decision 2026-10-05).
    private func action(for r: Reaction, need n: Need) -> () -> Void {
        r == .busy ? { [weak self] in self?.askHowLong() } : { [weak self] in self?.react(r) }
    }

    private func askHowLong() {
        let minutes = engine.config.busyMinutes
        sim.say(Lines.busyHowLong, buttons: minutes.map(Lines.minutesLabel))
        buttonActions = minutes.map { m in
            { [weak self] in
                guard let self else { return }
                self.apply(self.engine.deferBusy(minutes: m))
                self.syncEscalation()
            }
        }
    }

    /// The shade and the pause exist only while the engine shows stage 3–4. Every way out (rest, a promise,
    /// a call, an exit, a softer mode, a new day) ends here, even while a conversation holds the stage.
    private func syncEscalation() {
        guard guidedRun == nil else { return }                 // the guided break owns the dark screen
        let shown = engine.state.episode.flatMap { $0.phase == .showing ? $0.stage : nil } ?? 0
        if shown < 3 || (shown == 3 && escalation.level == .pause) {
            if escalation.level != .none { escalation.lift() }
            if edge.raised { edge.raised = false }
            sim.isSad = false
            if sim.standOut == .center { sim.standOut = engine.state.episode?.phase == .showing ? .out : .docked }
        }
        if shown >= 4, let rest = engine.pauseRest {
            escalation.update(restLeft: max(0, rest - (lastSignals?.idle ?? 0)), exitsLeft: engine.state.exitsLeft)
        }
    }

    // MARK: Settings (slice 5c, decisions 19–20)

    /// «Договор с собой»: a request is on stage 3–4, so nothing may soften care.
    var settingsLocked: Bool { engine.settingsLocked }

    /// A click in Settings → «Забота». `false` = refused by the engine (it softens during stages 3–4).
    @discardableResult
    func changeCare(_ change: CareChange) -> Bool {
        let events: [BalanceEvent]
        do {
            events = try engine.setCare(engine.state.care.applying(change))
        } catch {
            log("care \(change) refused")
            return false
        }
        save()
        log("care \(change)")
        apply(events)
        syncEscalation()
        return true
    }

    /// Settings → apps: `nil` = automatic. `false` = refused (softer during stages 3–4).
    @discardableResult
    func setCategory(_ id: String, to category: AppCategory?) -> Bool {
        let automatic = AppCatalog.automatic(bundleID: id)
        do {
            try settings.update { try $0.apps.set(id, to: category, automatic: automatic, locked: engine.settingsLocked) }
            log("app category \(id) → \(category?.rawValue ?? "auto")")
            return true
        } catch {
            log("app category \(id) → \(category?.rawValue ?? "auto") refused")
            return false
        }
    }

    // MARK: Modes (В16) and the emergency exit (В13)

    var mode: BalanceMode { engine.state.mode }

    /// `false` = refused: no softer mode during stages 3–4 («договор с собой»).
    @discardableResult
    func setMode(_ m: BalanceMode) -> Bool {
        do {
            let events = try engine.setMode(m)
            save()
            log("mode \(m.rawValue)")
            apply(events)
            syncEscalation()
            return true
        } catch {
            log("mode \(m.rawValue) refused")
            return false
        }
    }

    // MARK: Persuasion and focus (slice 4b, SPEC «Уговоры и фокус (В14)»)

    var focusUntil: Date? { engine.state.focusUntil }
    /// The focus ended while a conversation had the stage: its line comes after it (unless a request speaks first).
    private var focusEndedUnsaid = false

    private static func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
    private static func iso(_ d: Date) -> String {
        ISO8601DateFormatter.string(from: d, timeZone: .current, formatOptions: [.withInternetDateTime])
    }

    /// `chilk_defer`: Codex judged the reason, the engine holds the frame. The conversation owns the stage meanwhile.
    func persuade(minutes: Int) -> JSON {
        let need = engine.state.episode?.need
        do {
            let events = try engine.committing(Self.write) { try engine.persuade(minutes: minutes) }
            lastSave = Date()
            var granted = minutes
            for case .deferred(_, let m) in events { granted = m }
            log("persuaded \(need?.rawValue ?? "-") \(granted) min (asked \(minutes))")   // the reason stays out of logs
            apply(events)
            syncEscalation()
            let back = Date().addingTimeInterval(Double(granted) * 60 / max(engine.config.timeScale, 1e-6))   // engine clock
            return ["deferred": true, "need": .string(need?.rawValue ?? ""), "minutes": .number(Double(granted)),
                    "cut": .bool(granted < minutes), "back": .string(Self.iso(back))]
        } catch {
            guard let refusal = error as? BalanceRefusal else {
                log("persuasion not saved")
                return ["deferred": false, "refused": "not_saved"]
            }
            let code = switch refusal {
            case .nothingToDefer: "nothing_to_defer"
            case .pauseInProgress: "pause_in_progress"
            default: "limit_reached"
            }
            log("persuasion refused \(code)")
            let snooze = engine.state.episode.map { engine.buttons(for: $0.need, stage: $0.stage).contains(.snooze) } ?? false
            return ["deferred": false, "refused": .string(code), "snoozeButtonLeft": .bool(snooze)]
        }
    }

    enum FocusOutcome: Equatable {
        case started(until: Date, shortened: Bool)
        case refused(BalanceRefusal)
        case notSaved
    }

    /// The popover «Фокус…», `chilk_focus` and the acceptance hook. Says nothing itself: see `announceFocus`.
    @discardableResult
    func startFocus(seconds: TimeInterval) -> FocusOutcome {
        do {
            let start = try engine.committing(Self.write) { try engine.startFocus(seconds: seconds, now: Date()) }
            lastSave = Date()
            log("focus until \(Self.clock(start.until)) (asked \(Int(seconds / 60)) min\(start.shortened ? ", shortened" : ""))")
            apply(start.events)
            syncEscalation()
            return .started(until: start.until, shortened: start.shortened)
        } catch {
            guard let refusal = error as? BalanceRefusal else {
                log("focus not saved")
                return .notSaved
            }
            log("focus refused \(refusal)")
            return .refused(refusal)
        }
    }

    /// «Фокус до 18:00…» at the edge, unless something else has the stage.
    func announceFocus() {
        guard let until = engine.state.focusUntil, !isBusy(), activity == nil, engine.state.episode?.phase != .showing else { return }
        sim.say(Lines.focusOn(until: Self.clock(until)), duration: 3.5)
    }

    /// `chilk_focus`: the conversation says it.
    func focusFromConversation(minutes: Int) -> JSON {
        switch startFocus(seconds: Double(minutes) * 60) {
        case .started(let until, let shortened):
            return ["focus": true, "until": .string(Self.iso(until)), "untilLocal": .string(Self.clock(until)),
                    "minutes": .number((until.timeIntervalSinceNow / 60).rounded()), "shortened": .bool(shortened)]
        case .refused(let r):
            return ["focus": false, "refused": .string(r == .focusSpent ? "focus_spent_today" : "escalation_in_progress")]
        case .notSaved:
            return ["focus": false, "refused": "not_saved"]
        }
    }

    /// «Закончить» / `chilk_end_focus`: what piled up comes back at «настаивает» right away. `false` = no focus.
    @discardableResult
    func endFocus() -> Bool {
        let events = engine.endFocus(now: Date())
        guard !events.isEmpty else { return false }
        save()
        log("focus ended early")
        apply(events)
        syncEscalation()
        return true
    }

    private func emergencyExit(reason: String, minutes: Int, held: Bool) -> Bool {
        do {
            let events = try engine.emergencyExit(reason: reason, minutes: minutes, held: held, now: Date())
            save()
            log("emergency exit \(minutes) min held=\(held) left=\(engine.state.exitsLeft)")   // the reason stays out of logs
            apply(events)
            syncEscalation()
            return true
        } catch {
            log("emergency exit refused \(error)")
            return false
        }
    }

    /// CHILK_DEMO_EXIT=<reason> (acceptance only): the pause is left through its own form after
    /// CHILK_DEMO_EXIT_AFTER seconds (default 6), so an unattended run never holds the screen for long.
    private func scheduleDemoExit() {
        guard let reason = env["CHILK_DEMO_EXIT"], !demoExitScheduled else { return }
        demoExitScheduled = true
        let after = env["CHILK_DEMO_EXIT_AFTER"].flatMap(Double.init) ?? 6
        Timer.scheduledTimer(withTimeInterval: after, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.demoExitScheduled = false
                self?.escalation.demoExit(reason: reason)
            }
        }
    }

    private func hideBubble() {
        buttonActions = []
        sim.clearBubble()
    }

    /// Back to the edge after a reaction; props off unless he is out walking with the user.
    private func settle(after seconds: Double, takeOffProps: Bool = false) {
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.activity == nil, self.engine.state.episode?.phase != .showing else { return }
                self.sim.standOut = .docked
                if takeOffProps || !self.walking { self.tidyProps() }
            }
        }
    }

    private func tidyProps() {
        sim.takeOff(.hat)
        sim.takeOff(.backpack)
    }

    // MARK: Input from the panel

    private func pressed(_ index: Int) {
        guard index < buttonActions.count else { return }
        log("button \(index)")
        let action = buttonActions[index]
        hideBubble()
        action()
    }

    func poked() {
        guard activity == nil else { return }
        if introShow != nil { return finishIntro() }               // a click skips the intro
        apply(engine.pokedDuringHint())
    }

    private func backFromAway() {
        if walking || engine.state.episode == nil {
            if walking { cheerOnReturn = true }
            walking = false
            tidyProps()
            sim.standOut = .docked
        }
        if cheerOnReturn {
            cheerOnReturn = false
            cheer()
        }
    }

    /// «Ликует» (6a, decision 6): he steps out from behind the edge to jump, then goes back.
    func cheer() {
        guard activity == nil, !isBusy() else { return }
        log("cheer")
        if engine.state.episode?.phase != .showing { sim.standOut = .peek }
        sim.perform(.cheer)
        settle(after: Act.cheer.duration + 0.4)
    }

    private func takeReturnLine() -> String? {
        defer { returnLine = nil }
        return returnLine
    }

    // MARK: Breaks (В18)

    /// Чилк flies a figure-eight over the screen, then «посмотри вдаль» for 20 seconds.
    func startEyeGym(forEpisode: Bool = false) {
        guard activity == nil else { return }
        activity = .eyeGym
        hideBubble()
        sim.standOut = .docked
        sim.eyesWide = true
        sim.say(Lines.gymFollow, duration: 3)
        edge.fly(duration: 14) { [weak self] in self?.lookFar(forEpisode: forEpisode) }
    }

    private func lookFar(forEpisode: Bool) {
        sim.eyesWide = false
        sim.standOut = .peek
        var left = 20
        sim.say(Lines.lookFar(left), duration: .infinity)
        activityTimer?.invalidate()
        activityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                left -= 1
                if left > 0 { return self.sim.updateBubble(Lines.lookFar(left)) }
                self.activityTimer?.invalidate()
                self.activity = nil
                self.sim.say(Lines.thanks(.eyes), duration: 3)
                self.settle(after: 3)
                if forEpisode || self.engine.state.episode?.need == .eyes {
                    _ = self.engine.handle(.done)
                } else {
                    _ = self.engine.tookRest(.eyes)
                }
            }
        }
    }

    /// Breathe with Чилк: he inflates on the in-breath (4 s) and deflates on the out-breath (6 s).
    func startBreathing(minutes: Double) {
        guard activity == nil else { return }
        activity = .breathing
        hideBubble()
        sim.standOut = .out
        sim.perform(.breathe(seconds: minutes * 60))
        sim.say(Lines.inhale, buttons: [Lines.enough])
        buttonActions = [{ [weak self] in self?.finishBreathing() }]
        var inhaling = true
        activityTimer?.invalidate()
        activityTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let b = self.sim.breath else { return self.finishBreathing() }
                if b.inhaling != inhaling {
                    inhaling = b.inhaling
                    self.sim.updateBubble(inhaling ? Lines.inhale : Lines.exhale)
                }
            }
        }
    }

    private func finishBreathing() {
        activityTimer?.invalidate()
        activity = nil
        buttonActions = []
        sim.stopAct()
        sim.say(Lines.breathedWell, duration: 3)
        settle(after: 3)
    }

    private func stretchOnMyOwn() {
        sim.standOut = .peek
        sim.perform(.stretches)
        sim.say(Lines.stretchTips.randomElement()!, duration: 8)
        settle(after: 8)
    }

    // MARK: Guided warm-up and walk (decisions 2026-10-05)

    /// Entry points for the tray popup (slice 5a) and the voice tools.
    func startWarmup() { startGuided(.warmup) }
    func startWalk() { startGuided(.walk) }

    /// A break asked for by voice: refused while another runs or while a pause it would not end is up.
    func queueBreak(_ b: ChilkBreak) -> JSON {
        if activity != nil || guidedRun != nil { return ["willStart": false, "reason": "another_break_in_progress"] }
        if escalation.level == .pause, let need = engine.state.episode?.need {
            let fits = (b == .warmup && need == .stretch) || (b == .walk && (need == .walk || need == .stretch))
            if !fits { return ["willStart": false, "reason": "pause_in_progress"] }
        }
        pendingBreak = (b, Date())
        log("break queued \(b)")
        return ["willStartAfterReply": true]
    }

    private func startBreak(_ b: ChilkBreak) {
        log("break from voice \(b)")
        switch b {
        case .eyeGym: startEyeGym()
        case .warmup: startWarmup()
        case .walk: startWalk()
        case .breathe(let minutes): startBreathing(minutes: Double(minutes))
        }
    }

    /// «Начать разминку» / «Иду гулять» on the pause.
    private func startFromPause() {
        guard let need = engine.state.episode?.need else { return }
        if need == .stretch { startWarmup() } else if need == .walk { startWalk() }
    }

    private func startGuided(_ kind: GuidedKind) {
        guard activity == nil, guidedRun == nil else { return }
        let session: GuidedSession
        var source: WarmupSource.Origin?
        switch kind {
        case .warmup:
            var rng = SystemRandomNumberGenerator()
            let taken: (steps: [Exercise], origin: WarmupSource.Origin) = warmups?.take()
                ?? (Warmup.compose(from: Lines.warmupLibrary, using: &rng) ?? [], .library)
            guard Warmup.isValid(taken.steps) else { return log("guided warmup unavailable") }
            session = GuidedSession(.warmup(taken.steps), started: ProcessInfo.processInfo.systemUptime)
            source = taken.origin
        case .walk:
            session = GuidedSession(.walk, started: ProcessInfo.processInfo.systemUptime)
        }
        let origin = engine.beginGuided(kind)
        activity = .guided
        buttonActions = []
        settleTimer?.invalidate()
        activityTimer?.invalidate()
        sim.isSad = false
        guidedRun = GuidedRun(session: session, kind: kind, origin: origin, idea: Lines.idea(hour: sim.hourOfDay), source: source)
        escalation.guide(caption: kind == .warmup ? Lines.warmupCaption(step: 1, of: Warmup.stepCount) : Lines.walkCaption)
        edge.raised = true
        sim.standOut = .center
        if kind == .walk { sim.wear(.hat); sim.wear(.backpack); sim.perform(.wave) }
        sim.say(kind == .warmup ? Lines.warmupStart : Lines.walkCountdown(guidedRun!.idea, left: GuidedSession.clock(session.duration)),
                duration: .infinity)
        log("guided \(kind.rawValue) started origin=\(origin.rawValue) source=\(source?.rawValue ?? "-")")
        guideTimer?.invalidate()
        guideTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.guideTick() }
        }
        if let path = env["CHILK_DEMO_GUIDE_SNAPSHOT"] {
            Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.escalation.snapshot(to: URL(fileURLWithPath: path), openForm: false) }
            }
        }
        if let after = env["CHILK_DEMO_GUIDE_STOP"].flatMap(Double.init) {
            Timer.scheduledTimer(withTimeInterval: after, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.escalation.demoStopGuide() }
            }
        }
    }

    private func guideTick() {
        guard var run = guidedRun else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        let now = run.session.started + (uptime - run.session.started) * guideScale
        guard let step = run.session.step(at: now) else { return finishGuided() }
        guard !isBusy() else { return }                        // a conversation has the bubble for now
        switch run.session.kind {
        case .warmup(let steps):
            let exercise = steps[step.index]
            if step.index != run.step {
                run.step = step.index
                run.lastMove = 0
                escalation.guide(caption: Lines.warmupCaption(step: step.index + 1, of: steps.count))
                log("guided step \(step.index + 1) \(exercise.kind.rawValue)/\(exercise.move.rawValue)")
                if exercise.move == .breathe { sim.perform(.breathe(seconds: step.left / guideScale)) }
                if exercise.move == .still { sim.stopAct() }
            }
            if [.stretch, .lookFar, .wave].contains(exercise.move), uptime - run.lastMove > 6 {
                run.lastMove = uptime
                sim.perform(exercise.move == .stretch ? .stretches : exercise.move == .lookFar ? .lookAway : .wave)
            }
            let elapsed = now - run.session.started
            sim.updateBubble(step.index == 0 && elapsed < 4 ? Lines.warmupStart
                             : Lines.warmupStep(exercise.text, left: GuidedSession.clock(step.left)))
        case .walk:
            sim.updateBubble(Lines.walkCountdown(run.idea, left: GuidedSession.clock(step.left)))
        }
        guidedRun = run
    }

    private func finishGuided() {
        guard let run = guidedRun else { return }
        guideTimer?.invalidate()
        guidedRun = nil
        activity = nil
        let events = engine.finishGuided(run.session)
        save()
        log("guided \(run.kind.rawValue) finished: \(events)")
        if run.kind == .warmup { warmups?.prepareIfNeeded() }          // the next one, written ahead
        endGuideScreen(walk: run.kind == .walk)
        sim.say(run.kind == .warmup ? Lines.warmupDone : Lines.walkDone, duration: 4)
        if run.kind == .walk { sim.perform(.cheer) }                  // a walk that counted (6a, decision 6)
        syncEscalation()
        settle(after: 4, takeOffProps: true)
        Timer.scheduledTimer(withTimeInterval: 4.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }      // another need's request, if one is waiting
        }
    }

    /// «Прервать»: free when the user asked; after «Иду» a broken promise; from the pause, back to it.
    private func stopGuided() {
        guard let run = guidedRun else { return }
        guideTimer?.invalidate()
        guidedRun = nil
        activity = nil
        let events = engine.interruptGuided()
        save()
        log("guided \(run.kind.rawValue) interrupted origin=\(run.origin.rawValue) events=\(events)")
        if case .warmup(let steps) = run.session.kind, let source = run.source { warmups?.giveBack(steps, origin: source) }
        endGuideScreen(walk: run.kind == .walk)
        if events.isEmpty {
            sim.say(Lines.guideStopped, duration: 3)
            settle(after: 3, takeOffProps: true)
        } else {
            apply(events)
            syncEscalation()
        }
    }

    private func endGuideScreen(walk: Bool) {
        escalation.lift()
        edge.raised = false
        sim.stopAct()
        if walk { tidyProps() }
        sim.standOut = .peek
    }

    func drankWater() {
        let events = engine.state.episode?.need == .water ? engine.handle(.done) : engine.tookRest(.water)
        if events.isEmpty { return }
        hideBubble()
        if events.contains(.tooSoon(.water)) { return apply(events) }
        sim.perform(.drink)
        sim.say(Lines.thanks(.water), duration: 3.5)
        settle(after: 3.5)
    }

    /// The conversation owns the stage; water only changes and persists aggregates here.
    /// `false` = not counted: the last glass was less than 20 minutes ago.
    func creditWaterFromVoice() throws -> Bool {
        let events = try engine.tookRest(.water, persisting: Self.write)
        lastSave = Date()
        return !events.contains(.tooSoon(.water))
    }

    /// An explicit timer outranks balance prompts (they come back after it); it only waits for an exercise
    /// in progress and an unlocked screen. Conversations are checked by `Actions` itself.
    var canPresentScheduledNotice: Bool {
        activity == nil && guidedRun == nil && lastSignals?.locked != true && escalation.level == .none
    }

    // MARK: Manual testing (tray right-click «Проверка»)

    func makeDue(_ n: Need) {
        hideBubble()
        engine.makeDue(n)
    }

    func showPressure() {
        let parts = [Need.water, .stretch, .eyes, .walk, .endOfDay].map { "\(Lines.name($0)) \(Int((engine.pressure($0) * 100).rounded()))%" }
        sim.say(parts.joined(separator: " · "), duration: 7)
    }

    var timeScale: Double {
        get { engine.config.timeScale }
        set { engine.config.timeScale = newValue }
    }

    func resetNeeds() {
        hideBubble()
        engine.resetAll()
        sim.standOut = .docked
        tidyProps()
        save()
    }

    // MARK: Persistence (~/Library/Application Support/Chilk/balance.json, aggregates only — В24)

    private static var stateURL: URL {
        AppState.directory.appendingPathComponent("balance.json")
    }

    private static func load() -> BalanceState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(BalanceState.self, from: data)
    }

    func save() {
        lastSave = Date()
        try? Self.write(engine.state)
    }

    private static func write(_ state: BalanceState) throws {
        let url = stateURL
        let data = try JSONEncoder().encode(state)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
