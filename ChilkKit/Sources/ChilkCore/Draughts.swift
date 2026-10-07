import Foundation

// MARK: - Russian draughts (slice 7d, SPEC decision 31)

/// Whose pieces: yours start at the bottom (rows 5–7) and go up; Chilk's start at the top (rows 0–2) and go down.
public enum DraughtsSide: String, Codable, Sendable {
    case you, chilk
    public var other: DraughtsSide { self == .you ? .chilk : .you }
    /// The row a man of this side is crowned on.
    var crownRow: Int { self == .you ? 0 : 7 }
    var forward: Int { self == .you ? -1 : 1 }
}

public struct DraughtsPiece: Codable, Equatable, Hashable, Sendable {
    public var side: DraughtsSide
    public var king: Bool
    public init(_ side: DraughtsSide, king: Bool = false) {
        self.side = side
        self.king = king
    }
}

/// A move: the squares the piece goes through (`path[0]` = from, the last = where it stops), the pieces it takes,
/// whether it is crowned (also in the middle of a series — then it goes on as a king).
public struct DraughtsMove: Codable, Equatable, Hashable, Sendable {
    public let path: [Int]
    public let captured: [Int]
    public let crowned: Bool
    public init(path: [Int], captured: [Int], crowned: Bool) {
        self.path = path
        self.captured = captured
        self.crowned = crowned
    }

    public var from: Int { path[0] }
    public var to: Int { path[path.count - 1] }
}

/// The 8×8 board (squares `row * 8 + col`, dark squares only), the side to move, and the draw counter. Rules:
/// taking is compulsory (any series, not necessarily the longest), a series goes on to the end, men take backwards
/// too, kings fly (move and take over any distance), a man crowned during a series goes on as a king, a piece taken in
/// a series stays on the board until the move ends and may not be jumped twice. A side without a move loses; 15
/// moves each of kings only without a take is a draw.
public struct Draughts: Codable, Equatable, Sendable {
    public static let size = 8
    public static let quietLimit = 30

    public private(set) var squares: [DraughtsPiece?]
    public var toMove: DraughtsSide
    /// Plies in a row made by kings without a take.
    public private(set) var quiet = 0

    public init(toMove: DraughtsSide = .you) {
        squares = Array(repeating: nil, count: 64)
        for r in 0..<8 {
            for c in 0..<8 where Self.isDark(r * 8 + c) {
                if r < 3 { squares[r * 8 + c] = DraughtsPiece(.chilk) }
                if r > 4 { squares[r * 8 + c] = DraughtsPiece(.you) }
            }
        }
        self.toMove = toMove
    }

    public init(squares: [DraughtsPiece?], toMove: DraughtsSide) {
        precondition(squares.count == 64)
        self.squares = squares
        self.toMove = toMove
    }

    public static func isDark(_ s: Int) -> Bool { (s / 8 + s % 8) % 2 == 1 }

    private static let directions = [(-1, -1), (-1, 1), (1, -1), (1, 1)]

    private static func step(_ s: Int, _ d: (Int, Int), _ n: Int = 1) -> Int? {
        let r = s / 8 + d.0 * n, c = s % 8 + d.1 * n
        guard r >= 0, r < 8, c >= 0, c < 8 else { return nil }
        return r * 8 + c
    }

    // MARK: Moves

    /// Every legal move of the side to move; only takes when there is one.
    public var moves: [DraughtsMove] {
        var takes: [DraughtsMove] = []
        for s in 0..<64 {
            guard let p = squares[s], p.side == toMove else { continue }
            takes += captures(from: s, piece: p)
        }
        if !takes.isEmpty { return takes }
        var out: [DraughtsMove] = []
        for s in 0..<64 {
            guard let p = squares[s], p.side == toMove else { continue }
            for d in Self.directions {
                if p.king {
                    var n = 1
                    while let t = Self.step(s, d, n), squares[t] == nil {
                        out.append(DraughtsMove(path: [s, t], captured: [], crowned: false))
                        n += 1
                    }
                } else if d.0 == p.side.forward, let t = Self.step(s, d), squares[t] == nil {
                    out.append(DraughtsMove(path: [s, t], captured: [], crowned: t / 8 == p.side.crownRow))
                }
            }
        }
        return out
    }

    /// Every complete series of takes from `s`.
    private func captures(from s: Int, piece: DraughtsPiece) -> [DraughtsMove] {
        var out: [DraughtsMove] = []
        func free(_ t: Int) -> Bool { squares[t] == nil || t == s }       // its own start square is empty meanwhile
        func search(at: Int, king: Bool, path: [Int], taken: [Int], crowned: Bool) {
            var next: [(land: Int, over: Int, king: Bool)] = []
            for d in Self.directions {
                if king {
                    var n = 1
                    while let t = Self.step(at, d, n), free(t) { n += 1 }
                    guard let over = Self.step(at, d, n), let q = squares[over], q.side != piece.side,
                          !taken.contains(over) else { continue }
                    var lands: [Int] = []
                    var m = n + 1
                    while let t = Self.step(at, d, m), free(t) { lands.append(t); m += 1 }
                    // A flying king must stop where it can take again, if it can anywhere along the line.
                    let going = lands.filter { canTake(at: $0, king: true, side: piece.side, taken: taken + [over], start: s) }
                    for l in (going.isEmpty ? lands : going) { next.append((l, over, true)) }
                } else {
                    guard let over = Self.step(at, d), let q = squares[over], q.side != piece.side, !taken.contains(over),
                          let land = Self.step(at, d, 2), free(land) else { continue }
                    next.append((land, over, land / 8 == piece.side.crownRow))
                }
            }
            if next.isEmpty {
                if !taken.isEmpty { out.append(DraughtsMove(path: path, captured: taken, crowned: crowned)) }
                return
            }
            for n in next {
                search(at: n.land, king: n.king, path: path + [n.land], taken: taken + [n.over],
                       crowned: crowned || (n.king && !king))
            }
        }
        search(at: s, king: piece.king, path: [s], taken: [], crowned: false)
        return out
    }

    private func canTake(at: Int, king: Bool, side: DraughtsSide, taken: [Int], start: Int) -> Bool {
        func free(_ t: Int) -> Bool { squares[t] == nil || t == start }
        for d in Self.directions {
            var n = 1
            if king { while let t = Self.step(at, d, n), free(t) { n += 1 } }
            guard let over = Self.step(at, d, n), let q = squares[over], q.side != side, !taken.contains(over),
                  let land = Self.step(at, d, n + 1), free(land) else { continue }
            return true
        }
        return false
    }

    /// `false`: not a legal move now.
    @discardableResult
    public mutating func play(_ m: DraughtsMove) -> Bool {
        guard outcome == nil, moves.contains(m), var p = squares[m.from] else { return false }
        let byKing = p.king
        squares[m.from] = nil
        for c in m.captured { squares[c] = nil }
        if m.crowned { p.king = true }
        squares[m.to] = p
        quiet = byKing && m.captured.isEmpty ? quiet + 1 : 0
        toMove = toMove.other
        return true
    }

    /// `nil` while the game goes on.
    public var outcome: GameResult? {
        if quiet >= Self.quietLimit { return .draw }
        guard moves.isEmpty else { return nil }
        return toMove == .you ? .chilk : .you
    }

    public func count(_ side: DraughtsSide) -> Int { squares.compactMap { $0 }.filter { $0.side == side }.count }
}

/// Chilk looks a few moves ahead (alpha-beta) and «yawns» on about a quarter of his moves (a random legal move);
/// among equally good moves he picks at random (decision 31).
public enum DraughtsAI {
    public static let yawnChance = 0.25
    public static let depth = 4
    public static let thinkRange = 0.5...1.2

    public static func move<R: RandomSource>(_ board: Draughts, rng: inout R, depth: Int = depth) -> (move: DraughtsMove, yawned: Bool) {
        let all = board.moves
        precondition(!all.isEmpty, "no move")
        if rng.next() < yawnChance { return (all[rng.index(all.count)], true) }
        let best = bestMoves(board, depth: depth)
        return (best[rng.index(best.count)], false)
    }

    public static func bestMoves(_ board: Draughts, depth: Int = depth) -> [DraughtsMove] {
        var best = Int.min, out: [DraughtsMove] = []
        for m in board.moves {
            var next = board
            next.play(m)
            let v = -search(next, depth: depth - 1, alpha: -1_000_000, beta: 1_000_000)
            if v > best { best = v; out = [m] } else if v == best { out.append(m) }
        }
        return out
    }

    private static func search(_ b: Draughts, depth: Int, alpha: Int, beta: Int) -> Int {
        if let o = b.outcome {
            switch o {
            case .draw: return 0
            default: return (o == .you) == (b.toMove == .you) ? 100_000 + depth : -100_000 - depth
            }
        }
        if depth <= 0 { return evaluate(b) }
        var a = alpha
        for m in b.moves {
            var next = b
            next.play(m)
            let v = -search(next, depth: depth - 1, alpha: -beta, beta: -a)
            if v >= beta { return v }
            a = max(a, v)
        }
        return a
    }

    /// Material for the side to move: a man 100, a king 300, men a little more the further they have come.
    static func evaluate(_ b: Draughts) -> Int {
        var score = 0
        for s in 0..<64 {
            guard let p = b.squares[s] else { continue }
            let advance = p.side == .you ? 7 - s / 8 : s / 8
            let v = p.king ? 300 : 100 + advance * 3
            score += p.side == b.toMove ? v : -v
        }
        return score
    }

    public static func thinkTime<R: RandomSource>(rng: inout R) -> Double {
        rng.uniform(thinkRange.lowerBound, thinkRange.upperBound)
    }
}
