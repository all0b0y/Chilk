import ChilkCore
import CoreGraphics
import Testing

/// Slice 7b (SPEC decisions 27–28): basketball «Попадёт — не попадёт».
struct BasketballRulesTests {
    let screen = CGRect(x: 0, y: 0, width: 1500, height: 900)

    @Test func theChanceFallsWithTheDistanceFrom85To15Percent() {
        #expect(abs(Basketball.chance(distance: 500, screenWidth: 1500) - 0.85) < 1e-9)
        #expect(abs(Basketball.chance(distance: 1500, screenWidth: 1500) - 0.15) < 1e-9)
        #expect(abs(Basketball.chance(distance: 1000, screenWidth: 1500) - 0.5) < 1e-9)
        #expect(Basketball.chance(distance: 100, screenWidth: 1500) == 0.85)       // never above / below the ends
        #expect(Basketball.chance(distance: 4000, screenWidth: 1500) == 0.15)
        #expect(Basketball.chance(distance: 700, screenWidth: 1500) > Basketball.chance(distance: 900, screenWidth: 1500))
    }

    @Test func theRollFollowsTheChance() {
        var rng = SeededRandom(seed: 11)
        let n = 4000
        let hits = (0..<n).filter { _ in Basketball.scores(chance: 0.3, rng: &rng) }.count
        let p = Double(hits) / Double(n), sigma = (0.3 * 0.7 / Double(n)).squareRoot()
        #expect(abs(p - 0.3) < 4 * sigma)
    }

    @Test func theHoopStaysOnScreenAndAThirdOfTheWidthAway() {
        let him = CGPoint(x: 1400, y: 150)                                            // at the right edge
        let near = Basketball.minDistance(screenWidth: 1500)
        for p in [CGPoint(x: 1300, y: 200), CGPoint(x: 1400, y: 150), CGPoint(x: 1450, y: 880), CGPoint(x: 1000, y: 10),
                  CGPoint(x: -500, y: 2000), CGPoint(x: 300, y: 600)] {
            let q = Basketball.clampHoop(p, from: him, in: screen, margin: 60)
            #expect(screen.insetBy(dx: 59.9, dy: 59.9).contains(q), "\(p) → \(q)")
            #expect(hypot(q.x - him.x, q.y - him.y) >= near - 0.5, "\(p) → \(q)")
        }
        // Far enough already: left where it was dropped.
        #expect(Basketball.clampHoop(CGPoint(x: 300, y: 600), from: him, in: screen, margin: 60) == CGPoint(x: 300, y: 600))
    }

    @Test func theDefaultHoopIsAcrossTheScreenFromHim() {
        let right = Basketball.defaultHoop(from: CGPoint(x: 1400, y: 150), in: screen, margin: 60)
        let left = Basketball.defaultHoop(from: CGPoint(x: 100, y: 150), in: screen, margin: 60)
        #expect(right.x < 300 && left.x > 1200)
        #expect(right.y > 150 && left.y > 150)
    }

    @Test func aGuessScoresYouAndHisThrowDecidesHisFace() {
        #expect(ShotRound(guess: .hit, scored: true).result == .you)
        #expect(ShotRound(guess: .miss, scored: false).result == .you)
        #expect(ShotRound(guess: .hit, scored: false).result == .chilk)
        #expect(ShotRound(guess: .miss, scored: true).result == .chilk)
        #expect(ShotRound(guess: .miss, scored: false).firework)
        #expect(!ShotRound(guess: .hit, scored: false).firework)
        #expect(ShotRound(guess: .miss, scored: true).reaction == .cheer)                // in: «ликует»
        #expect(ShotRound(guess: .miss, scored: false).reaction == .offended)            // out: «обиделся»
    }

    @Test func aMatchOfThrowsCountsLikeAnyMatchAndEndsWithItsFinale() {
        var m = GameMatch(length: 4)
        for r in [ShotRound(guess: .hit, scored: true), .init(guess: .hit, scored: false),
                  .init(guess: .miss, scored: false), .init(guess: .hit, scored: false)] { m.record(r.result) }
        #expect(m.isOver && m.you == 2 && m.chilk == 2 && m.result == .draw)
        #expect(CourtFinale(.draw) == .highFive)
        #expect(CourtFinale(.you) == .fireworksAndClap)
        #expect(CourtFinale(.chilk) == .cheer)
        #expect(GameMatch().length == 3)
    }
}

struct ShotFlightTests {
    let from = CGPoint(x: 1380, y: 200), rim = CGPoint(x: 300, y: 520)

    @Test func theBallLeavesHisHandsAndGoesOverAnArc() {
        let f = ShotFlight(from: from, rim: rim, rimRadius: 22, scored: true, miss: .front, screenWidth: 1500)
        #expect(f.point(at: 0) == from)
        let mid = f.point(at: f.contact / 2)
        #expect(mid.y > max(from.y, rim.y) + 50)                                       // up over the line between them
        #expect(f.contact > 0.7 && f.contact < 1.3 && f.duration > f.contact)
    }

    @Test func inItDropsThroughTheRim() {
        let f = ShotFlight(from: from, rim: rim, rimRadius: 22, scored: true, miss: .front, screenWidth: 1500)
        let at = f.point(at: f.contact)
        #expect(abs(at.x - rim.x) < 1 && abs(at.y - rim.y) < 6)
        let below = f.point(at: f.contact + 0.3)
        #expect(abs(below.x - rim.x) < 1 && below.y < rim.y - 40)                       // down through the net
    }

    @Test func outItHitsTheRimAndFallsAwayFromIt() {
        for miss in [ShotFlight.Miss.front, .back] {
            let f = ShotFlight(from: from, rim: rim, rimRadius: 22, scored: false, miss: miss, screenWidth: 1500)
            let at = f.point(at: f.contact)
            #expect(abs(abs(at.x - rim.x) - 20.9) < 1, "\(miss)")                       // on the rim, not inside it
            for t in stride(from: f.contact + 0.05, through: f.duration, by: 0.05) {
                let p = f.point(at: t)
                #expect(abs(p.x - rim.x) > 22 || p.y > rim.y + 1, "\(miss) at \(t)")     // never down through the hoop
            }
            #expect(f.point(at: f.duration).y < rim.y - 100)
            let away = f.point(at: f.contact + 0.4).x - rim.x
            #expect(miss == .front ? away > 0 : away < 0)                               // back to him / on beyond
        }
        #expect(f(alphaAt: 0) == 1)
    }

    private func f(alphaAt t: Double) -> Double {
        ShotFlight(from: from, rim: rim, rimRadius: 22, scored: true, miss: .front, screenWidth: 1500).alpha(at: t)
    }
}

struct FireworksTests {
    @Test func aSmallOneBurstsAroundItsCentreAndFades() {
        var rng = SeededRandom(seed: 3)
        let show = Fireworks.small(at: CGPoint(x: 300, y: 600), rng: &rng)
        #expect(show.duration > 0.8 && show.duration < 1.3)
        let early = show.visible(at: 0.05)
        #expect(early.count == show.sparks.count)
        let spread = show.visible(at: 0.5).map { hypot($0.point.x - 300, $0.point.y - 600) }
        #expect(spread.allSatisfy { $0 > 5 && $0 < 160 })
        #expect(spread.reduce(0, +) / Double(spread.count) > 30)
        #expect(show.visible(at: show.duration + 0.01).isEmpty)
    }

    @Test func theBigOneGoesOffInTurnAcrossTheTop() {
        var rng = SeededRandom(seed: 5)
        let screen = CGRect(x: 0, y: 0, width: 1500, height: 900)
        let show = Fireworks.big(over: screen, rng: &rng)
        let origins = Set(show.sparks.map { "\($0.origin.x)" })
        #expect(origins.count == 6)
        #expect(show.sparks.allSatisfy { $0.origin.y > 450 && screen.contains($0.origin) })
        #expect(show.visible(at: 0.1).count < show.sparks.count)                        // the later bursts wait
        #expect(show.duration > 2.5 && show.duration < 3.5)
    }
}

/// Slice 7b: his throw, his clapping and «пять!».
@MainActor
struct CourtActsTests {
    func sim() -> CharacterSim {
        let s = CharacterSim(metrics: .standard, rng: SeededRandom(seed: 4))
        for _ in 0..<60 { s.step(dt: 1.0 / 60, pointer: nil) }
        return s
    }

    @Test func heHoldsTheBallOverHisHeadAndLetsGoAtTheRelease() {
        let s = sim()
        s.perform(.shoot)
        for _ in 0..<24 { s.step(dt: 1.0 / 60, pointer: nil) }                       // 0.4 s
        let held = s.pose.ball
        #expect(held != nil && abs(held!.y - 20) < 8)                                  // at his chest, in the dip
        #expect(s.pose.hands.count == 2 && s.pose.hands.allSatisfy { !$0.arm })         // the mittens on its sides
        for _ in 0..<(Int(Act.shootRelease * 60) - 24 + 2) { s.step(dt: 1.0 / 60, pointer: nil) }
        #expect(s.pose.ball == nil)
        let p = s.scenePoint(figure: Act.releaseBall), c = s.bodyCenter
        #expect(p.x < c.x - 40 && p.y < c.y - 30)                                      // into the screen, up
        for _ in 0..<40 { s.step(dt: 1.0 / 60, pointer: nil) }
        #expect(s.act == nil && s.pose.hands.isEmpty)
    }

    @Test func theFinalesAreTheClapTheCheerAndTheHighFive() {
        let s = sim()
        s.finale(.fireworksAndClap)
        #expect(s.act == .clap && s.isEmoting)
        for _ in 0..<20 { s.step(dt: 1.0 / 60, pointer: nil) }
        #expect(s.pose.hands.count == 2 && s.pose.hands.allSatisfy { !$0.arm } && s.mood.cheering)
        s.finale(.highFive)
        for _ in 0..<30 { s.step(dt: 1.0 / 60, pointer: nil) }
        #expect(s.act == .highFive && s.pose.hands.count == 1 && s.pose.hands[0].x < 0)  // the arm towards the screen
        s.finale(.cheer)
        #expect(s.act == .cheer)
        #expect(!Emotion.allCases.map(\.rawValue).contains("clap"))
    }
}
