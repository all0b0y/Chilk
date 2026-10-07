import ChilkCore
import Testing

/// Slice 7d (SPEC decision 31): Russian draughts.
struct DraughtsRulesTests {
    /// A board from a picture: rows top to bottom, `y`/`Y` yours (man/king), `c`/`C` Chilk's, `.` empty.
    func board(_ rows: [String], toMove: DraughtsSide = .you) -> Draughts {
        var squares: [DraughtsPiece?] = Array(repeating: nil, count: 64)
        for (r, row) in rows.enumerated() {
            for (c, ch) in row.enumerated() {
                switch ch {
                case "y": squares[r * 8 + c] = DraughtsPiece(.you)
                case "Y": squares[r * 8 + c] = DraughtsPiece(.you, king: true)
                case "c": squares[r * 8 + c] = DraughtsPiece(.chilk)
                case "C": squares[r * 8 + c] = DraughtsPiece(.chilk, king: true)
                default: break
                }
            }
        }
        return Draughts(squares: squares, toMove: toMove)
    }

    @Test func theStartHasTwelveEachAndSevenOpeningMoves() {
        let b = Draughts()
        #expect(b.count(.you) == 12 && b.count(.chilk) == 12)
        #expect(b.moves.count == 7)
        #expect(b.moves.allSatisfy { $0.to / 8 == 4 })                                   // men go up only
    }

    @Test func takingIsCompulsoryAndMenTakeBackwards() {
        let b = board(["........",
                       "........",
                       "........",
                       "........",
                       "...y....",
                       "....c...",
                       "........",
                       "........"])
        // Your man at (4,3), Chilk's at (5,4) behind it: the only move is the backward take to (6,5).
        #expect(b.moves == [DraughtsMove(path: [35, 53], captured: [44], crowned: false)])
    }

    @Test func aSeriesGoesOnToTheEnd() {
        let b = board(["........",
                       "........",
                       "...c....",
                       "........",
                       ".c......",
                       "y.......",
                       "........",
                       "........"])
        // (5,0) takes (4,1) → (3,2), then (2,3) → (1,4): one move with two takes.
        #expect(b.moves.count == 1)
        #expect(b.moves[0].path == [40, 26, 12] && b.moves[0].captured == [33, 19])
    }

    @Test func aManCrownedInASeriesGoesOnAsAFlyingKing() {
        let b = board(["........",
                       "..c.....",
                       ".y......",
                       "......c.",
                       "........",
                       "........",
                       "........",
                       "........"])
        // (2,1) takes (1,2) and is crowned on (0,3); as a king it flies on over (3,6) to (4,7).
        #expect(b.moves == [DraughtsMove(path: [17, 3, 39], captured: [10, 30], crowned: true)])
        var played = b
        let ok = played.play(b.moves[0])
        #expect(ok)
        #expect(played.squares[39] == DraughtsPiece(.you, king: true) && played.count(.chilk) == 0)
        #expect(played.outcome == .you)
    }

    @Test func aKingFliesAndTakesFromAfar() {
        let b = board(["Y.......",
                       "........",
                       "........",
                       "........",
                       "....c...",
                       "........",
                       "........",
                       "........"])
        #expect(Set(b.moves.map(\.to)) == [45, 54, 63])                                // over (4,4), anywhere beyond
        #expect(b.moves.allSatisfy { $0.captured == [36] })
    }

    @Test func aFlyingKingMustStopWhereItCanTakeAgain() {
        let b = board(["Y.......",
                       "........",
                       "........",
                       "...c....",
                       "........",
                       "...c....",
                       "........",
                       "........"])
        // Over (3,3) only the landing (4,4) goes on: over (5,3) to (6,2) or (7,1).
        #expect(b.moves.allSatisfy { $0.captured == [27, 43] && $0.path[1] == 36 })
        #expect(Set(b.moves.map(\.to)) == [50, 57])
    }

    @Test func aPieceIsNotJumpedTwice() {
        let b = board(["........",
                       "........",
                       ".c.c....",
                       "........",
                       ".c.c....",
                       "..y.....",
                       "........",
                       "........"])
        for m in b.moves { #expect(Set(m.captured).count == m.captured.count) }
        #expect(b.moves.contains { $0.captured.count == 4 && $0.to == $0.from })        // round the ring, back home
    }

    @Test func noMoveLosesAndQuietKingsDraw() {
        let gone = board(["........", "........", "........", "...c....", "........", "........", "........", "........"])
        #expect(gone.outcome == .chilk)                                                // you have no piece: you lose
        let blocked = board(["........", "........", "........", "........", "........", "c.......", "y.......", "........"])
        // Your man at (6,0) can only go to (5,1)... free, so not blocked; a truly blocked one:
        let stuck = board(["........", "........", "........", "........", "........", ".c......", "y.......", ".c......"])
        #expect(blocked.outcome == nil)
        #expect(stuck.moves.isEmpty == false || stuck.outcome == .chilk)
        var kings = board(["Y.......", "........", "........", "........", "........", "........", "........", "......C."])
        var plies = 0
        while kings.outcome == nil, plies < 100 {
            guard let m = kings.moves.first(where: { $0.captured.isEmpty }) else { break }
            kings.play(m)
            plies += 1
        }
        #expect(kings.outcome == .draw && plies == Draughts.quietLimit)
    }
}

struct DraughtsAITests {
    @Test func heTakesTheBigSeriesWhenHeIsAwake() {
        let b = DraughtsRulesTests().board(["........",
                                            "........",
                                            ".c.c....",
                                            "........",
                                            ".c.c....",
                                            "..y.....",
                                            "........",
                                            "........"])
        let best = DraughtsAI.bestMoves(b, depth: 2)
        #expect(best.allSatisfy { $0.captured.count == 4 })
    }

    @Test func heYawnsAboutAQuarterOfTheTime() {
        var rng = SeededRandom(seed: 4)
        let b = Draughts(toMove: .chilk)
        let n = 1200
        let yawns = (0..<n).filter { _ in DraughtsAI.move(b, rng: &rng, depth: 1).yawned }.count
        let p = Double(yawns) / Double(n), sigma = (0.25 * 0.75 / Double(n)).squareRoot()
        #expect(abs(p - 0.25) < 4 * sigma)
    }

    @Test func aWholeGameEndsAndStaysLegal() {
        var rng = SeededRandom(seed: 6)
        var b = Draughts()
        var plies = 0
        while b.outcome == nil, plies < 400 {
            let m = DraughtsAI.move(b, rng: &rng, depth: 2).move
            let ok = b.play(m)
            #expect(ok)
            plies += 1
        }
        #expect(b.outcome != nil)
    }
}
