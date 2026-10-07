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
    private static let waitLimit: TimeInterval = 30

    /// The notebook holds Chilk: he is not at the edge.
    private(set) var holdsChilk = false
    var isOpen: Bool { window != nil }
    var log: (String) -> Void = { _ in }
    /// Chilk is free at the edge (the tray's rule): nothing else holds him.
    var isFree: () -> Bool = { true }
    /// Acceptance: called on every phase change (snapshots, scripted moves).
    var onPhase: (TicTacToeModel.Phase) -> Void = { _ in }

    init(edge: EdgeController, balance: BalanceController, seed: UInt64? = nil) {
        self.edge = edge
        self.balance = balance
        rng = SeededRandom(seed: seed ?? UInt64(Date().timeIntervalSince1970 * 1000))
        super.init()
        hero.fatigue = { [weak edge] in edge?.sim.fatigue ?? 0 }
        hero.eyeStrain = { [weak edge] in edge?.sim.eyeStrain ?? 0 }
        model.start = { [weak self] n in self?.begin(length: n) }
        model.tap = { [weak self] i in self?.tap(i) }
        model.again = { [weak self] in self?.again() }
        model.close = { [weak self] in self?.close() }
    }

    /// Opens the notebook (from the popover, by voice or chat). `length` skips the first sheet. Returns the line Chilk
    /// says instead when a game is not possible now (decision 26); `nil` = opened.
    @discardableResult
    func open(_ kind: GameKind = .ticTacToe, length: Int? = nil) -> String? {
        if let refusal = balance.gameRefusal(kind) {
            log("game \(kind.rawValue) refused: \(refusal.rawValue)")
            return GameLines.refusal(refusal)
        }
        if let window {                                    // already open: just bring it up
            if let length, model.phase == .setup || model.phase == .matchOver { begin(length: length) }
            window.makeKeyAndOrderFront(nil)
            return nil
        }
        guard isFree() else {
            // A conversation that asked for the game, a bubble or his entrance: open as soon as he is free (≤ 15 s).
            let first = waitStarted == nil
            waitStarted = waitStarted ?? Date()
            if Date().timeIntervalSince(waitStarted!) > Self.waitLimit {
                waitStarted = nil
                log("game \(kind.rawValue): Chilk stayed busy — not opened")
                return GameLines.busy
            }
            if first { log("game \(kind.rawValue): waits until Chilk is free") }
            waiting?.invalidate()
            waiting = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.waiting = nil
                    _ = self?.open(kind, length: length)
                }
            }
            return nil
        }
        waitStarted = nil
        history.played(kind, at: Date())
        try? history.save(to: Self.historyFile)
        holdsChilk = true
        edge.sim.standOut = .away                          // he ducks behind the screen edge …
        model.match = GameMatch()
        model.board = TicTacToe()
        model.strike = nil
        if let length { begin(length: length) } else { setPhase(.setup) }
        show()
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
        begin(length: model.match.length)
    }

    private func newGame() {
        model.board = TicTacToe()
        model.strike = nil
        model.seed = UInt64(rng.next() * 1_000_000_000)
        model.gameIndex += 1
        model.headline = GameLines.score(you: model.match.you, chilk: model.match.chilk, game: model.match.game,
                                         of: model.match.length)
        if model.match.youStart { setPhase(.yourMove) } else { chilkTurn() }
    }

    private func tap(_ cell: Int) {
        guard model.phase == .yourMove, model.board.play(cell, .x) else { return }
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
            }
        } else {
            setPhase(.gameOver, status: Self.gameLine(result))
            after(0.5) { [weak self] in self?.hero.sim.react(result.reaction) }
            after(2.8) { [weak self] in self?.newGame() }
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

    private func show() {
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
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        cancelTimers()
        hero.stop()
        window = nil
        guard holdsChilk else { return }
        holdsChilk = false
        if edge.sim.standOut == .away {
            edge.sim.standOut = .docked                    // back at his place
            balance.resume()                               // what waited while he played
        }
        log("game closed — Chilk is back at the edge")
    }

    /// Acceptance: the notebook as the window server shows it.
    func snapshot(to url: URL) {
        guard let window else { return }
        WindowSnapshot.write(window, to: url)
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
                self.after(0.9) {
                    guard self.model.phase == .yourMove else { return }
                    let free = self.model.board.empty
                    while let next = script.first, !free.contains(next) { script.removeFirst() }
                    let cell = script.isEmpty ? free.first! : script.removeFirst()
                    self.log("game demo: you play \(cell)")
                    self.tap(cell)
                }
            case .matchOver:
                self.after(4) { self.close() }
            default: break
            }
        }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.open(.ticTacToe, length: length) }
        }
    }
}
