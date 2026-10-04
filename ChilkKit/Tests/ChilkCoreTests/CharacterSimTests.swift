import CoreGraphics
import Foundation
import Testing
@testable import ChilkCore

@Suite("Spring")
struct SpringTests {
    @Test func settlesOnTarget() {
        var s = Spring(0, stiffness: 170, damping: 14)
        s.target = 100
        for _ in 0..<(60 * 3) { s.step(1.0 / 60) }
        #expect(abs(s.value - 100) < 0.5)
        #expect(abs(s.velocity) < 1)
    }

    @Test func staysStableAtThirtyFps() {
        var s = Spring(0, stiffness: 330, damping: 10)   // the stiffest spring Чилк uses (squash)
        s.impulse(7.5)
        for _ in 0..<(30 * 4) { s.step(1.0 / 60); s.step(1.0 / 60) }   // app sub-steps dt/2
        #expect(abs(s.value) < 0.01)
    }
}

@Suite("CharacterSim")
@MainActor
struct CharacterSimTests {
    let m = Metrics.standard

    func run(_ sim: CharacterSim, seconds: Double, pointer: CGPoint? = nil, every: ((CharacterSim) -> Void)? = nil) {
        let dt = 1.0 / 60
        for _ in 0..<Int(seconds * 60) {
            sim.step(dt: dt, pointer: pointer)
            every?(sim)
        }
    }

    @Test func restsDockedWhenNothingHappens() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 1))
        run(sim, seconds: 3)
        #expect(abs(sim.pose.x - m.dockX) < 2)
        #expect(sim.pose.mood == Mood())
    }

    @Test func hopsFullyOutWhenHovered() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 2))
        let sliver = CGPoint(x: m.width - 6, y: Double(sim.bodyCenter.y))   // the part visible at the edge
        var minHop = 0.0
        run(sim, seconds: 2, pointer: sliver) { minHop = min(minHop, $0.pose.hop) }
        #expect(sim.isHovering)
        #expect(minHop < -8)                                   // a real little jump
        #expect(abs(sim.pose.x - m.peekX) < 3)
        // nothing cut by the screen edge: bean width + sticker border + drop shadow
        #expect(sim.pose.x + m.radiusX * 1.07 + 6 + 5 <= m.width)
    }

    @Test func hoverDoesNotFlickerWhileHeMovesOutFromUnderTheCursor() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 30))
        let sliver = CGPoint(x: m.width - 6, y: Double(sim.bodyCenter.y))
        var changes = 0
        var last = false
        run(sim, seconds: 4, pointer: sliver) {
            if $0.isHovering != last { changes += 1; last = $0.isHovering }
        }
        #expect(changes == 1)
    }

    @Test func hoverEndsShortlyAfterTheCursorLeaves() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 31))
        run(sim, seconds: 1, pointer: CGPoint(x: m.width - 6, y: Double(sim.bodyCenter.y)))
        #expect(sim.isHovering)
        run(sim, seconds: 0.15, pointer: CGPoint(x: 10, y: 10))
        #expect(sim.isHovering)                                // grace period
        run(sim, seconds: 0.3, pointer: CGPoint(x: 10, y: 10))
        #expect(!sim.isHovering)
        run(sim, seconds: 2)
        #expect(abs(sim.pose.x - m.dockX) < 3)
    }

    @Test func violentDraggingTiltsButNeverSpinsHim() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 32))
        sim.isCarried = true
        var maxTilt = 0.0, maxLeaf = 0.0
        for i in 0..<120 {
            sim.step(dt: 1.0 / 60, pointer: nil, carryVelocity: (i / 5) % 2 == 0 ? 6000 : -6000)
            maxTilt = max(maxTilt, abs(sim.pose.tilt))
            maxLeaf = max(maxLeaf, abs(sim.pose.leafAngle))
        }
        #expect(maxTilt < 0.75)
        #expect(maxLeaf < 1.6)
    }

    @Test func carriedHeStaysCentredSoThePanelNeverCutsHim() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 33))
        run(sim, seconds: 1)
        #expect(abs(sim.positionX - m.dockX) < 2)
        let shift = m.panelShiftKeepingPlace(fromX: sim.positionX, toX: m.carryX, mirrored: false)
        let screenBefore = 1000 + sim.positionX
        sim.reframe(x: m.carryX)
        sim.isCarried = true
        #expect(abs((1000 + shift + sim.positionX) - screenBefore) < 0.001)   // no jump on screen
        var minLeft = Double.infinity, maxRight = -Double.infinity
        for i in 0..<120 {
            sim.step(dt: 1.0 / 60, pointer: nil, carryVelocity: (i / 8) % 2 == 0 ? 3000 : -3000)
            let reach = m.radiusX * 1.07 + 6 + 5            // bean + sticker border + drop shadow
            minLeft = min(minLeft, sim.positionX - reach)
            maxRight = max(maxRight, sim.positionX + reach)
        }
        #expect(minLeft > 0)
        #expect(maxRight < m.width)
    }

    @Test func panelShiftKeepsHimInPlaceOnBothEdges() {
        for mirrored in [false, true] {
            let panelX = 500.0, oldX = m.dockX, newX = m.carryX
            func screenX(_ panel: Double, _ x: Double) -> Double { panel + (mirrored ? m.width - x : x) }
            let shift = m.panelShiftKeepingPlace(fromX: oldX, toX: newX, mirrored: mirrored)
            #expect(abs(screenX(panelX, oldX) - screenX(panelX + shift, newX)) < 0.001)
        }
    }

    @Test func pokeAnnoysBrieflyAndSquashes() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 3))
        run(sim, seconds: 0.5)
        sim.poke()
        run(sim, seconds: 0.05)
        #expect(sim.pose.mood.annoyed)
        #expect(sim.pose.scaleY < 0.97)   // squashed
        run(sim, seconds: 1.0)
        #expect(!sim.pose.mood.annoyed)
    }

    @Test func threeQuickPokesMakeHimDizzy() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 4))
        sim.poke(); run(sim, seconds: 0.3)
        sim.poke(); run(sim, seconds: 0.3)
        sim.poke(); run(sim, seconds: 0.05)
        #expect(sim.pose.mood.dizzy)
        #expect(!sim.pose.mood.annoyed)
        run(sim, seconds: 2.7)
        #expect(!sim.pose.mood.dizzy)
    }

    @Test func slowPokesNeverMakeHimDizzy() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 5))
        var everDizzy = false
        for _ in 0..<4 {
            sim.poke()
            run(sim, seconds: 1.5) { everDizzy = everDizzy || $0.pose.mood.dizzy }
        }
        #expect(!everDizzy)
    }

    @Test func callMakesHimHopOutThenGoBack() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 6))
        run(sim, seconds: 1)
        sim.call(line: "Звал?")
        run(sim, seconds: 1.5)
        #expect(sim.pose.mood.called)
        #expect(sim.pose.x < m.dockX - 60)
        #expect(sim.pose.bubble == "Звал?")
        run(sim, seconds: 3.2)
        #expect(!sim.pose.mood.called)
        #expect(sim.pose.bubble == nil)
        run(sim, seconds: 3)
        #expect(abs(sim.pose.x - m.dockX) < 3)
    }

    @Test func blinksEveryFewSecondsAndReopens() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 7))
        var closedRuns: [Double] = []
        var closedFor = 0.0
        run(sim, seconds: 30) {
            let closed = $0.pose.eyeOpen < 0.15 && !$0.pose.mood.yawning   // a yawn closes the eyes on purpose
            if closed { closedFor += 1.0 / 60 } else if closedFor > 0 { closedRuns.append(closedFor); closedFor = 0 }
        }
        #expect(closedRuns.count >= 5)          // ~ every 2.2–5.8 s (+ some double blinks)
        #expect(closedRuns.allSatisfy { $0 < 0.3 })
    }

    @Test func noAnticsWhileCalled() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 8))
        var antics = 0
        for _ in 0..<8 {
            sim.call(line: "Да?")
            run(sim, seconds: 4) { if $0.currentAntic != nil { antics += 1 } }
        }
        #expect(antics == 0)
    }

    @Test func anticsHappenWhenLeftAlone() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 9))
        var seen = Set<Antic>()
        run(sim, seconds: 120) { if let a = $0.currentAntic { seen.insert(a) } }
        #expect(seen.count >= 2)
    }

    @Test func eyesFollowThePointer() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 10))
        let c = sim.bodyCenter
        run(sim, seconds: 1, pointer: CGPoint(x: c.x - 200, y: c.y))
        #expect(sim.pose.lookX < -0.6)
        run(sim, seconds: 1, pointer: CGPoint(x: c.x + 200, y: c.y - 100))
        #expect(sim.pose.lookX > 0.5)
        #expect(sim.pose.lookY < 0)
    }

    @Test func fatigueHalfClosesTheEyes() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 11))
        sim.fatigue = 1
        var maxOpen = 0.0
        run(sim, seconds: 10) { maxOpen = max(maxOpen, $0.pose.eyeOpen) }
        #expect(maxOpen <= 0.46)
        #expect(sim.pose.fatigue == 1)
    }

    @Test func hitTestUsesTheBody() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 12))
        run(sim, seconds: 1)
        #expect(sim.contains(sim.bodyCenter))
        #expect(!sim.contains(CGPoint(x: 20, y: 20)))
    }

    @Test func calmsDownToThirtyFpsWhenIdle() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 13))
        run(sim, seconds: 4)
        // idle most of the time (blinks / antics briefly need 60 fps)
        var idleFrames = 0
        run(sim, seconds: 5) { if !$0.isBusy { idleFrames += 1 } }
        #expect(idleFrames > 5 * 60 / 2)
        sim.poke()
        run(sim, seconds: 0.05)
        #expect(sim.isBusy)
    }

    @Test func anticsIncludeTheWholeRepertoire() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 20))
        var seen = Set<Antic>()
        run(sim, seconds: 600) { if let a = $0.currentAntic { seen.insert(a) } }
        #expect(seen == Set(Antic.allCases))       // 6 antics, all reachable
    }

    @Test func yawnsMuchMoreAtNight() {
        func yawns(hour: Int) -> Int {
            let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 21))
            sim.hourOfDay = hour
            var count = 0
            var last: Antic?
            run(sim, seconds: 900) {
                if $0.currentAntic == .yawn, last != .yawn { count += 1 }
                last = $0.currentAntic
            }
            return count
        }
        #expect(yawns(hour: 1) > yawns(hour: 14) * 2)
    }

    @Test func dozesOffWhenUserIsAwayAndWakesWithAHop() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 22))
        run(sim, seconds: 1)
        sim.fallAsleep()
        run(sim, seconds: 3)
        #expect(sim.pose.mood.sleeping)
        #expect(sim.pose.eyeOpen < 0.01)
        var antics = 0
        run(sim, seconds: 60) { if $0.currentAntic != nil { antics += 1 } }
        #expect(antics == 0)                         // sleeps peacefully
        #expect(!sim.isBusy)                         // and costs 30 fps at most
        sim.wakeUp()
        run(sim, seconds: 0.15)
        #expect(sim.pose.hop < -5)                   // hops
        run(sim, seconds: 0.5)
        #expect(!sim.pose.mood.sleeping)
        #expect(sim.pose.eyeOpen > 0.5 || sim.pose.mood.yawning)
    }

    @Test func pokingWakesHimUp() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 23))
        sim.fallAsleep()
        run(sim, seconds: 3)
        sim.poke()
        #expect(!sim.isAsleep)
    }

    @Test func carriedLooksSurprisedAndLandsWithASquash() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 24))
        run(sim, seconds: 1)
        sim.isCarried = true
        run(sim, seconds: 0.5, pointer: sim.bodyCenter)
        #expect(sim.pose.mood.carried)
        #expect(!sim.isHovering)                     // held, not hovered
        #expect(sim.pose.eyeScale > 1.2)
        sim.isCarried = false
        run(sim, seconds: 0.05)
        #expect(sim.pose.scaleY < 0.97)
    }

    @Test func sayShowsABubbleForItsDuration() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 25))
        sim.say("С возвращением!", duration: 2)
        run(sim, seconds: 1)
        #expect(sim.pose.bubble == "С возвращением!")
        #expect(!sim.pose.mood.called)               // talking from the edge, not hopping out
        run(sim, seconds: 1.1)
        #expect(sim.pose.bubble == nil)
    }
}

@Suite("Presence")
struct PresenceTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func goesAwayAfterThreeIdleMinutesAndReportsTheFullAbsence() {
        var p = PresenceTracker()
        #expect(p.update(idleSeconds: 30, now: t0) == nil)
        #expect(p.update(idleSeconds: 180, now: t0.addingTimeInterval(150)) == .wentAway)
        #expect(p.update(idleSeconds: 900, now: t0.addingTimeInterval(870)) == nil)
        // the absence started at the last input (t0 - 30), not when we noticed it
        #expect(p.update(idleSeconds: 0.5, now: t0.addingTimeInterval(1200)) == .returned(after: 1230))
        #expect(!p.isAway)
    }

    @Test func greetingDependsOnAbsenceAndHour() {
        #expect(Greeting.after(absence: 60, hour: 9) == nil)
        #expect(Greeting.after(absence: 15 * 60, hour: 15) == .welcomeBack)
        #expect(Greeting.after(absence: 8 * 3600, hour: 8) == .goodMorning)
        #expect(Greeting.after(absence: 8 * 3600, hour: 20) == .welcomeBack)
    }
}
