import ChilkCore
import Testing

/// Slice 7c (SPEC decision 30): battleship 10×10, 1×4 · 2×3 · 3×2 · 4×1, no touching even at corners.
struct FleetTests {
    @Test func randomFleetsAreAlwaysLegal() {
        var rng = SeededRandom(seed: 1)
        for _ in 0..<200 {
            let f = Fleet.random(rng: &rng)
            #expect(f.isValid)
            #expect(f.ships.map(\.length).sorted(by: >) == Fleet.lengths)
        }
    }

    @Test func shipsMayNotTouchEvenAtACorner() {
        let a = Ship(x: 0, y: 0, length: 2, horizontal: true)
        #expect(!Fleet.fits(Ship(x: 2, y: 1, length: 1, horizontal: true), among: [a]))       // diagonal
        #expect(!Fleet.fits(Ship(x: 2, y: 0, length: 1, horizontal: true), among: [a]))       // end to end
        #expect(Fleet.fits(Ship(x: 3, y: 0, length: 1, horizontal: true), among: [a]))
        #expect(!Fleet.fits(Ship(x: 8, y: 0, length: 3, horizontal: true), among: []))          // off the sea
        #expect(!Fleet.fits(Ship(x: 0, y: 8, length: 3, horizontal: false), among: []))
    }

    @Test func movingAndRotatingKeepTheFleetLegal() {
        var rng = SeededRandom(seed: 5)
        var f = Fleet.random(rng: &rng)
        var moves = 0
        for i in 0..<400 {
            let index = i % f.ships.count
            if f.move(index, to: rng.index(10), rng.index(10), horizontal: rng.next() < 0.5) { moves += 1 }
            #expect(f.isValid)
        }
        #expect(moves > 10)
        let before = f
        let blocked = f.move(0, to: 9, 9, horizontal: true)                                     // a 4 cannot sit there
        #expect(!blocked && f == before)
    }
}

struct SeaTests {
    let fleet = Fleet(ships: [Ship(x: 0, y: 0, length: 4, horizontal: true), Ship(x: 0, y: 2, length: 3, horizontal: true),
                              Ship(x: 5, y: 2, length: 3, horizontal: true), Ship(x: 0, y: 4, length: 2, horizontal: true),
                              Ship(x: 3, y: 4, length: 2, horizontal: true), Ship(x: 6, y: 4, length: 2, horizontal: true),
                              Ship(x: 0, y: 6, length: 1, horizontal: true), Ship(x: 2, y: 6, length: 1, horizontal: true),
                              Ship(x: 4, y: 6, length: 1, horizontal: true), Ship(x: 6, y: 6, length: 1, horizontal: true)])

    @Test func theTestFleetIsLegal() { #expect(fleet.isValid) }

    @Test func aHitShootsAgainAMissPassesASinkingDotsTheShipsSurroundings() {
        var sea = Sea(fleet: fleet)
        #expect(sea.fire(99) == .miss && !ShotResult.miss.again)
        #expect(sea.fire(99) == .wasted)
        #expect(sea.fire(60) == .sunk(Ship(x: 0, y: 6, length: 1, horizontal: true)))           // the single at (0, 6)
        #expect(sea.mark(50) == .dot && sea.mark(71) == .dot && sea.mark(60) == .sunk)
        #expect(sea.fire(71) == .wasted)                                                         // known empty
        let hit = sea.fire(0)
        #expect(hit == .hit && hit.again)
        #expect(sea.mark(0) == .hit)
        _ = sea.fire(1); _ = sea.fire(2)
        #expect(sea.fire(3) == .sunk(Ship(x: 0, y: 0, length: 4, horizontal: true)))
        #expect(sea.mark(4) == .dot && sea.mark(14) == .dot && sea.mark(0) == .sunk)
    }

    @Test func theGameEndsWhenAFleetIsGone() {
        var g = BattleshipGame(yours: fleet, his: fleet)
        #expect(g.winner == nil)
        for s in fleet.ships { for c in s.cells { _ = g.his.fire(c) } }
        #expect(g.winner == .you)
    }
}

/// Chilk: random until a hit, then he finishes the ship; he never shoots twice or into a dot, never sees ships.
struct BattleshipAITests {
    @Test func afterOneHitHeShootsANeighbour() {
        var sea = Sea(fleet: Fleet(ships: [Ship(x: 4, y: 4, length: 3, horizontal: true)]))
        _ = sea.fire(44)
        var rng = SeededRandom(seed: 2)
        for _ in 0..<50 { #expect([43, 45, 34, 54].contains(BattleshipAI.move(sea, rng: &rng))) }
    }

    @Test func twoHitsInARowAreFinishedAlongTheirLine() {
        var sea = Sea(fleet: Fleet(ships: [Ship(x: 4, y: 4, length: 3, horizontal: true)]))
        _ = sea.fire(44); _ = sea.fire(45)
        var rng = SeededRandom(seed: 3)
        for _ in 0..<50 { #expect([43, 46].contains(BattleshipAI.move(sea, rng: &rng))) }
    }

    @Test func heSinksAWholeFleetWithoutWastingAShot() {
        var rng = SeededRandom(seed: 9)
        var total = 0
        for _ in 0..<30 {
            var sea = Sea(fleet: Fleet.random(rng: &rng))
            var shots = 0
            while !sea.allSunk {
                let r = sea.fire(BattleshipAI.move(sea, rng: &rng))
                #expect(r != .wasted)
                shots += 1
            }
            total += shots
        }
        let mean = Double(total) / 30
        #expect(mean > 50 && mean < 92, "mean \(mean)")         // a middle player: well below 100, far from perfect
    }
}
