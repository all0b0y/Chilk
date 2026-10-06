import CoreGraphics
import Foundation
import Testing
@testable import ChilkCore

// Slice 6a (grilling 2026-10-06, decisions 1–6 and 33): one signal — one meaning.

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

/// Only `need` can become due; the engine is driven second by second like the app does.
@MainActor
private final class Bench {
    let engine: BalanceEngine
    var now = ISO8601DateFormatter().date(from: "2026-10-05T09:00:00Z")!
    var events: [BalanceEvent] = []

    init(only need: Need, mode: BalanceMode? = nil, seed: UInt64 = 7) {
        var c = BalanceConfig()
        c.moodEvery = 1e8...(1e8 + 1)
        let never = 1e6...(1e6 + 1)
        if need != .water { c.waterMinutes = never }
        if need != .stretch { c.stretchMinutes = never }
        if need != .eyes { c.eyesMinutes = never }
        if need != .walk { c.walkMinutes = never }
        if need != .endOfDay { c.weekdayBudget = 1e9; c.weekendBudget = 1e9 }
        engine = BalanceEngine(config: c, rng: SeededRandom(seed: seed), calendar: utc)
        if let mode { _ = try? engine.setMode(mode) }
        _ = engine.tick(Signals(now: now))
    }

    @discardableResult
    func work(minutes: Double) -> [BalanceEvent] {
        var got: [BalanceEvent] = []
        for i in 0..<Int((minutes * 60).rounded()) {
            now += 1
            got += engine.tick(Signals(now: now, idle: Double(i % 6), frontApp: "com.apple.dt.Xcode"))
        }
        events += got
        return got
    }

    /// Works until the first request of any kind shows up (thresholds are random).
    func workUntilRequest(maxMinutes: Double = 300) -> BalanceEvent? {
        for _ in 0..<Int(maxMinutes * 60) {
            if let e = work(minutes: 1.0 / 60).first(where: { $0.isRequest }) { return e }
        }
        return nil
    }
}

private extension BalanceEvent {
    var isRequest: Bool {
        switch self {
        case .hint, .ask: true
        default: false
        }
    }
}

@Suite("6a: the ladder starts with the bubble in Soft and Strict")
@MainActor
struct LadderFloorTests {

    @Test func softStartsAtTheBubbleWithItsButtons() {
        let b = Bench(only: .water)
        #expect(b.engine.state.mode == .soft)
        #expect(b.workUntilRequest() == .ask(.water, stage: 1, buttons: [.done, .snooze, .busy], again: false))
        #expect(b.engine.state.episode?.stage == 1)
    }

    @Test func strictStartsAtTheBubbleToo() {
        let b = Bench(only: .stretch, mode: .strict)
        #expect(b.workUntilRequest() == .ask(.stretch, stage: 1, buttons: [.going, .snooze, .busy], again: false))
    }

    @Test func silenceStillOnlyPantomimes() {
        let b = Bench(only: .water, mode: .silent)
        #expect(b.workUntilRequest() == .hint(.water))
        b.work(minutes: 30)
        #expect(!b.events.contains { if case .ask = $0 { true } else { false } })
    }

    @Test func aStricterModeLiftsAPantomimeToTheBubble() throws {
        let b = Bench(only: .water, mode: .silent)
        #expect(b.workUntilRequest() == .hint(.water))
        #expect(try b.engine.setMode(.soft) == [.ask(.water, stage: 1, buttons: [.done, .snooze, .busy], again: false)])
        #expect(b.engine.state.episode?.stage == 1)
    }

    @Test func theNextStageStillComesAfterFiveToTenMinutes() {
        let b = Bench(only: .water)
        _ = b.workUntilRequest()
        let quiet = b.work(minutes: 4.9)
        #expect(!quiet.contains { if case .ask = $0 { true } else { false } })
        let later = b.work(minutes: 5.2)
        #expect(later.contains { if case .ask(.water, 2, _, false) = $0 { true } else { false } })
    }
}

@Suite("6a: the eyes mirror")
@MainActor
struct EyeStrainTests {

    @Test func eyeStrainStartsAtHalfThePressureAndTopsOutAtTheThreshold() {
        let b = Bench(only: .eyes)
        let threshold = b.engine.state.needs[.eyes]!.threshold
        b.work(minutes: threshold * 0.45 / 60)
        #expect(b.engine.eyeStrain == 0)
        b.work(minutes: threshold * 0.3 / 60)                       // 75 %
        #expect(abs(b.engine.eyeStrain - 0.5) < 0.05)
        b.work(minutes: threshold * 0.4 / 60)                       // 115 %
        #expect(b.engine.eyeStrain == 1)
    }

    @Test func restedEyesAndSwitchedOffEyesShowNoStrain() {
        let b = Bench(only: .eyes)
        b.work(minutes: b.engine.state.needs[.eyes]!.threshold / 60 + 1)
        #expect(b.engine.eyeStrain > 0.9)
        _ = b.engine.tookRest(.eyes)
        #expect(b.engine.eyeStrain == 0)

        let off = Bench(only: .eyes)
        var care = off.engine.state.care
        care = care.applying(.need(.eyes, on: false))
        _ = try? off.engine.setCare(care)
        off.work(minutes: 200)
        #expect(off.engine.eyeStrain == 0)
    }
}

@Suite("6a: Чилк's body language")
@MainActor
struct LivelyCharacterTests {
    let m = Metrics.standard

    func run(_ sim: CharacterSim, seconds: Double, pointer: CGPoint? = nil, every: ((CharacterSim) -> Void)? = nil) {
        for _ in 0..<Int(seconds * 60) {
            sim.step(dt: 1.0 / 60, pointer: pointer)
            every?(sim)
        }
    }

    @Test func theRepertoireHasNoMoreLookalikesOfTheHints() {
        #expect(Set(Antic.allCases) == [.hop, .leafFlick, .yawn, .wiggle, .scratchLeaf, .catchSpeck])
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 5))
        var seen = Set<Antic>()
        run(sim, seconds: 900) { if let a = $0.currentAntic { seen.insert(a) } }
        #expect(seen == Set(Antic.allCases))
    }

    @Test func tirednessSagsTheBodyButKeepsTheEyesOpen() {
        let fresh = CharacterSim(metrics: m, rng: SeededRandom(seed: 2))
        let tired = CharacterSim(metrics: m, rng: SeededRandom(seed: 2))
        tired.fatigue = 1
        var maxOpen = 0.0, freshY = 0.0, tiredY = 0.0, n = 0.0
        for _ in 0..<(60 * 12) {
            fresh.step(dt: 1.0 / 60, pointer: nil)
            tired.step(dt: 1.0 / 60, pointer: nil)
            maxOpen = max(maxOpen, tired.pose.eyeOpen)
            freshY += fresh.pose.scaleY; tiredY += tired.pose.scaleY; n += 1
        }
        #expect(maxOpen > 0.97)                                       // the eyes belong to the eyes need now
        #expect(tired.pose.sag == 1)
        #expect(tiredY / n < freshY / n - 0.04)                       // lower…
        #expect(tired.pose.scaleX > fresh.pose.scaleX)                // …and wider
        #expect(tired.pose.eyeStrain == 0)
    }

    @Test func strainedEyesShrinkGraduallyAndRestBringsThemBackWithADoubleBlink() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 3))
        sim.eyeStrain = 1
        run(sim, seconds: 1)
        #expect(sim.pose.eyeStrain < 0.5)                             // not at once
        run(sim, seconds: 6)
        #expect(sim.pose.eyeStrain == 1)

        sim.eyeStrain = 0
        var closings = 0, wasClosed = false
        run(sim, seconds: 1.2) {
            let closed = $0.pose.eyeOpen < 0.15
            if closed && !wasClosed { closings += 1 }
            wasClosed = closed
        }
        #expect(closings >= 2)                                         // blink-blink
        #expect(sim.pose.eyeStrain == 0)
    }

    @Test func theStretchHintHopsAroundNearTheEdgeWithAStraightFaceThenGoesBack() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 4))
        run(sim, seconds: 1)
        sim.perform(.hops)
        var xs: [Double] = [], takeoffs = 0, wasUp = false, focused = true, through = true
        run(sim, seconds: Act.hops.duration - 0.6) {
            xs.append($0.pose.x)
            let up = $0.pose.hop < -25
            if up && !wasUp { takeoffs += 1 }
            wasUp = up
            focused = focused && $0.pose.mood.focused && !$0.pose.mood.cheering
            through = through && $0.pose.passThrough
        }
        #expect((5...6).contains(takeoffs))
        #expect(xs.max()! - xs.min()! > 80)                           // all over the place, not on the spot
        #expect(xs.min()! >= m.width - 235)                          // the ~300 pt zone at the edge
        #expect(focused && through)
        run(sim, seconds: 3)
        #expect(sim.act == nil && !sim.pose.passThrough)
        #expect(abs(sim.pose.x - m.dockX) < 3)
    }

    @Test func betweenTheHopsHeStaysWhereHeLanded() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 4))
        run(sim, seconds: 1)
        sim.perform(.hops)
        run(sim, seconds: 0.56)                                       // the first hop has landed
        let landed = sim.pose.x
        #expect(abs(landed - m.dockX) > 30)
        run(sim, seconds: 0.08)                                       // still on the ground before the next one
        #expect(abs(sim.pose.x - landed) < 2)
        #expect(sim.passesClicks)
    }

    @Test func cheeringJumpsOnTheSpotWithHandsUpAndConfetti() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 6))
        sim.standOut = .peek
        run(sim, seconds: 2)
        let x0 = sim.pose.x
        sim.perform(.cheer)
        var takeoffs = 0, wasUp = false, handsUp = false, spun = false, confetti = false, drift = 0.0
        run(sim, seconds: Act.cheer.duration) {
            let p = $0.pose
            let up = p.hop < -25
            if up && !wasUp { takeoffs += 1 }
            wasUp = up
            // Both arms out of his sides and pointing up (angle 0 = straight up): ＼(^o^)／, not ears on top.
            if p.mood.cheering, p.hands.count == 2, p.hands.allSatisfy({ $0.arm && abs($0.angle) < 1.3 && $0.y > -0.6 }) { handsUp = true }
            if abs(p.leafSpin) > .pi { spun = true }
            if p.confettiAge != nil { confetti = true }
            drift = max(drift, abs(p.x - x0))
        }
        #expect((2...3).contains(takeoffs))
        #expect(handsUp && spun && confetti)
        #expect(drift < 4)                                            // vertical, on the spot
        run(sim, seconds: 2)
        #expect(sim.pose.confettiAge == nil && sim.pose.hands.isEmpty && !sim.pose.mood.cheering)
    }

    @Test func scratchingTheLeafRaisesAHandToTheStem() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 8))
        sim.startAntic(.scratchLeaf)
        var atStem = false
        run(sim, seconds: Antic.scratchLeaf.duration) {
            if let h = $0.pose.hands.first, h.y < -0.75, abs(h.x) < 0.45 { atStem = true }
        }
        #expect(atStem)
        run(sim, seconds: 0.5)
        #expect(sim.pose.hands.isEmpty)
    }

    @Test func aSpeckFloatsInHeWatchesItCatchesItAndChews() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 9))
        sim.startAntic(.catchSpeck)
        var seenSpeck = false, watched = false, chewed = false, gone = false
        run(sim, seconds: Antic.catchSpeck.duration + 0.2) {
            let p = $0.pose
            if let s = p.speck {
                seenSpeck = true
                let c = $0.bodyCenter
                if (Double(s.x) - Double(c.x)) * p.lookX > 0 { watched = true }   // the eyes go where the speck is
            } else if seenSpeck { gone = true }
            if p.mood.chewing { chewed = true }
        }
        #expect(seenSpeck && watched && gone && chewed)
        #expect(sim.pose.speck == nil)
    }
}
