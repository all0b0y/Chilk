import AppKit
import ChilkBrain
import ChilkCore

/// Slice 6d (decisions 17–19): Chilk hidden behind the screen edge. «Hidden» only moves his home behind the edge
/// (`CharacterSim.hidden`): everything that brings him out — a conversation, a due timer, a break, the tray — still
/// does, and he goes back by himself. Kept in `hideout.json` in the state folder (not UserDefaults: acceptance copies
/// share the bundle id and would hide the user's Chilk).
@MainActor
final class HideController {
    private let sim: CharacterSim
    private let file: URL
    private(set) var state: Hideout
    private var rng = SystemRandom()
    private let env = ProcessInfo.processInfo.environment
    private var lookTimer: Timer?
    /// He leans out right now (a peek or a «not staying» look): a click brings him out for good.
    private(set) var lurking = false
    /// What a conversation or a chat turn asked for (`chilk_hide`): applied when it closes.
    private var pending: Bool?
    private var ticks = 0

    var log: (String) -> Void = { _ in }
    /// `chilk_hide(true)` arrived: a voice conversation ends at once (6d).
    var onHideAsked: () -> Void = {}
    /// Chilk is idle at home (no conversation, timer, bubble, break, popover): only then he peeks.
    var canPeek: () -> Bool = { false }
    /// He came out for good (tray, click, a roll, Codex): the request on screen, if any, shows again.
    var onShown: () -> Void = {}

    var isHidden: Bool { state.hidden }

    init(sim: CharacterSim) {
        self.sim = sim
        file = AppState.directory.appending(path: "hideout.json")
        var s = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Hideout.self, from: $0) } ?? Hideout()
        // Acceptance: CHILK_DEMO_HIDE=1 starts hidden, =later hides 4 s after launch (the dive and the «пф!»);
        // CHILK_DEMO_PEEK_EVERY=<s> peeks after that much work.
        let demo = env["CHILK_DEMO_HIDE"]
        if let demo, demo != "later", !s.hidden { s.hide(rng: &rng) }
        state = s
        if s.hidden, let every = demoPeekEvery { state.postpone(every) }
        sim.hidden = state.hidden
        sim.snapHidden()                                   // already behind the edge at launch: no dive, no «пф!»
        if demo == "later" {
            lookTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide("demo") }
            }
        }
    }

    private var demoPeekEvery: Double? { env["CHILK_DEMO_PEEK_EVERY"].flatMap(Double.init) }

    func hide(_ why: String) {
        pending = nil
        guard !state.hidden else { return }
        state.hide(rng: &rng)
        if let every = demoPeekEvery { state.postpone(every) }
        endLook(goHome: true)                                       // a peek in progress does not stay half out
        sim.hidden = true
        save()
        log("hidden (\(why))")
    }

    /// `notify: false` — the caller shows the request itself (a roll).
    func show(_ why: String, notify: Bool = true) {
        pending = nil
        guard state.hidden else { return }
        state.show()
        endLook(goHome: true)                                       // out of a peek: docked, not stuck at the lurk line
        sim.hidden = false
        save()
        log("shown (\(why))")
        if notify { onShown() }
    }

    /// `chilk_hide` from a conversation or a chat turn: it happens when that closes (he is out until then anyway).
    func request(_ hidden: Bool) -> JSON {
        let changed = hidden != state.hidden
        pending = changed ? hidden : nil
        log("hide requested by Codex: \(hidden ? "hide" : "show")\(changed ? "" : " (already)")")
        // By voice he hides at once, without an answer (acceptance 2026-10-06): the conversation ends, its end applies it.
        if hidden, changed { DispatchQueue.main.async { [weak self] in self?.onHideAsked() } }
        return ["hidden": .bool(hidden), "changed": .bool(changed)]
    }

    /// The conversation or the chat turn closed (the caller resumes the balance right after).
    func applyPending() {
        guard let p = pending else { return }
        pending = nil
        if p { hide("asked") } else { show("asked", notify: false) }
    }

    /// Each second of the balance loop (decision 18): the peek clock runs while the user works.
    func tick(_ s: Signals) {
        ticks += 1
        let working = !s.locked && s.idle < 60
        let quiet = s.inCall || s.fullscreen || s.video
        if state.tick(seconds: 1, working: working, quiet: quiet, rng: &rng) {
            if let every = demoPeekEvery { state.postpone(every) }
            if canPeek(), !lurking {
                look(seconds: 2, why: "peek")
            } else {
                state.postpone(60)
                log("peek postponed: Chilk busy")
            }
        }
        if ticks % 60 == 0, state.hidden { save() }
    }

    /// He leans out from behind the edge for `seconds`: a peek (looks at the cursor) or «not staying» (the need's
    /// pantomime). Then home again unless something else took him out meanwhile.
    func look(seconds: Double, why: String) {
        guard state.hidden else { return }
        lurking = true
        sim.standOut = .lurk
        log("lurk: \(why)")
        lookTimer?.invalidate()
        lookTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endLook(goHome: true) }
        }
    }

    /// Slice 10 (Б5, decision 11): he leans out with a request's bubble and stays so until it is answered or gone.
    private(set) var holding = false
    func hold(why: String) {
        guard state.hidden else { return }
        lookTimer?.invalidate()
        lookTimer = nil
        lurking = true
        holding = true
        sim.standOut = .lurk
        log("lurk: \(why) — held until answered")
    }

    /// The request held out was answered or went: back behind the edge (unless something else took him out).
    func release(_ why: String) {
        guard holding else { return }
        holding = false
        endLook(goHome: true)
        log("lurk released (\(why))")
    }

    private func endLook(goHome: Bool = false) {
        lookTimer?.invalidate()
        lookTimer = nil
        holding = false
        if lurking, goHome, sim.standOut == .lurk { sim.standOut = .docked }
        lurking = false
    }

    /// A click on him while he looks out: he comes out for good.
    func clicked() -> Bool {
        guard state.hidden, lurking, sim.standOut == .lurk else { return false }
        sim.standOut = .docked
        show("clicked")
        return true
    }

    /// Decision 19: a request starts or climbs while he is hidden — does he stay out? (`CHILK_DEMO_STAY_ROLL` = the roll.)
    func rollStays(stage: Int) -> Bool {
        let roll = env["CHILK_DEMO_STAY_ROLL"].flatMap(Double.init) ?? rng.next()
        let stays = Hideout.stays(stage: stage, roll: roll)
        log(String(format: "hidden: stage %d, roll %.2f vs %.2f → %@", stage, roll, Hideout.chance(stage: stage),
                   stays ? "comes out" : "stays hidden"))
        return stays
    }

    func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: file, options: .atomic) }
    }
}
