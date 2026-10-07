import AppKit
import ChilkCore
import ChilkRender
import Observation
import SwiftUI

/// What the scoreboard under the hoop shows (slice 7b).
@MainActor
@Observable
final class CourtModel {
    enum Phase: Equatable { case setup, asking, throwing, result, request, matchOver, away }

    var phase = Phase.setup
    var match = GameMatch()
    var length = GameMatch.defaultLength
    var headline = GameLines.name(.basketball)
    var status = ""
    /// The net swings after a basket (0…1, 1 = still).
    var swing = 1.0
    /// −1: Chilk stands to the left of the hoop, +1: to the right (the rim sticks out towards him).
    var facing = 1.0

    var start: (Int) -> Void = { _ in }
    var again: () -> Void = {}
    var close: () -> Void = {}
    var touched: () -> Void = {}
    /// The hoop was dragged to a new place (screen delta of the window's origin).
    var drag: (CGSize) -> Void = { _ in }
    var dragEnded: () -> Void = {}
}

/// Slice 7b (SPEC decisions 27–28, 32): basketball «Попадёт — не попадёт» on the screen. Chilk stays at his edge and
/// throws; the hoop with its scoreboard is a small window at the other side of the screen (dragged by the backboard,
/// never nearer than a third of the screen width); the ball's flight and the fireworks are drawn in a click-through
/// window that is on screen only while something flies. Owned by `GameController`, which saves a paused match.
@MainActor
final class CourtController: NSObject, NSWindowDelegate {
    let model = CourtModel()
    private let edge: EdgeController
    private let balance: BalanceController
    private var rng: SeededRandom
    private var panel: NSPanel?
    private let sky = CourtSky()
    private var timers: [Timer] = []
    private var watchTimer: Timer?
    private var lastTouch = Date()
    /// Decision 28: it closes itself after 2 min without a touch (CHILK_DEMO_COURT_IDLE=<s> for acceptance).
    private static let idleLimit: TimeInterval =
        ProcessInfo.processInfo.environment["CHILK_DEMO_COURT_IDLE"].flatMap(Double.init) ?? 120

    /// The game holds Chilk: he plays at his edge and nothing else may use him.
    private(set) var holdsChilk = false
    var isOpen: Bool { panel != nil }
    var log: (String) -> Void = { _ in }
    /// A conversation (hotkey, wake word) or a due notice: the question waits, he talks, then asks again.
    var conversationActive: () -> Bool = { false }
    /// The user's call (decision 32): the hoop goes with a «тсс»; full screen: it goes silently.
    var inCall: () -> Bool = { false }
    var fullScreen: () -> Bool = { false }
    /// A stage 3 / «измотан» / «Иду» pause: the match is saved by the game controller («Доиграем?» after the rest).
    var onPause: (GameMatch) -> Void = { _ in }
    /// The court closed (Chilk is back at his place).
    var onClosed: () -> Void = {}
    /// Acceptance: every phase change; the bubble buttons pressed by the demo.
    var onPhase: (CourtModel.Phase) -> Void = { _ in }

    private enum Bubble { case none, question, request([Reaction]), goOn }
    private var bubble = Bubble.none
    /// A conversation took his bubble: this one comes back once the talk is over (review 7b).
    private var stashed: Bubble?
    private var dockTimer: Timer?
    private var swingTimer: Timer?
    /// He was hidden (6d) when the game opened; «спрячься» during it ends the game.
    private var hiddenAtOpen = false
    /// Put away for a call or full screen; `phase`: where the game was.
    private var away: (call: Bool, phase: CourtModel.Phase)?
    private var afterClose: (() -> Void)?
    private var lastRound: ShotRound?

    init(edge: EdgeController, balance: BalanceController, seed: UInt64) {
        self.edge = edge
        self.balance = balance
        rng = SeededRandom(seed: seed &+ 77)
        super.init()
        model.start = { [weak self] n in self?.touch(); self?.begin(length: n) }
        model.again = { [weak self] in self?.touch(); self?.begin(length: self?.model.match.length ?? 3) }
        model.close = { [weak self] in self?.close() }
        model.touched = { [weak self] in self?.touch() }
        model.drag = { [weak self] d in self?.moveHoop(by: d) }
        model.dragEnded = { [weak self] in self?.touch(); self?.logHoop() }
    }

    // MARK: Open and close

    /// Opens the court with Chilk at his edge: `length` skips the scoreboard's length choice; `restoring` resumes a
    /// paused match. `activate`: started by a click — the scoreboard takes the keys (Esc).
    func open(length: Int?, restoring: GameMatch?, activate: Bool) {
        holdsChilk = true
        cancelTimers()
        edge.sim.clearBubble()
        edge.sim.standOut = .out
        lastTouch = Date()
        away = nil
        bubble = .none
        stashed = nil
        hiddenAtOpen = edge.sim.hidden
        model.swing = 1
        // No stale scoreboard from the last game while the first round gets ready.
        model.match = restoring ?? GameMatch(length: length ?? GameMatch.defaultLength)
        model.phase = length == nil && restoring == nil ? .setup : .result
        model.headline = GameLines.name(.basketball)
        model.status = ""
        let p = makePanel()
        panel = p
        placeHoop(p)
        if activate {
            p.makeKeyAndOrderFront(nil)
        } else {
            p.orderFrontRegardless()
        }
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watch() }
        }
        if let restoring {
            model.match = restoring
            model.length = restoring.length
            log("court: resumed at \(restoring.you):\(restoring.chilk)")
            after(0.8) { [weak self] in self?.nextRound() }
        } else if let length {
            after(0.8) { [weak self] in self?.begin(length: length) }
        } else {
            model.match = GameMatch()
            setPhase(.setup)
        }
        log(String(format: "court opened, hoop at %@, chance %.0f %%", NSStringFromPoint(rimOnScreen), chance * 100))
    }

    func close() {
        panel?.close()                                     // → windowWillClose
    }

    func windowWillClose(_ notification: Notification) {
        cancelTimers()
        watchTimer?.invalidate()
        watchTimer = nil
        dockTimer?.invalidate()
        swingTimer?.invalidate()
        sky.stop()
        panel = nil
        let then = afterClose
        afterClose = nil
        if holdsChilk {
            holdsChilk = false
            let talking = conversationActive()             // a conversation has him: it places him and its bubble
            if !talking, case .none = bubble {} else if !talking { edge.sim.clearBubble() }
            bubble = .none
            stashed = nil
            if edge.sim.act == .shoot { edge.sim.stopAct() }
            if !talking, edge.sim.standOut == .out { edge.sim.standOut = .docked }
            if let then { then() } else if !talking { balance.resume() }
            log("court closed — Chilk is back at his place")
        }
        onClosed()
    }

    /// A bubble button pressed at the edge while the court has him: `true` = it was ours.
    func pressedButton(_ i: Int) -> Bool {
        guard holdsChilk else { return false }
        switch bubble {
        case .none: return false
        case .question:
            bubble = .none
            edge.sim.clearBubble()
            touch()
            shoot(guess: i == 0 ? .hit : .miss)
        case .request(let reactions):
            bubble = .none
            edge.sim.clearBubble()
            touch()
            answer(i < reactions.count ? reactions[i] : nil)
        case .goOn:
            bubble = .none
            edge.sim.clearBubble()
            touch()
            if i == 0 { comeBack() } else { close() }
        }
        return true
    }

    // MARK: The match

    private func begin(length: Int) {
        cancelTimers()
        model.length = min(GameMatch.lengths.upperBound, max(GameMatch.lengths.lowerBound, length))
        model.match = GameMatch(length: model.length)
        log("court: match of \(model.match.length)")
        nextRound()
    }

    /// Between throws: a waiting request comes first (decision 32), then «Попаду?».
    private func nextRound() {
        guard panel != nil, away == nil else { return }
        if checkBreak(betweenThrows: true) { return }
        if conversationActive() || edge.sim.isTalking {    // he is talking: ask once he is done (watch)
            setPhase(.asking)
            return
        }
        moveHoop(by: .zero)                                // he is out now: the hoop keeps its third of the screen
        bubble = .question
        edge.sim.standOut = .out
        edge.sim.say(CourtLines.willIScore, duration: 3600, buttons: [CourtLines.hit, CourtLines.miss])
        setPhase(.asking)
    }

    private var throwPoint: CGPoint { edge.screenPoint(scene: edge.sim.scenePoint(figure: Act.releaseBall)) }

    private var rimOnScreen: CGPoint {
        guard let p = panel else { return .zero }
        let off = CourtArt.rimOffset(facing: model.facing)
        return CGPoint(x: p.frame.minX + HoopPanelView.boardBottom.x + off.x,
                       y: p.frame.maxY - HoopPanelView.boardBottom.y - off.y)
    }

    private var chance: Double {
        let a = throwPoint, b = rimOnScreen
        return Basketball.chance(distance: Double(hypot(b.x - a.x, b.y - a.y)), screenWidth: Double(edge.homeVisibleFrame.width))
    }

    private func shoot(guess: ShotGuess) {
        let p = chance
        let scored = Basketball.scores(chance: p, rng: &rng)
        let miss: ShotFlight.Miss = rng.next() < 0.5 ? .front : .back
        setPhase(.throwing)
        edge.sim.perform(.shoot)
        log(String(format: "court: you say %@, chance %.0f %% → %@", guess.rawValue, p * 100, scored ? "in" : "out"))
        after(Act.shootRelease) { [weak self] in
            guard let self else { return }
            let flight = ShotFlight(from: self.throwPoint, rim: self.rimOnScreen, rimRadius: CourtArt.rimRadius,
                                    scored: scored, miss: miss, screenWidth: Double(self.edge.homeVisibleFrame.width))
            self.sky.show(on: self.edge.homeVisibleFrame)
            self.sky.throwBall(flight)
            if scored { self.after(flight.contact) { [weak self] in self?.swingNet() } }
            self.after(flight.duration - 0.2) { [weak self] in self?.resolve(ShotRound(guess: guess, scored: scored)) }
        }
    }

    private func swingNet() {
        let start = Date()
        swingTimer?.invalidate()
        swingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let u = min(1, Date().timeIntervalSince(start) / 0.9)
                self.model.swing = u
                if u >= 1 { self.swingTimer?.invalidate() }
            }
        }
    }

    private func resolve(_ round: ShotRound) {
        lastRound = round
        model.match.record(round.result)
        let m = model.match
        model.headline = CourtLines.score(you: m.you, chilk: m.chilk, shot: m.played, of: m.length)
        model.status = round.firework ? CourtLines.guessed : CourtLines.notGuessed
        if round.firework {
            sky.fireworks(Fireworks.small(at: CGPoint(x: rimOnScreen.x, y: rimOnScreen.y + 70), rng: &rng))
        }
        edge.sim.react(round.reaction)
        log("court: \(round.scored ? "in" : "out"), \(round.result.rawValue) — \(m.you):\(m.chilk), throw \(m.played) of \(m.length)")
        setPhase(.result)
        after(2.6) { [weak self] in
            guard let self else { return }
            if self.model.match.isOver { self.finale() } else { self.nextRound() }
        }
    }

    private func finale() {
        guard let total = model.match.result else { return }
        let m = model.match
        model.headline = GameLines.finalScore(you: m.you, chilk: m.chilk)
        model.status = switch total {
        case .you: GameLines.youWonMatch
        case .chilk: GameLines.chilkWonMatch
        case .draw: GameLines.drawMatch
        }
        let f = CourtFinale(total)
        switch f {
        case .fireworksAndClap: sky.fireworks(Fireworks.big(over: edge.homeVisibleFrame, rng: &rng))
        case .highFive: edge.sim.say(CourtLines.highFive, duration: 2.2)
        case .cheer: break
        }
        edge.sim.finale(f)
        setPhase(.matchOver)
        log("court: match over — \(total.rawValue) (\(f.rawValue))")
    }

    private func setPhase(_ phase: CourtModel.Phase) {
        model.phase = phase
        switch phase {
        case .setup:
            model.headline = GameLines.name(.basketball)
            model.status = ""
        case .asking:
            let m = model.match
            model.headline = CourtLines.score(you: m.you, chilk: m.chilk, shot: m.game, of: m.length)
            model.status = CourtLines.guessIt
        default: break
        }
        onPhase(phase)
    }

    // MARK: Breaks, calls and full screen (decision 32)

    /// Twice a second: the idle limit, a call or full screen (the hoop goes), a conversation (the question waits),
    /// a request (between throws) and stage 3 / «измотан» (the match is saved).
    private func watch() {
        guard panel != nil else { return }
        if edge.sim.hidden, !hiddenAtOpen {               // «спрячься» during the game: the game ends, he hides
            log("court: hidden — the game ends")
            return close()
        }
        let call = inCall(), full = fullScreen()
        if let a = away {
            lastTouch = Date()
            // Put away for a long film or call: stage 3 / «измотан» still pause the match (stage 1–2 wait).
            if case .pause = GameBreakPolicy.decide(stage: balance.gameRequest?.stage, need: balance.gameRequest?.need,
                                                    slumped: balance.slumpedNow, silent: balance.mode == .silent,
                                                    betweenGames: false, waiting: 0) {
                return pauseForBreak()
            }
            if !call && !full && !(a.call && edge.sim.isTalking) { back(fromCall: a.call) }
            return
        }
        if call || full {
            goAway(call: call)
            return
        }
        if conversationActive() {
            lastTouch = Date()                             // talking is not idling
            if case .none = bubble {} else {               // the conversation's bubble replaced ours: it comes back after
                stashed = bubble
                bubble = .none
            }
            return
        }
        if let s = stashed, !edge.sim.isTalking {          // the talk is over: our bubble again
            stashed = nil
            edge.sim.standOut = .out
            switch s {
            case .goOn: askToGoOn()
            case .request where model.phase == .matchOver: _ = checkBreak(betweenThrows: true)
            default: nextRound()
            }
            return
        }
        if model.phase == .asking, case .none = bubble, !edge.sim.isTalking {
            nextRound()                                    // «Попаду?» once he is free to ask
            return
        }
        if [.setup, .asking, .matchOver, .request].contains(model.phase) || isAskingToGoOn {
            if Date().timeIntervalSince(lastTouch) > Self.idleLimit {
                log("court: 2 min without a touch — closed")
                endWith(CourtLines.putAway)
                return
            }
        }
        if model.phase != .throwing, model.phase != .result { _ = checkBreak(betweenThrows: true) }
    }

    private var isAskingToGoOn: Bool { if case .goOn = bubble { return true }; return false }

    /// `true`: a request or a pause took over the round.
    private func checkBreak(betweenThrows: Bool) -> Bool {
        let request = balance.gameRequest
        switch GameBreakPolicy.decide(stage: request?.stage, need: request?.need, slumped: balance.slumpedNow,
                                      silent: balance.mode == .silent, betweenGames: betweenThrows, waiting: 0) {
        case .pause:
            pauseForBreak()
            return true
        case .card:
            guard let request else { return false }
            if case .request = bubble { return true }
            bubble = .request(request.buttons)
            edge.sim.standOut = .out
            edge.sim.say(GameLines.firstThenRematch(request.need), duration: 3600,
                         buttons: request.buttons.map { Lines.button($0, for: request.need) })
            if model.phase != .matchOver { setPhase(.request) }
            log("court: request \(request.need.rawValue) stage \(request.stage) between throws")
            return true
        case .keepPlaying:
            if case .request = bubble, request == nil {    // answered elsewhere
                bubble = .none
                edge.sim.clearBubble()
                if model.phase == .request { nextRound() }
            }
            return false
        }
    }

    private func answer(_ r: Reaction?) {
        guard let r else { return nextRound() }
        if r == .going {                                   // «Иду»: the match waits, the rest starts at the edge
            return pauseForBreak { [weak balance] in balance?.answerAtEdge(.going) }
        }
        let line = balance.answerFromGame(r)
        if let line { edge.sim.say(line, duration: 2.5) }
        let wasOver = model.phase == .matchOver
        after(line == nil ? 0.3 : 2.7) { [weak self] in
            guard let self else { return }
            if wasOver || self.model.match.isOver { self.setPhase(.matchOver) } else { self.nextRound() }
        }
    }

    /// Stage 3–4, «измотан» or «Иду»: a match in progress is saved («Доиграем?» after the rest) and the court goes.
    private func pauseForBreak(then: (() -> Void)? = nil) {
        let m = model.match
        if m.played > 0 || model.phase != .setup, !m.isOver { onPause(m) }
        log("court paused for a break" + (m.isOver ? "" : " at \(m.you):\(m.chilk)"))
        afterClose = then
        close()
    }

    private func goAway(call: Bool) {
        cancelTimers()
        sky.stop()
        if edge.sim.act == .shoot { edge.sim.stopAct() }
        bubble = .none
        if call {
            let batch = Lines.batch?.shush ?? []
            let pool = CourtLines.shush + batch
            edge.sim.say(pool[rng.index(pool.count)], duration: 2.5)
            dockTimer?.invalidate()
            dockTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { if self?.away != nil { self?.edge.sim.standOut = .docked } }
            }
        } else {
            edge.sim.clearBubble()
            edge.sim.standOut = .docked
        }
        panel?.orderOut(nil)
        away = (call, [.throwing, .result, .request].contains(model.phase) ? .asking : model.phase)
        setPhase(.away)
        log("court: \(call ? "a call — «тсс», the hoop is put away" : "full screen — the hoop goes quietly")")
    }

    private func back(fromCall: Bool) {
        guard let a = away else { return }
        away = nil
        dockTimer?.invalidate()
        panel?.orderFrontRegardless()
        edge.sim.standOut = .out
        if fromCall, a.phase == .asking, !model.match.isOver {
            model.phase = .asking
            askToGoOn()
            log("court: the call is over — «Ну что, продолжаем?»")
        } else {
            log("court: back")
            if a.phase == .asking { nextRound() } else { setPhase(a.phase) }
        }
    }

    private func askToGoOn() {
        let m = model.match
        bubble = .goOn
        edge.sim.say(CourtLines.goOnAfterCall(you: m.you, chilk: m.chilk), duration: 3600,
                     buttons: [CourtLines.goOn, GameLines.enough])
    }

    /// «Давай до пяти» while the court is open on the length choice or after a match: that match starts.
    func apply(length: Int) {
        guard model.phase == .setup || model.phase == .matchOver else { return }
        touch()
        begin(length: length)
    }

    private func comeBack() {
        log("court: back")
        nextRound()
    }

    /// Says `line` at the edge and closes the court.
    private func endWith(_ line: String) {
        if case .none = bubble {} else { edge.sim.clearBubble() }
        bubble = .none
        afterClose = { [weak self] in
            self?.edge.sim.say(line, duration: 2.5)
            self?.balance.resume()
        }
        close()
    }

    private func touch() { lastTouch = Date() }

    // MARK: The hoop's window

    private func makePanel() -> NSPanel {
        let p = HoopPanel(contentRect: NSRect(origin: .zero, size: HoopPanelView.size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false                        // the match goes on while the user works in another app
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.delegate = self
        p.contentView = NSHostingView(rootView: HoopPanelView(model: model))
        return p
    }

    private func origin(forRim rim: CGPoint) -> CGPoint {
        let off = CourtArt.rimOffset(facing: model.facing)
        return CGPoint(x: rim.x - HoopPanelView.boardBottom.x - off.x,
                       y: rim.y + HoopPanelView.boardBottom.y + off.y - HoopPanelView.size.height)
    }

    private func placeHoop(_ p: NSPanel) {
        let frame = edge.homeVisibleFrame, from = throwPoint
        model.facing = from.x > frame.midX ? 1 : -1
        let rim = Basketball.defaultHoop(from: from, in: frame, margin: 90)
        p.setFrameOrigin(origin(forRim: rim))
    }

    private func moveHoop(by d: CGSize) {
        guard let p = panel else { return }
        let off = CourtArt.rimOffset(facing: model.facing)
        let rim = CGPoint(x: p.frame.minX + HoopPanelView.boardBottom.x + off.x + d.width,
                          y: p.frame.maxY - HoopPanelView.boardBottom.y - off.y + d.height)
        let clamped = Basketball.clampHoop(rim, from: throwPoint, in: edge.homeVisibleFrame, margin: 90)
        p.setFrameOrigin(origin(forRim: clamped))
    }

    private func logHoop() {
        log(String(format: "court: hoop moved to %@, chance %.0f %%", NSStringFromPoint(rimOnScreen), chance * 100))
    }

    // MARK: Timers

    private func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        let t = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { body() }
        }
        timers.append(t)
    }

    private func cancelTimers() {
        timers.forEach { $0.invalidate() }
        timers.removeAll()
    }

    /// Acceptance: the scoreboard and the sky as the window server shows them.
    func snapshot(to dir: URL, name: String) {
        if let panel { WindowSnapshot.write(panel, to: dir.appending(path: "\(name)-hoop.png")) }
        WindowSnapshot.writeScreen(edge.homeVisibleFrame, to: dir.appending(path: "\(name)-screen.png"))
    }

    /// Acceptance: which of the court's bubbles waits for a press («question», «request», «goOn»), if any.
    var waitingBubble: String? {
        switch bubble {
        case .none: nil
        case .question: "question"
        case .request: "request"
        case .goOn: "goOn"
        }
    }

    /// Acceptance: press a bubble button as the user would.
    func demoPress(_ i: Int) -> Bool { pressedButton(i) }
    func demoDrag(_ d: CGSize) { moveHoop(by: d); logHoop() }
}

/// A borderless panel that can still take the keys (Esc on «Хватит») without activating the app.
private final class HoopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - The hoop and the scoreboard

struct HoopPanelView: View {
    @Bindable var model: CourtModel

    static let size = CGSize(width: 240, height: 236)
    /// The backboard's bottom centre in the panel (y down).
    static let boardBottom = CGPoint(x: 120, y: 82)

    var body: some View {
        VStack(spacing: 6) {
            HoopCanvas(model: model)
                .frame(width: Self.size.width, height: 126)
            VStack(spacing: 6) {
                Text(model.headline).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                if !model.status.isEmpty {
                    Text(model.status).font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                }
                controls
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
            Spacer(minLength: 0)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    @ViewBuilder private var controls: some View {
        switch model.phase {
        case .setup:
            HStack(spacing: 4) {
                Text(CourtLines.throwsLabel).font(.system(size: 12))
                ForEach(Array(GameMatch.lengths), id: \.self) { n in
                    Button("\(n)") { model.length = n; model.touched() }
                        .buttonStyle(.bordered).controlSize(.mini)
                        .tint(n == model.length ? .orange : nil)
                }
            }
            HStack {
                Button(GameLines.enough) { model.close() }.keyboardShortcut(.cancelAction)
                Button(GameLines.start) { model.start(model.length) }
            }.controlSize(.small)
        case .matchOver:
            HStack {
                Button(GameLines.enough) { model.close() }.keyboardShortcut(.cancelAction)
                Button(GameLines.again) { model.again() }
            }.controlSize(.small)
        default:
            Button(GameLines.enough) { model.close() }.keyboardShortcut(.cancelAction).controlSize(.small)
        }
    }
}

/// The backboard, the rim and the net, drawn with the shared art; dragging it moves the hoop.
private struct HoopCanvas: NSViewRepresentable {
    let model: CourtModel

    func makeNSView(context: Context) -> HoopNSView {
        let v = HoopNSView()
        v.model = model
        return v
    }

    func updateNSView(_ v: HoopNSView, context: Context) {
        v.swing = model.swing
        v.facing = model.facing
        v.needsDisplay = true
    }
}

final class HoopNSView: NSView {
    var model: CourtModel?
    var swing = 1.0
    var facing = 1.0
    private var last: NSPoint?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: HoopPanelView.boardBottom.x, y: HoopPanelView.boardBottom.y)
        CourtArt.hoop(ctx, facing: facing, swing: swing, outline: Palette.peach.outline.cgColor)
        ctx.restoreGState()
    }

    override func mouseDown(with event: NSEvent) { last = NSEvent.mouseLocation }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        if let last { MainActor.assumeIsolated { model?.drag(CGSize(width: now.x - last.x, height: now.y - last.y)) } }
        last = now
    }

    override func mouseUp(with event: NSEvent) {
        last = nil
        MainActor.assumeIsolated { model?.dragEnded() }
    }
}

// MARK: - The sky: the ball in flight and the fireworks

/// A click-through window over his monitor; on screen only while a ball or a firework is in the air.
@MainActor
final class CourtSky {
    private let panel: NSPanel
    private let view = SkyView()
    private var timer: Timer?
    private var flight: (ShotFlight, CFTimeInterval)?
    private var shows: [(Fireworks, CFTimeInterval)] = []

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = view
    }

    func show(on frame: CGRect) {
        if panel.frame != frame { panel.setFrame(frame, display: false) }
    }

    func throwBall(_ f: ShotFlight) {
        flight = (f, CACurrentMediaTime())
        run()
    }

    func fireworks(_ f: Fireworks) {
        shows.append((f, CACurrentMediaTime()))
        run()
    }

    func stop() {
        flight = nil
        shows = []
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    private func run() {
        panel.orderFrontRegardless()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if let (f, start) = flight, now - start > f.duration { flight = nil }
        shows.removeAll { now - $0.1 > $0.0.duration }
        guard flight != nil || !shows.isEmpty else { return stop() }
        view.origin = panel.frame.origin
        view.flight = flight.map { ($0.0, now - $0.1) }
        view.shows = shows.map { ($0.0, now - $0.1) }
        view.needsDisplay = true
    }

    func snapshot(to url: URL) {
        guard panel.isVisible, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private final class SkyView: NSView {
        var origin = CGPoint.zero
        var flight: (ShotFlight, Double)?
        var shows: [(Fireworks, Double)] = []
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let h = Double(bounds.height)
            for (show, t) in shows { CourtArt.sparks(ctx, show, at: t, origin: origin, height: h) }
            if let (f, t) = flight {
                let p = f.point(at: t)
                ctx.saveGState()
                ctx.setAlpha(f.alpha(at: t))
                ctx.translateBy(x: p.x - origin.x, y: h - (p.y - origin.y))
                CourtArt.ball(ctx, spin: -t * 9, outline: Palette.peach.outline.cgColor, lw: 1)
                ctx.restoreGState()
            }
        }
    }
}
