@testable import ChilkCore
import Foundation
import Testing

/// Slice 7a (SPEC decision 29): tic-tac-toe 3×3 — you are crosses, Chilk plays right but «yawns» ~25 % of his moves.
struct TicTacToeTests {
    private func board(_ s: String) -> TicTacToe {
        // "xo. .x. ..o" → cells row by row; '.' = empty
        TicTacToe(cells: s.filter { "xo.".contains($0) }.map { $0 == "x" ? .x : $0 == "o" ? .o : nil })
    }

    @Test func rowsColumnsAndDiagonalsWinWithTheirLine() {
        #expect(board("xxx ... oo.").outcome == .won(.x, line: [0, 1, 2]))
        #expect(board("o.x o.x o..").outcome == .won(.o, line: [0, 3, 6]))
        #expect(board("x.o .xo ..x").outcome == .won(.x, line: [0, 4, 8]))
        #expect(board("o.x .x. x.o").outcome == .won(.x, line: [2, 4, 6]))
    }

    @Test func aFullBoardWithoutALineIsADrawAndAnOpenOneGoesOn() {
        #expect(board("xox xoo oxx").outcome == .draw)
        #expect(board("xo. ... ...").outcome == nil)
    }

    @Test func noMoveOnATakenCellOrAfterTheEnd() {
        var b = board("xxx oo. ...")
        let movedAfterEnd = b.play(5, .o)
        #expect(!movedAfterEnd)                            // the game is over
        var c = TicTacToe()
        let first = c.play(4, .x)
        #expect(first)
        let onTaken = c.play(4, .o)
        #expect(!onTaken)                            // taken
        let offBoard = c.play(9, .o)
        #expect(!offBoard)                            // off the board
        #expect(c.empty == [0, 1, 2, 3, 5, 6, 7, 8])
    }

    @Test func playingRightHeWinsWhenHeCanAndBlocksWhenHeMust() {
        // o to move: o can win at 5 (row 3-4-5), x threatens 2 (row 0-1-2) — winning first.
        #expect(TicTacToeAI.bestMoves(board("xx. oo. x.."), for: .o) == [5])
        // o to move: no win of his own, x threatens 2 → only the block.
        #expect(TicTacToeAI.bestMoves(board("xx. .o. ...") , for: .o) == [2])
    }

    @Test func perfectPlayAgainstPerfectPlayIsAlwaysADraw() {
        var rng = SeededRandom(seed: 3)
        for start in [TicMark.x, .o] {
            var b = TicTacToe(), turn = start
            while b.outcome == nil {
                let best = TicTacToeAI.bestMoves(b, for: turn)
                #expect(!best.isEmpty)
                let cell = best[Int(rng.next() * Double(best.count)) % best.count]
                let played = b.play(cell, turn)
                #expect(played)
                turn = turn.other
            }
            #expect(b.outcome == .draw)
        }
    }

    @Test func aboutAQuarterOfHisMovesAreYawns() {
        var rng = SeededRandom(seed: 11)
        var yawns = 0
        let tries = 2000
        for _ in 0..<tries {
            let move = TicTacToeAI.move(board("xo. .x. ..."), for: .o, rng: &rng)
            #expect([2, 3, 5, 6, 7, 8].contains(move.cell))
            if move.yawned { yawns += 1 }
        }
        let share = Double(yawns) / Double(tries)
        #expect(abs(share - TicTacToeAI.yawnChance) < 0.03, "share \(share)")
    }

    @Test func withoutAYawnHeNeverMissesAWinOrABlock() {
        var rng = SeededRandom(seed: 5)
        let b = board("xx. oo. x..")
        for _ in 0..<200 {
            let move = TicTacToeAI.move(b, for: .o, rng: &rng)
            if !move.yawned { #expect(move.cell == 5) }
        }
    }

    @Test func heThinksHalfASecondToASecondAndAHalf() {
        var rng = SeededRandom(seed: 2)
        for _ in 0..<500 {
            let t = TicTacToeAI.thinkTime(rng: &rng)
            #expect(t >= 0.5 && t <= 1.2)
        }
    }
}

/// Slice 7a (SPEC decisions 26, 28–29): a match of 1–6 games, the first move alternates, a draw scores nobody.
struct GameMatchTests {
    @Test func aMatchIsExactlyItsLengthAndTheFirstMoveAlternates() {
        var m = GameMatch(length: 3)
        #expect(m.game == 1 && m.youStart && !m.isOver)
        m.record(.you)
        #expect(m.game == 2 && !m.youStart)
        m.record(.draw)
        #expect(m.game == 3 && m.youStart)
        m.record(.chilk)
        #expect(m.isOver && m.you == 1 && m.chilk == 1 && m.result == .draw)
        m.record(.you)                                     // ignored after the end
        #expect(m.you == 1 && m.played == 3)
    }

    @Test func theLengthIsClampedToOneToSix() {
        #expect(GameMatch(length: 0).length == 1)
        #expect(GameMatch(length: 9).length == 6)
        #expect(GameMatch().length == GameMatch.defaultLength)
    }

    @Test func theMatchResultFollowsTheScore() {
        var m = GameMatch(length: 2)
        m.record(.chilk)
        #expect(m.result == nil)
        m.record(.draw)
        #expect(m.result == .chilk)
    }

    @Test func eachResultHasItsReaction() {
        #expect(GameResult.chilk.reaction == .cheer)
        #expect(GameResult.you.reaction == .offended)
        #expect(GameResult.draw.reaction == .shrug)
    }
}

/// Slice 7a (SPEC decision 26): «давай поиграем» picks the game not played for longest; no games while exhausted,
/// on stages 3–4 or in an exercise.
struct GameLaunchTests {
    @Test func aNeverPlayedReadyGameComesFirstThenTheOldest() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ready: [GameKind] = [.ticTacToe, .basketball]
        #expect(GameChooser.pick(ready: ready, lastPlayed: [.ticTacToe: now]) == .basketball)
        #expect(GameChooser.pick(ready: ready, lastPlayed: [:]) == .ticTacToe)
        #expect(GameChooser.pick(ready: ready, lastPlayed: [.ticTacToe: now, .basketball: now - 60]) == .basketball)
        #expect(GameChooser.pick(ready: [.ticTacToe], lastPlayed: [.ticTacToe: now]) == .ticTacToe)
    }

    @Test func onlyTicTacToeIsReadyInSevenA() {
        #expect(GameKind.ready == [.ticTacToe])
    }

    @Test func gamesAreRefusedWhileExhaustedOnTheTopStagesAndInAnExercise() {
        #expect(GameGate.refusal(kind: .ticTacToe, exhausted: false, stage: 2, exercise: false) == nil)
        #expect(GameGate.refusal(kind: .ticTacToe, exhausted: true, stage: 0, exercise: false) == .exhausted)
        #expect(GameGate.refusal(kind: .ticTacToe, exhausted: false, stage: 3, exercise: false) == .topStage)
        #expect(GameGate.refusal(kind: .ticTacToe, exhausted: false, stage: 4, exercise: false) == .topStage)
        #expect(GameGate.refusal(kind: .ticTacToe, exhausted: false, stage: 0, exercise: true) == .exercise)
        #expect(GameGate.refusal(kind: .checkers, exhausted: false, stage: 0, exercise: false) == .notReady)
    }

    @Test func theHistoryKeepsAReadableJSONObject() throws {
        var h = GameHistory()
        h.played(.ticTacToe, at: Date(timeIntervalSince1970: 100))
        let json = String(decoding: try JSONEncoder().encode(h), as: UTF8.self)
        #expect(json.contains("\"tictactoe\""), "\(json)")
        #expect(try JSONDecoder().decode(GameHistory.self, from: Data(json.utf8)) == h)
        #expect(try JSONDecoder().decode(GameHistory.self, from: Data("{}".utf8)) == GameHistory())
    }
}

/// Slice 7a (decision 29): the game reactions are Chilk's acts; the shrug is game-only.
@MainActor
struct GameReactionTests {
    @Test func aDrawMakesHimShrugWithBothArmsOutThenItEnds() {
        let sim = CharacterSim(metrics: .standard, rng: SeededRandom(seed: 4))
        for _ in 0..<60 { sim.step(dt: 1.0 / 60, pointer: nil) }
        sim.react(.shrug)
        #expect(sim.act == .shrug)
        for _ in 0..<30 { sim.step(dt: 1.0 / 60, pointer: nil) }
        #expect(sim.pose.hands.count == 2 && sim.pose.hands.allSatisfy(\.arm))
        #expect(sim.mood.shrugging)
        for _ in 0..<90 { sim.step(dt: 1.0 / 60, pointer: nil) }
        #expect(sim.act == nil && !sim.mood.shrugging && sim.pose.hands.isEmpty)
    }

    @Test func winsAndLossesUseTheCheerAndTheSulk() {
        let sim = CharacterSim(metrics: .standard, rng: SeededRandom(seed: 4))
        sim.react(.cheer)
        #expect(sim.act == .cheer)
        sim.react(.offended)
        #expect(sim.act == .sulk)
        #expect(!Emotion.allCases.map(\.rawValue).contains("shrug"))
    }
}

/// Slice 7a (SPEC decision 32): a request during a game waits for the end of the game, ≤ 10 min; between games the
/// notebook shows it; stage 3 or «измотан» pause the game; Тишина shows no signs; the evening game is not work.
struct GameBreakPolicyTests {
    private func decide(stage: Int?, need: Need? = .water, slumped: Bool = false, silent: Bool = false,
                        between: Bool = false, waiting: TimeInterval = 0) -> GameBreakAction {
        GameBreakPolicy.decide(stage: stage, need: need, slumped: slumped, silent: silent, betweenGames: between,
                               waiting: waiting)
    }

    @Test func noRequestMeansPlayOn() {
        #expect(decide(stage: nil, need: nil) == .keepPlaying)
        #expect(decide(stage: 0, between: true) == .keepPlaying)          // a pantomime hint is not a request
    }

    @Test func aRequestWaitsForTheEndOfTheGameButNoLongerThanTenMinutes() {
        #expect(decide(stage: 1) == .keepPlaying)
        #expect(decide(stage: 2, waiting: 599) == .keepPlaying)
        #expect(decide(stage: 2, waiting: 600) == .card)
        #expect(decide(stage: 1, between: true) == .card)
    }

    @Test func stageThreeOrExhaustedPauseTheGame() {
        #expect(decide(stage: 3) == .pause)
        #expect(decide(stage: 4, between: true) == .pause)
        #expect(decide(stage: nil, need: nil, slumped: true) == .pause)
    }

    @Test func silenceAndTheEndOfTheDayShowNoSign() {
        #expect(decide(stage: 1, silent: true, between: true, waiting: 700) == .keepPlaying)
        #expect(decide(stage: 2, need: .endOfDay, between: true, waiting: 700) == .keepPlaying)
        #expect(decide(stage: 3, need: .endOfDay) == .pause)                 // Strict's dimming still wins
    }
}
