import AppKit
import ChilkCore

/// Slice 2 in the app: signals → `BalanceEngine` → what Чилк does (pantomime, bubble with buttons,
/// standing out, Dock bounce) and the breaks themselves (eye gymnastics, breathing, water, walk).
@MainActor
final class BalanceController {
    let engine: BalanceEngine
    private let sim: CharacterSim
    private let edge: EdgeController
    private let monitor = SignalMonitor()
    private var timer: Timer?
    private var activityTimer: Timer?
    private var settleTimer: Timer?
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

    private enum Activity { case eyeGym, breathing }

    /// While Чилк talks with the user the stage is theirs: balance keeps counting but shows nothing.
    var isBusy: () -> Bool = { false }

    /// After a conversation: show the current prompt again (if any).
    func resume() {
        if let prompt = engine.currentPrompt() { apply(prompt) }
    }

    /// Minutes since the last real stretch break — the only activity fact sent to Codex (В24).
    var sittingMinutes: Int { Int((engine.state.needs[.stretch]?.sitting ?? 0) / 60) }

    init(sim: CharacterSim, edge: EdgeController, presence: PresenceMonitor) {
        var config = BalanceConfig()
        if let scale = ProcessInfo.processInfo.environment["CHILK_TIME_SCALE"].flatMap(Double.init) { config.timeScale = scale }
        engine = BalanceEngine(config: config, restoring: Self.load())
        self.sim = sim
        self.edge = edge
        edge.onButton = { [weak self] i in self?.pressed(i) }
        edge.onPoke = { [weak self] in self?.poked() }
        presence.greetingOverride = { [weak self] in self?.takeReturnLine() }
        presence.onWake = { [weak self] in self?.backFromAway() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.2
    }

    // MARK: Loop

    private func tick() {
        let s = monitor.snapshot()
        lastSignals = s
        let events = engine.tick(s)
        if logURL != nil {
            if ticks % 10 == 0 {
                log(String(format: "signals idle=%.0fs locked=%d front=%@ %@ fullscreen=%d call=%d video=%d | water %.0f%% stretch %.0f%% eyes %.0f%% walk %.0f%% day %.0f%%",
                           s.idle, s.locked ? 1 : 0, s.frontApp ?? "-", s.category.rawValue, s.fullscreen ? 1 : 0, s.inCall ? 1 : 0, s.video ? 1 : 0,
                           engine.pressure(.water) * 100, engine.pressure(.stretch) * 100, engine.pressure(.eyes) * 100,
                           engine.pressure(.walk) * 100, engine.pressure(.endOfDay) * 100))
            }
            for e in events { log("event \(e)") }
        }
        ticks += 1
        apply(events)
        sim.fatigue = engine.leafFatigue
        if let e = engine.state.episode, e.stage == 0, e.phase == .showing, activity == nil,
           Date().timeIntervalSince(lastPantomime) > 25 {
            pantomime(e.need)
        }
        if Date().timeIntervalSince(lastSave) > 30 { save() }
    }

    private func apply(_ events: [BalanceEvent]) {
        for event in events { apply(event) }
    }

    private func apply(_ event: BalanceEvent) {
        if isBusy() {
            if case .bounceDock = event { NSApp.requestUserAttention(.informationalRequest) }
            return
        }
        switch event {
        case .hint(let n):
            hideBubble()
            sim.standOut = .docked
            pantomime(n)

        case .ask(let n, let stage, let buttons, let again):
            guard activity == nil else { return }
            sim.standOut = stage >= 2 ? .out : .peek
            if n == .walk { sim.wear(.hat) }
            if n == .endOfDay && stage >= 2 { sim.wear(.backpack) }
            sim.say(Lines.ask(n, stage: stage, again: again), buttons: buttons.map { Lines.button($0, for: n) })
            buttonActions = buttons.map { r in { [weak self] in self?.react(r) } }

        case .bounceDock:
            NSApp.requestUserAttention(.informationalRequest)

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
                sim.standOut = .peek
                sim.perform(.stretches)
                sim.say(Lines.stretchTips.randomElement()!, duration: 8)
                settle(after: 8)
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

        case .deferred:
            buttonActions = []
            sim.say(Lines.deferred.randomElement()!, duration: 3)
            settle(after: 3, takeOffProps: true)

        case .mood:
            guard activity == nil, !sim.isTalking, !sim.isAsleep else { return }
            sim.say(Lines.jokes.randomElement()!, duration: 5)
            if Bool.random() { sim.perform(.wave) }
        }
    }

    private func pantomime(_ n: Need) {
        switch n {
        case .water: sim.perform(.drink)
        case .stretch: sim.perform(.stretches)
        case .eyes: sim.perform(.lookAway)
        case .walk: sim.wear(.hat); sim.perform(.wave)
        case .endOfDay: sim.perform(.pack)
        }
        lastPantomime = Date()
    }

    private func react(_ r: Reaction) {
        apply(engine.handle(r))
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
        apply(engine.pokedDuringHint())
    }

    private func backFromAway() {
        if walking || engine.state.episode == nil {
            walking = false
            tidyProps()
            sim.standOut = .docked
        }
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

    func drankWater() {
        let events = engine.state.episode?.need == .water ? engine.handle(.done) : engine.tookRest(.water)
        if events.isEmpty { return }
        hideBubble()
        sim.perform(.drink)
        sim.say(Lines.thanks(.water), duration: 3.5)
        settle(after: 3.5)
    }

    /// The conversation owns the stage; water only changes and persists aggregates here.
    func creditWaterFromVoice() throws {
        _ = try engine.tookRest(.water, persisting: Self.write)
        lastSave = Date()
    }

    var canPresentScheduledNotice: Bool {
        !isBusy() && activity == nil && !sim.isTalking && lastSignals?.locked != true
    }

    // MARK: Manual testing (Dock «Проверка»)

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
