import Foundation

// MARK: - Which games (slice 7, SPEC decisions 26–31)

/// The games Chilk plays. A game is offered only once its sub-slice ships (`ready`).
public enum GameKind: String, CaseIterable, Codable, Sendable, CodingKeyRepresentable {
    case ticTacToe = "tictactoe", basketball, battleship, checkers

    /// Slice 7a ships tic-tac-toe, 7b basketball, 7c battleship; 7d checkers.
    public static let ready: [GameKind] = [.ticTacToe, .basketball, .battleship]
}

/// When each game was last played — «давай поиграем» without a name picks the one not played for longest.
public struct GameHistory: Codable, Equatable, Sendable {
    public var lastPlayed: [GameKind: Date] = [:]

    public init() {}

    public mutating func played(_ kind: GameKind, at date: Date) { lastPlayed[kind] = date }

    private enum CodingKeys: String, CodingKey { case lastPlayed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastPlayed = (try? c.decodeIfPresent([GameKind: Date].self, forKey: .lastPlayed)) ?? [:]
    }

    public static func load(from url: URL) -> GameHistory {
        guard let data = try? Data(contentsOf: url) else { return GameHistory() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(GameHistory.self, from: data)) ?? GameHistory()
    }

    public func save(to url: URL) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: url, options: .atomic)
    }
}

public enum GameChooser {
    /// A ready game never played comes first (in `ready` order), otherwise the one played longest ago.
    public static func pick(ready: [GameKind], lastPlayed: [GameKind: Date]) -> GameKind {
        if let fresh = ready.first(where: { lastPlayed[$0] == nil }) { return fresh }
        return ready.min { lastPlayed[$0]! < lastPlayed[$1]! } ?? .ticTacToe
    }
}

/// Why a game cannot start now (decision 26). The raw values are the tool's refusal codes.
public enum GameRefusal: String, Sendable {
    case exhausted = "chilk_exhausted", topStage = "top_stage", exercise = "in_exercise", notReady = "not_ready"
}

public enum GameGate {
    /// No games while he is «измотан», on stages 3–4 (dimmed screen / the pause) or in a guided exercise.
    public static func refusal(kind: GameKind, exhausted: Bool, stage: Int, exercise: Bool) -> GameRefusal? {
        guard GameKind.ready.contains(kind) else { return .notReady }
        if exhausted { return .exhausted }
        if stage >= 3 { return .topStage }
        if exercise { return .exercise }
        return nil
    }
}

// MARK: - Games and breaks (decision 32)

public enum GameBreakAction: Equatable, Sendable {
    /// Nothing to show: play on (a waiting request shows when the game ends or the notebook closes).
    case keepPlaying
    /// Show the request in the notebook: between games it holds the next one; mid-game (after 10 min) it is a sign.
    case card
    /// Stage 3 / 4 or «измотан»: the game is saved and paused, Chilk goes to the edge; «Доиграем?» after the rest.
    case pause
}

public enum GameBreakPolicy {
    /// A request waits for the end of a game at most this long (a long game: battleship, checkers).
    public static let maxWait: TimeInterval = 600

    /// `stage`/`need`: the request on screen (`nil` = none); `waiting`: how long it has waited for the game.
    public static func decide(stage: Int?, need: Need?, slumped: Bool, silent: Bool, betweenGames: Bool,
                              waiting: TimeInterval) -> GameBreakAction {
        if slumped { return .pause }
        guard let stage, stage >= 1, let need else { return .keepPlaying }
        if stage >= 3 { return .pause }
        // Тишина: no signs. The end of the day concerns work apps only (user story 34): an evening game goes on.
        if silent || need == .endOfDay { return .keepPlaying }
        return betweenGames || waiting >= maxWait ? .card : .keepPlaying
    }
}

// MARK: - A match (decisions 28–29)

public enum GameResult: String, Codable, Sendable {
    case you, chilk, draw

    /// Decision 29: he cheers when he wins, sulks when you win, shrugs at a draw.
    public var reaction: GameReaction {
        switch self {
        case .chilk: .cheer
        case .you: .offended
        case .draw: .shrug
        }
    }
}

/// Game-only reactions: not in `Emotion` (Codex may not ask for a shrug).
public enum GameReaction: String, Sendable { case cheer, offended, shrug }

/// Exactly `length` games; the first move alternates (game 1 — you); a draw scores nobody.
public struct GameMatch: Codable, Equatable, Sendable {
    public static let lengths = 1...6
    public static let defaultLength = 3

    public let length: Int
    public private(set) var you = 0
    public private(set) var chilk = 0
    public private(set) var played = 0

    public init(length: Int = GameMatch.defaultLength) {
        self.length = min(Self.lengths.upperBound, max(Self.lengths.lowerBound, length))
    }

    /// The game being played, 1-based.
    public var game: Int { min(played + 1, length) }
    public var isOver: Bool { played >= length }
    /// Who moves first in the current game.
    public var youStart: Bool { played % 2 == 0 }

    public mutating func record(_ r: GameResult) {
        guard !isOver else { return }
        played += 1
        switch r {
        case .you: you += 1
        case .chilk: chilk += 1
        case .draw: break
        }
    }

    public var result: GameResult? {
        guard isOver else { return nil }
        return you > chilk ? .you : chilk > you ? .chilk : .draw
    }
}

// MARK: - Tic-tac-toe (decision 29)

public enum TicMark: String, Codable, Sendable {
    case x, o
    public var other: TicMark { self == .x ? .o : .x }
}

public enum TicOutcome: Equatable, Sendable {
    case won(TicMark, line: [Int])
    case draw
}

/// The 3×3 board, cells row by row (0 1 2 / 3 4 5 / 6 7 8). You are crosses, Chilk noughts.
public struct TicTacToe: Codable, Equatable, Sendable {
    public static let lines = [[0, 1, 2], [3, 4, 5], [6, 7, 8], [0, 3, 6], [1, 4, 7], [2, 5, 8], [0, 4, 8], [2, 4, 6]]

    public private(set) var cells: [TicMark?]

    public init(cells: [TicMark?] = Array(repeating: nil, count: 9)) {
        precondition(cells.count == 9)
        self.cells = cells
    }

    public var empty: [Int] { cells.indices.filter { cells[$0] == nil } }

    /// `nil` while the game goes on.
    public var outcome: TicOutcome? {
        for line in Self.lines {
            if let m = cells[line[0]], cells[line[1]] == m, cells[line[2]] == m { return .won(m, line: line) }
        }
        return empty.isEmpty ? .draw : nil
    }

    /// `false`: off the board, taken, or the game is over.
    @discardableResult
    public mutating func play(_ cell: Int, _ mark: TicMark) -> Bool {
        guard cells.indices.contains(cell), cells[cell] == nil, outcome == nil else { return false }
        cells[cell] = mark
        return true
    }
}

/// Chilk plays right (minimax) but «yawns» on about a quarter of his moves: a random free cell instead (decision 29,
/// no difficulty choice). Among equally good moves he picks at random, so he is not predictable.
public enum TicTacToeAI {
    public static let yawnChance = 0.25
    public static let thinkRange = 0.5...1.2

    /// Every move that keeps the best result for `mark` (a win as fast as possible, a loss as late as possible).
    public static func bestMoves(_ board: TicTacToe, for mark: TicMark) -> [Int] {
        var memo: [Int: Int] = [:]
        var best = Int.min, moves: [Int] = []
        for cell in board.empty {
            var next = board
            next.play(cell, mark)
            let score = -negamax(next, toMove: mark.other, memo: &memo)
            if score > best { best = score; moves = [cell] } else if score == best { moves.append(cell) }
        }
        return moves
    }

    /// Score for the side to move. Counted from the filled cells, not the search depth, so a position scores the
    /// same from any root and the memo (≤ 3⁹ positions) stays valid; a win with fewer marks is worth more.
    private static func negamax(_ board: TicTacToe, toMove: TicMark, memo: inout [Int: Int]) -> Int {
        let key = board.cells.reduce(0) { $0 * 3 + ($1 == nil ? 0 : $1 == .x ? 1 : 2) } * 2 + (toMove == .x ? 0 : 1)
        if let known = memo[key] { return known }
        let free = board.empty
        let filled = 9 - free.count
        let score: Int
        switch board.outcome {
        case .won(let m, _)?: score = m == toMove ? 10 - filled : filled - 10
        case .draw?: score = 0
        case nil:
            var best = Int.min
            for cell in free {
                var next = board
                next.play(cell, toMove)
                best = max(best, -negamax(next, toMove: toMove.other, memo: &memo))
            }
            score = best
        }
        memo[key] = score
        return score
    }

    public static func move<R: RandomSource>(_ board: TicTacToe, for mark: TicMark, rng: inout R) -> (cell: Int, yawned: Bool) {
        let free = board.empty
        precondition(!free.isEmpty, "no move on a full board")
        if rng.next() < yawnChance { return (pick(free, &rng), true) }
        return (pick(bestMoves(board, for: mark), &rng), false)
    }

    /// He «thinks» 0.5–1.2 s before drawing his nought.
    public static func thinkTime<R: RandomSource>(rng: inout R) -> Double {
        rng.uniform(thinkRange.lowerBound, thinkRange.upperBound)
    }

    private static func pick<R: RandomSource>(_ cells: [Int], _ rng: inout R) -> Int {
        cells[min(cells.count - 1, Int(rng.next() * Double(cells.count)))]
    }
}
