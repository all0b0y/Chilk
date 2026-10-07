import Foundation

// MARK: - Battleship (slice 7c, SPEC decision 30)

/// One ship: its bow at (x, y), going right (horizontal) or down. Cells are `y * 10 + x` on the 10×10 sea.
public struct Ship: Codable, Equatable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var length: Int
    public var horizontal: Bool

    public init(x: Int, y: Int, length: Int, horizontal: Bool) {
        self.x = x
        self.y = y
        self.length = length
        self.horizontal = horizontal
    }

    public var cells: [Int] {
        (0..<length).map { i in horizontal ? y * Sea.size + x + i : (y + i) * Sea.size + x }
    }

    public var inBounds: Bool {
        x >= 0 && y >= 0 && (horizontal ? x + length <= Sea.size && y < Sea.size : y + length <= Sea.size && x < Sea.size)
    }

    /// Its cells and every cell touching them, corners included (ships may not touch).
    public var halo: Set<Int> {
        var out = Set<Int>()
        for c in cells {
            let cx = c % Sea.size, cy = c / Sea.size
            for dy in -1...1 {
                for dx in -1...1 {
                    let nx = cx + dx, ny = cy + dy
                    if nx >= 0, ny >= 0, nx < Sea.size, ny < Sea.size { out.insert(ny * Sea.size + nx) }
                }
            }
        }
        return out
    }

    public var rotated: Ship { Ship(x: x, y: y, length: length, horizontal: !horizontal) }
}

/// The ten ships: one of 4, two of 3, three of 2, four of 1; inside the sea; never touching, not even at a corner.
public struct Fleet: Codable, Equatable, Sendable {
    public static let lengths = [4, 3, 3, 2, 2, 2, 1, 1, 1, 1]
    public var ships: [Ship]

    public init(ships: [Ship]) { self.ships = ships }

    /// `ship` fits among `others` (in bounds, not touching any).
    public static func fits(_ ship: Ship, among others: [Ship]) -> Bool {
        guard ship.inBounds else { return false }
        let taken = others.reduce(into: Set<Int>()) { $0.formUnion($1.halo) }
        return taken.isDisjoint(with: ship.cells)
    }

    public var isValid: Bool {
        guard ships.map(\.length).sorted(by: >) == Self.lengths else { return false }
        for (i, s) in ships.enumerated() where !Self.fits(s, among: ships.enumerated().filter { $0.offset != i }.map(\.element)) {
            return false
        }
        return true
    }

    /// A random legal fleet (largest ships first; starts over in the rare dead end).
    public static func random<R: RandomSource>(rng: inout R) -> Fleet {
        while true {
            var ships: [Ship] = []
            var stuck = false
            for length in lengths {
                var placed = false
                for _ in 0..<300 {
                    let h = rng.next() < 0.5
                    let s = Ship(x: rng.index(Sea.size), y: rng.index(Sea.size), length: length, horizontal: h)
                    if fits(s, among: ships) { ships.append(s); placed = true; break }
                }
                if !placed { stuck = true; break }
            }
            if !stuck { return Fleet(ships: ships) }
        }
    }

    /// Moves ship `index` to (x, y) — or rotates it — if it still fits; `false` = left as it was.
    @discardableResult
    public mutating func move(_ index: Int, to x: Int, _ y: Int, horizontal: Bool? = nil) -> Bool {
        guard ships.indices.contains(index) else { return false }
        var s = ships[index]
        s.x = x
        s.y = y
        if let horizontal { s.horizontal = horizontal }
        let others = ships.enumerated().filter { $0.offset != index }.map(\.element)
        guard Self.fits(s, among: others) else { return false }
        ships[index] = s
        return true
    }

    public func ship(at cell: Int) -> Int? { ships.firstIndex { $0.cells.contains(cell) } }
}

public enum ShotResult: Equatable, Sendable {
    case miss, hit, sunk(Ship)
    /// Shot before, or known empty (a dot around a sunk ship): not a move.
    case wasted

    /// A hit or a sinking: the same player shoots again (decision 30).
    public var again: Bool {
        switch self {
        case .hit, .sunk: true
        case .miss, .wasted: false
        }
    }
}

/// What a player can see of a cell of the other sea.
public enum SeaMark: Equatable, Sendable { case unknown, miss, dot, hit, sunk }

/// One side's sea: its fleet and the shots it has taken. After a sinking the cells around the ship are dotted
/// (known empty) for both players.
public struct Sea: Codable, Equatable, Sendable {
    public static let size = 10
    public static let cells = size * size

    public let fleet: Fleet
    public private(set) var shots: Set<Int> = []
    public private(set) var dots: Set<Int> = []

    public init(fleet: Fleet) { self.fleet = fleet }

    public mutating func fire(_ cell: Int) -> ShotResult {
        guard (0..<Self.cells).contains(cell), !shots.contains(cell), !dots.contains(cell) else { return .wasted }
        shots.insert(cell)
        guard let i = fleet.ship(at: cell) else { return .miss }
        let ship = fleet.ships[i]
        guard ship.cells.allSatisfy(shots.contains) else { return .hit }
        dots.formUnion(ship.halo.subtracting(ship.cells).subtracting(shots))
        return .sunk(ship)
    }

    public func isSunk(_ ship: Ship) -> Bool { ship.cells.allSatisfy(shots.contains) }
    public var allSunk: Bool { fleet.ships.allSatisfy(isSunk) }
    public var sunkShips: [Ship] { fleet.ships.filter(isSunk) }

    /// What the shooter knows about `cell`.
    public func mark(_ cell: Int) -> SeaMark {
        if dots.contains(cell) { return .dot }
        guard shots.contains(cell) else { return .unknown }
        guard let i = fleet.ship(at: cell) else { return .miss }
        return isSunk(fleet.ships[i]) ? .sunk : .hit
    }

    /// Cells that may still be shot at.
    public var open: [Int] { (0..<Self.cells).filter { !shots.contains($0) && !dots.contains($0) } }
}

/// Both seas of one game: `yours` (Chilk shoots at it) and `his` (you shoot at it).
public struct BattleshipGame: Codable, Equatable, Sendable {
    public var yours: Sea
    public var his: Sea

    public init(yours: Fleet, his: Fleet) {
        self.yours = Sea(fleet: yours)
        self.his = Sea(fleet: his)
    }

    /// `nil` while both fleets float.
    public var winner: GameResult? {
        if his.allSunk { return .you }
        if yours.allSunk { return .chilk }
        return nil
    }
}

/// Chilk plays an honest middle game (decision 30): he sees only what a player sees (his shots, the hits, the
/// sunk ships and the dots around them). He shoots at random until he hits, then finishes the ship: along its line
/// once two hits show it, otherwise one of the four neighbours.
public enum BattleshipAI {
    public static let thinkRange = 0.5...1.2

    public static func move<R: RandomSource>(_ sea: Sea, rng: inout R) -> Int {
        let open = Set(sea.open)
        precondition(!open.isEmpty, "no cell left to shoot")
        let wounded = (0..<Sea.cells).filter { sea.mark($0) == .hit }
        if !wounded.isEmpty {
            let targets = finishing(wounded, open: open)
            if !targets.isEmpty { return targets[rng.index(targets.count)] }
        }
        let all = open.sorted()
        return all[rng.index(all.count)]
    }

    /// The next cells of a wounded ship: its line's two ends once two hits line up, else the four neighbours.
    static func finishing(_ hits: [Int], open: Set<Int>) -> [Int] {
        let n = Sea.size
        let xs = Set(hits.map { $0 % n }), ys = Set(hits.map { $0 / n })
        func ok(_ x: Int, _ y: Int) -> Int? {
            guard x >= 0, y >= 0, x < n, y < n, open.contains(y * n + x) else { return nil }
            return y * n + x
        }
        if hits.count >= 2, ys.count == 1, let y = ys.first {
            return [ok(xs.min()! - 1, y), ok(xs.max()! + 1, y)].compactMap { $0 }
        }
        if hits.count >= 2, xs.count == 1, let x = xs.first {
            return [ok(x, ys.min()! - 1), ok(x, ys.max()! + 1)].compactMap { $0 }
        }
        // One hit (or two wounded ships at once — finish the first).
        let h = hits[0], x = h % n, y = h / n
        return [ok(x - 1, y), ok(x + 1, y), ok(x, y - 1), ok(x, y + 1)].compactMap { $0 }
    }

    public static func thinkTime<R: RandomSource>(rng: inout R) -> Double {
        rng.uniform(thinkRange.lowerBound, thinkRange.upperBound)
    }
}
