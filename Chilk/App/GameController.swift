import AppKit
import ChilkBrain
import ChilkCore
import SwiftUI

/// Slice 7a (SPEC decisions 26, 29): the notebook with tic-tac-toe. Chilk leaves the screen edge for it the way he goes
/// into the popover (one owner: the edge Chilk is `.away` while the notebook holds him) and comes back when it closes.
@MainActor
final class GameController: NSObject, NSWindowDelegate {
    let model = TicTacToeModel()
    /// Chilk beside the board, bigger than on the hero card.
    let hero = HeroView(scale: 0.95)
    private let edge: EdgeController
    private let balance: BalanceController
    private var window: NSWindow?
    private var rng: SeededRandom
    private var timers: [Timer] = []
    private var history = GameHistory.load(from: GameController.historyFile)
    private static var historyFile: URL { AppState.directory.appendingPathComponent("games.json") }

    private var waiting: Timer?
    private var waitStarted: Date?
    /// A voice conversation keeps him until its follow-up window ends.
    private static let waitLimit: TimeInterval = 60

    /// Slice 7b: basketball on the screen (Chilk plays at his edge).
    let court: CourtController
    /// The notebook holds Chilk: he is not at the edge.
    private var notebookHolds = false
    /// A game holds Chilk (the notebook, or basketball at his edge): nothing else may use him.
    var holdsChilk: Bool { notebookHolds || court.holdsChilk }
    var isOpen: Bool { window != nil || court.isOpen }
    var log: (String) -> Void = { _ in }
    /// Chilk is free at the edge: nothing else holds him (a stage 1–2 request bubble does not — it comes along).
    var isFree: () -> Bool = { true }
    /// What holds him now (for the log while the notebook waits); empty = free.
    var whyBusy: () -> [String] = { [] }
    /// Acceptance: called on every phase change (snapshots, scripted moves) and when a request card appears.
    var onPhase: (TicTacToeModel.Phase) -> Void = { _ in }
    var onCard: () -> Void = {}
    /// A call or a due notice (plan, decision 8): he ducks out of the notebook, talks at the edge, then comes back.
    var conversationActive: () -> Bool = { false }

    // Decision 32: games and breaks.
    private var lent = false
    private var watchTimer: Timer?
    private var requestSince: Date?
    /// Between games (or after the match): a waiting request is shown as a card before the next game.
    private var waitingForNext = false
    private var cardReactions: [Reaction] = []
    private var afterClose: (() -> Void)?
    /// A game paused for a break (stage 3, «измотан», «Иду»): «Доиграем?» after the rest, until the end of the day.
    struct SavedGame {
        let kind: GameKind
        let match: GameMatch
        let board: TicTacToe?
        let youToMove: Bool
        let at: Date
        /// The engine clock of the latest counted rest at the pause: «Доиграем?» waits for a newer one.
        let restMark: TimeInterval
    }
    private var saved: SavedGame?
    private var offerTimer: Timer?
    private var offerNotBefore: Date?

    init(edge: EdgeController, balance: BalanceController, seed: UInt64? = nil) {
        self.edge = edge
        self.balance = balance
        let seed = seed ?? UInt64(Date().timeIntervalSince1970 * 1000)
        rng = SeededRandom(seed: seed)
        court = CourtController(edge: edge, balance: balance, seed: seed)
        super.init()
        court.onPause = { [weak self] match in
            guard let self else { return }
            self.saved = SavedGame(kind: .basketball, match: match, board: nil, youToMove: true, at: Date(),
                                   restMark: self.balance.lastRestMark)
            self.offerNotBefore = nil
        }
        court.onClosed = { [weak self] in if self?.saved != nil { self?.startOfferWatch() } }
        hero.fatigue = { [weak edge] in edge?.sim.fatigue ?? 0 }
        hero.eyeStrain = { [weak edge] in edge?.sim.eyeStrain ?? 0 }
        model.start = { [weak self] n in self?.begin(length: n) }
        model.tap = { [weak self] i in self?.tap(i) }
        model.again = { [weak self] in self?.again() }
        model.close = { [weak self] in self?.close() }
        model.answer = { [weak self] i in self?.answer(i) }
    }

    /// Opens the notebook (from the popover, by voice or chat). `length` skips the first sheet. Returns the line Chilk
    /// says instead when a game is not possible now (decision 26); `nil` = opened.
    @discardableResult
    func open(_ kind: GameKind = .ticTacToe, length: Int? = nil, restoring: SavedGame? = nil) -> String? {
        if let refusal = balance.gameRefusal(kind) {
            waitStarted = nil
            log("game \(kind.rawValue) refused: \(refusal.rawValue)")
            return GameLines.refusal(refusal)
        }
        balance.yieldToGame()                              // a request bubble (stage 1–2) moves into the game
        if kind == .ticTacToe, let window {                // already open: just bring it up
            if let length, model.phase == .setup || model.phase == .matchOver { begin(length: length) }
            window.makeKeyAndOrderFront(nil)
            return nil
        }
        if kind == .basketball, court.isOpen { return nil }
        if isOpen {                                        // another game is on: it ends, he comes back, then this one
            log("game \(kind.rawValue): the other game closes first")
            if window != nil { close() } else { court.close() }
        }
        guard isFree() else {
            // The conversation that asked for the game, a due notice or his entrance: open once he is free (≤ 60 s).
            let first = waitStarted == nil
            waitStarted = waitStarted ?? Date()
            if Date().timeIntervalSince(waitStarted!) > Self.waitLimit {
                waitStarted = nil
                log("game \(kind.rawValue): Chilk stayed busy — not opened")
                return GameLines.busy
            }
            if first { log("game \(kind.rawValue): waits until Chilk is free (\(whyBusy().joined(separator: ", ")))") }
            waiting?.invalidate()
            waiting = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.waiting = nil
                    _ = self?.open(kind, length: length, restoring: restoring)
                }
            }
            return nil
        }
        let deferred = waitStarted != nil
        waitStarted = nil
        saved = nil                                        // a new game (or the resumed one) replaces a paused game
        stopOffer()
        history.played(kind, at: Date())
        try? history.save(to: Self.historyFile)
        if kind == .basketball {                           // on the screen: he stays at his edge and throws
            court.open(length: length, restoring: restoring?.match, activate: !deferred)
            return nil
        }
        notebookHolds = true
        edge.sim.standOut = .away                          // he ducks behind the screen edge …
        model.match = GameMatch()
        model.board = TicTacToe()
        model.strike = nil
        model.card = nil
        waitingForNext = false
        requestSince = nil
        lent = false
        if let restoring { restore(restoring) } else if let length { begin(length: length) } else { setPhase(.setup) }
        show(activate: !deferred)
        hero.start(enterAfter: 0.45)                       // … and comes out from behind the notebook's edge
        log("game \(kind.rawValue) opened\(length.map { " length \($0)" } ?? "")")
        return nil
    }

    func close() {
        window?.close()                                    // → windowWillClose
    }

    /// The games ready now, for the popover's «Игры» page; and why not now (`nil` = can play).
    var ready: [GameKind] { GameKind.ready }
    func refusalLine(_ kind: GameKind = .ticTacToe) -> String? { balance.gameRefusal(kind).map(GameLines.refusal) }

    /// `chilk_game` (voice or chat): `nil` = Chilk picks the game not played for longest. The notebook opens when he is
    /// free (the conversation closes); refusals carry the codes Codex explains.
    func request(_ kind: GameKind?, length: Int?) -> CodexToolResult {
        let chosen = kind ?? GameChooser.pick(ready: GameKind.ready, lastPlayed: history.lastPlayed)
        if let r = balance.gameRefusal(chosen) {
            log("game \(chosen.rawValue) refused: \(r.rawValue)")
            return .failure("\(r.rawValue): " + (r == .notReady
                ? "not here yet; ready: " + GameKind.ready.map(\.rawValue).joined(separator: ", ")
                : GameLines.refusal(r)))
        }
        open(chosen, length: length)
        return .ok(["game": .string(chosen.rawValue), "name": .string(GameLines.name(chosen)),
                    "length": .number(Double(length ?? 0))])
    }

    // MARK: The match

    private func begin(length: Int) {
        cancelTimers()
        model.length = min(GameMatch.lengths.upperBound, max(GameMatch.lengths.lowerBound, length))
        model.match = GameMatch(length: model.length)
        log("game: match of \(model.match.length)")
        newGame()
    }

    private func again() {
        guard model.card == nil else { return }
        waitingForNext = false
        begin(length: model.match.length)
    }

    private func restore(_ s: SavedGame) {
        cancelTimers()
        model.match = s.match
        model.length = s.match.length
        log("game: resumed at \(s.match.you):\(s.match.chilk)")
        guard let board = s.board else { return newGame() }
        startBoard(board)
        if s.youToMove { setPhase(.yourMove) } else { chilkTurn() }
    }

    private func newGame() {
        startBoard(TicTacToe())
        if model.match.youStart { setPhase(.yourMove) } else { chilkTurn() }
    }

    /// A board on a fresh sheet: the pencil's wobble and the marks drawn anew, the score up top.
    private func startBoard(_ board: TicTacToe) {
        model.board = board
        model.strike = nil
        model.seed = UInt64(rng.next() * 1_000_000_000)
        model.gameIndex += 1
        model.headline = GameLines.score(you: model.match.you, chilk: model.match.chilk, game: model.match.game,
                                         of: model.match.length)
    }

    private func tap(_ cell: Int) {
        guard model.phase == .yourMove, !lent, model.board.play(cell, .x) else { return }
        if let outcome = model.board.outcome { finish(outcome) } else { chilkTurn() }
    }

    private func chilkTurn() {
        setPhase(.chilkThinks)
        let think = TicTacToeAI.thinkTime(rng: &rng)
        hero.sim.perform(.think(seconds: think))
        after(think) { [weak self] in
            guard let self, self.model.phase == .chilkThinks else { return }
            let move = TicTacToeAI.move(self.model.board, for: .o, rng: &self.rng)
            self.model.board.play(move.cell, .o)
            if move.yawned { self.log("game: Chilk yawned (cell \(move.cell))") }
            if let outcome = self.model.board.outcome { self.finish(outcome) } else { self.setPhase(.yourMove) }
        }
    }

    private func finish(_ outcome: TicOutcome) {
        let result: GameResult
        switch outcome {
        case .won(let mark, let line):
            result = mark == .x ? .you : .chilk
            model.strike = line
        case .draw:
            result = .draw
        }
        model.match.record(result)
        model.headline = GameLines.score(you: model.match.you, chilk: model.match.chilk, game: model.match.played,
                                         of: model.match.length)
        log("game: \(result.rawValue) — \(model.match.you):\(model.match.chilk), game \(model.match.played) of \(model.match.length)")
        if model.match.isOver, let total = model.match.result {
            // The last game: one reaction, for the whole match.
            setPhase(.gameOver, status: Self.gameLine(result))
            after(0.9) { [weak self] in
                guard let self else { return }
                self.model.headline = GameLines.finalScore(you: self.model.match.you, chilk: self.model.match.chilk)
                self.setPhase(.matchOver, status: Self.matchLine(total))
                self.hero.sim.react(total.reaction)
                self.log("game: match over — \(total.rawValue)")
                self.waitingForNext = true                 // «Ещё матч» waits for a request card too
                self.watch()
            }
        } else {
            setPhase(.gameOver, status: Self.gameLine(result))
            after(0.5) { [weak self] in self?.hero.sim.react(result.reaction) }
            after(2.8) { [weak self] in
                self?.waitingForNext = true
                self?.watch()                              // a waiting request comes first (decision 32)
            }
        }
    }

    private static func gameLine(_ r: GameResult) -> String {
        switch r {
        case .you: GameLines.youWonGame
        case .chilk: GameLines.chilkWonGame
        case .draw: GameLines.drawGame
        }
    }

    private static func matchLine(_ r: GameResult) -> String {
        switch r {
        case .you: GameLines.youWonMatch
        case .chilk: GameLines.chilkWonMatch
        case .draw: GameLines.drawMatch
        }
    }

    private func setPhase(_ phase: TicTacToeModel.Phase, status: String? = nil) {
        model.phase = phase
        switch phase {
        case .setup:
            model.headline = GameLines.ticTacToe
            model.status = GameLines.howMany
        case .yourMove: model.status = GameLines.yourMove
        case .chilkThinks: model.status = GameLines.chilkThinks
        case .gameOver, .matchOver: model.status = status ?? ""
        }
        onPhase(phase)
    }

    // MARK: The window

    /// `activate`: a click in the popover or a chat answer — the notebook takes the keyboard. Opened later (after a
    /// voice conversation) it only comes to the front and does not take the keys from what the user types into.
    private func show(activate: Bool) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: NotebookView.size),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = GameLines.ticTacToe
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.delegate = self
        w.contentView = NSHostingView(rootView: NotebookView(model: model, hero: hero))
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            w.setFrameOrigin(NSPoint(x: f.midX - NotebookView.size.width / 2, y: f.midY - NotebookView.size.height / 2))
        }
        window = w
        if activate {
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
        } else {
            w.orderFrontRegardless()
        }
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watch() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        cancelTimers()
        watchTimer?.invalidate()
        watchTimer = nil
        hero.stop()
        window = nil
        model.card = nil
        model.note = nil
        let then = afterClose
        afterClose = nil
        if notebookHolds {
            notebookHolds = false
            if !lent, edge.sim.standOut == .away {
                edge.sim.standOut = .docked                // back at his place (hidden: behind the edge again)
                // «Иду» from a note starts the promised rest itself; otherwise what waited while he played.
                if let then { then() } else { balance.resume() }
            } else {
                then?()                                    // a call has him at the edge: it resumes the rest itself
            }
            log("game closed — Chilk is back at the edge")
        } else {
            then?()
        }
        lent = false
        if saved != nil { startOfferWatch() }
    }

    /// Acceptance: the notebook as the window server shows it.
    func snapshot(to url: URL) {
        guard let window else { return }
        WindowSnapshot.write(window, to: url)
    }

    // MARK: Games and breaks (decision 32)

    /// Twice a second while the notebook is open: a call takes Chilk to the edge for a while; a request waits for the
    /// end of the game (≤ 10 min) and then shows as a note; stage 3 or «измотан» pause the game.
    private func watch() {
        guard window != nil else { return }
        // A call or a due notice (plan, decision 8): he talks at the edge for a while. The game still owns him, so no
        // request bubble or leap takes the edge meanwhile, and he comes back as soon as the talk is over.
        if conversationActive() {
            if !lent {
                lent = true
                hero.sim.standOut = .away
                log("game: Chilk went to the edge for a call")
            }
            return
        }
        if lent {
            guard !edge.sim.isTalking else { return }
            lent = false
            edge.sim.standOut = .away
            hero.sim.standOut = .out
            log("game: Chilk is back in the notebook")
        }
        let request = balance.gameRequest
        if request == nil { requestSince = nil } else if requestSince == nil { requestSince = Date() }
        // The first sheet counts as «between games»: a waiting request comes before the first game too.
        switch GameBreakPolicy.decide(stage: request?.stage, need: request?.need, slumped: balance.slumpedNow,
                                      silent: balance.mode == .silent,
                                      betweenGames: waitingForNext || model.phase == .setup,
                                      waiting: requestSince.map { Date().timeIntervalSince($0) } ?? 0) {
        case .pause:
            pauseForBreak()
            return
        case .card:
            if model.card == nil, let request { showCard(request) }
        case .keepPlaying:
            if model.card != nil, request == nil {         // answered elsewhere (by voice, at the edge)
                model.card = nil
                cardReactions = []
            }
        }
        if waitingForNext, model.card == nil, model.phase == .gameOver, !model.match.isOver {
            waitingForNext = false
            newGame()
        }
    }

    private func showCard(_ request: GameRequest) {
        cardReactions = request.buttons
        model.card = GameCard(text: GameLines.firstThenRematch(request.need),
                              buttons: request.buttons.map { Lines.button($0, for: request.need) })
        log("game: card \(request.need.rawValue) stage \(request.stage)"
            + (waitingForNext || model.phase == .setup ? " between games" : " mid-game"))
        onCard()
    }

    private func answer(_ index: Int) {
        guard index < cardReactions.count else { return }
        let r = cardReactions[index]
        model.card = nil
        cardReactions = []
        requestSince = nil
        if r == .going {                                   // «Иду»: the rest starts at the edge; the game waits
            pauseForBreak { [weak balance] in balance?.answerAtEdge(.going) }
            return
        }
        // Counted (or not) by the engine right here; its reply («Ты же только что пил») is written on the sheet.
        if let line = balance.answerFromGame(r) { flash(line) }
        watch()
    }

    private func flash(_ line: String) {
        model.note = line
        after(3) { [weak self] in if self?.model.note == line { self?.model.note = nil } }
    }

    /// Saves the game (the match and the board, or just the match between games) and closes the notebook; Chilk goes
    /// to the edge, where the request shows (dimming, «Помоги мне…», the promised rest).
    private func pauseForBreak(then: (() -> Void)? = nil) {
        guard window != nil else { return }
        let mark = balance.lastRestMark
        switch model.phase {
        case .yourMove, .chilkThinks:
            saved = SavedGame(kind: .ticTacToe, match: model.match, board: model.board, youToMove: model.phase == .yourMove,
                              at: Date(), restMark: mark)
        case .gameOver where !model.match.isOver:
            saved = SavedGame(kind: .ticTacToe, match: model.match, board: nil, youToMove: true, at: Date(), restMark: mark)
        default:
            saved = nil                                    // the first sheet or a finished match: nothing to resume
        }
        offerNotBefore = nil
        log("game paused for a break" + (saved.map { " at \($0.match.you):\($0.match.chilk)" } ?? ""))
        afterClose = then
        close()
    }

    private func startOfferWatch() {
        offerTimer?.invalidate()
        offerTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.offerTick() }
        }
    }

    private func stopOffer() {
        offerTimer?.invalidate()
        offerTimer = nil
    }

    /// «Доиграем?» once a rest was counted after the pause, with nothing on screen and Chilk free at the edge; kept until
    /// the day ends. Unanswered for 30 s, the bubble goes and comes back in 10 min (the popover offers it too).
    private func offerTick() {
        guard let s = saved, !isOpen else { return stopOffer() }
        guard Calendar.current.isDate(s.at, inSameDayAs: Date()) else {
            saved = nil
            stopOffer()
            log("game: the paused game expired")
            return
        }
        if let wait = offerNotBefore, Date() < wait { return }
        guard balance.lastRestMark > s.restMark, balance.gameRequest == nil, !balance.slumpedNow, isFree() else { return }
        let shown = balance.offer(GameLines.resume(you: s.match.you, chilk: s.match.chilk), buttons: [
            (GameLines.resumeYes, { [weak self] in self?.resumeSaved() }),
            (GameLines.resumeLater, { [weak self] in
                self?.saved = nil
                self?.log("game: «Доиграем?» — later")
            }),
        ])
        guard shown else { return }
        stopOffer()
        log("game: «Доиграем?» offered")
        Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.saved != nil, !self.isOpen else { return }
                if self.balance.withdrawOffer() { self.log("game: «Доиграем?» unanswered — later") }
                self.offerNotBefore = Date().addingTimeInterval(600)
                self.startOfferWatch()
            }
        }
    }

    private func resumeSaved() {
        guard let s = saved else { return }
        if let line = open(s.kind, restoring: s) {        // `saved` is cleared only once the game really opens
            log("game: could not resume — \(line)")
            offerNotBefore = Date().addingTimeInterval(600)
            startOfferWatch()
        }
    }

    /// The popover's games page resumes a paused game too (in any mode, Тишина included).
    var savedScore: (kind: GameKind, score: String)? {
        saved.map { ($0.kind, GameLines.finalScore(you: $0.match.you, chilk: $0.match.chilk)) }
    }

    func playFromPopover(_ kind: GameKind) -> String? {
        if let s = saved, s.kind == kind { return open(kind, restoring: s) }
        return open(kind)
    }

    /// A bubble button at the edge: basketball's question, its request or «продолжаем?» — `true` = taken.
    func pressedButton(_ i: Int) -> Bool { court.pressedButton(i) }

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
}

// MARK: - Acceptance hook

extension GameController {
    /// CHILK_DEMO_GAME="<length>:<cell>,<cell>,…" — opens the notebook 3 s after launch with that match length and
    /// plays your moves from the list (a taken cell → the next free one); CHILK_DEMO_GAME_SNAPSHOT=/dir writes the
    /// notebook after every phase change; the notebook closes 4 s after the match ends.
    func demo(_ spec: String, snapshots: String?) {
        let parts = spec.split(separator: ":")
        let length = parts.first.flatMap { Int($0) } ?? 1
        var script = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Int($0) } : []
        var shot = 0
        onPhase = { [weak self] phase in
            guard let self else { return }
            if let dir = snapshots {
                shot += 1
                let n = shot
                self.after(0.75) { self.snapshot(to: URL(fileURLWithPath: dir).appending(path: String(format: "game-%02d.png", n))) }
            }
            switch phase {
            case .yourMove:
                @MainActor func attempt() {
                    self.after(0.9) {
                        guard self.model.phase == .yourMove else { return }
                        if self.lent { return attempt() }      // he is at the edge for a call: wait for him
                        let free = self.model.board.empty
                        while let next = script.first, !free.contains(next) { script.removeFirst() }
                        let cell = script.isEmpty ? free.first! : script.removeFirst()
                        self.log("game demo: you play \(cell)")
                        self.tap(cell)
                    }
                }
                attempt()
            case .matchOver:
                self.after(4) { self.close() }
            default: break
            }
        }
        // A request card: snapshot it, then press its first button («Попил» / «Сделал» / «Иду»).
        onCard = { [weak self] in
            guard let self else { return }
            if let dir = snapshots {
                shot += 1
                let n = shot
                self.after(0.6) { self.snapshot(to: URL(fileURLWithPath: dir).appending(path: String(format: "game-%02d-card.png", n))) }
            }
            self.after(1.5) {
                self.log("game demo: card button 0")
                self.answer(0)
            }
        }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.open(.ticTacToe, length: length) }
        }
    }
}

extension GameController {
    /// CHILK_DEMO_COURT="<length>:<h|m…>" — basketball 3 s after launch with that many throws; each «Попаду?» is
    /// answered from the list (h = «Попадёт», m = «Мимо») 1.2 s after it shows; a request bubble and «продолжаем?»
    /// get their first button; CHILK_DEMO_COURT_DRAG="dx,dy" drags the hoop at the first «Попаду?»;
    /// CHILK_DEMO_GAME_SNAPSHOT=/dir writes the hoop and the sky at every phase. Closes 5 s after the match.
    func demoCourt(_ spec: String, snapshots: String?) {
        let parts = spec.split(separator: ":")
        let length = parts.first.flatMap { Int($0) } ?? 3
        var script = Array(parts.count > 1 ? String(parts[1]) : "")
        var shot = 0
        var drag = ProcessInfo.processInfo.environment["CHILK_DEMO_COURT_DRAG"]?.split(separator: ",").compactMap { Double($0) }
        if drag?.count != 2 { drag = nil }
        func snap(_ name: String) {
            guard let dir = snapshots else { return }
            shot += 1
            court.snapshot(to: URL(fileURLWithPath: dir), name: String(format: "court-%02d-%@", shot, name))
        }
        court.onPhase = { [weak self] phase in
            guard let self else { return }
            switch phase {
            case .throwing:
                Timer.scheduledTimer(withTimeInterval: 1.1, repeats: false) { _ in MainActor.assumeIsolated { snap("flight") } }
            case .result:
                Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in MainActor.assumeIsolated { snap("result") } }
            case .asking where drag != nil:
                let d = drag!
                drag = nil
                self.court.demoDrag(CGSize(width: d[0], height: d[1]))
            case .matchOver:
                Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { _ in MainActor.assumeIsolated { snap("finale") } }
                Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.court.close() }
                }
            default: break
            }
        }
        var seen: (kind: String, since: Date)?
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.court.isOpen else { return }
                guard let kind = self.court.waitingBubble else { seen = nil; return }
                if seen?.kind != kind { seen = (kind, Date()); return }
                guard Date().timeIntervalSince(seen!.since) >= 1.2 else { return }
                seen = nil
                var press = 0
                if kind == "question" {
                    let c = script.isEmpty ? "h" : script.removeFirst()
                    press = c == "m" ? 1 : 0
                    snap("ask")
                } else {
                    snap(kind)
                }
                self.log("court demo: \(kind) button \(press)")
                _ = self.court.demoPress(press)
            }
        }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                _ = self.open(.basketball, length: length > 0 ? length : nil)   // 0: the scoreboard's length choice
            }
        }
    }
}
