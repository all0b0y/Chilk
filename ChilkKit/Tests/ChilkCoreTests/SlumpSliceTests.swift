import CoreGraphics
import Foundation
import Testing
@testable import ChilkCore

// Slice 6b (grilling 2026-10-06, decisions 7–10): «лежит».

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

/// Every body need is due after ~10 minutes of sitting; the engine is driven second by second like the app does.
@MainActor
private final class Desk {
    let engine: BalanceEngine
    var now = ISO8601DateFormatter().date(from: "2026-10-05T09:00:00Z")!
    var events: [BalanceEvent] = []

    init(off: Set<Need> = [], mode: BalanceMode? = nil, restoring: BalanceState? = nil, seed: UInt64 = 11) {
        var c = BalanceConfig()
        c.moodEvery = 600...601                          // mood would come every 10 min — it must not while he lies
        c.waterMinutes = 10...10.5; c.stretchMinutes = 10...10.5; c.eyesMinutes = 10...10.5; c.walkMinutes = 10...10.5
        c.weekdayBudget = 1e9; c.weekendBudget = 1e9
        c.needsOff = off.union([.endOfDay])
        engine = BalanceEngine(config: c, restoring: restoring, rng: SeededRandom(seed: seed), calendar: utc)
        if let mode { _ = try? engine.setMode(mode) }
        _ = engine.tick(Signals(now: now))
    }

    @discardableResult
    func work(minutes: Double, _ tweak: (inout Signals) -> Void = { _ in }) -> [BalanceEvent] {
        run(minutes, make: { i in Signals(now: self.now, idle: Double(i % 6), frontApp: "com.apple.dt.Xcode") }, tweak: tweak)
    }

    @discardableResult
    func away(minutes: Double) -> [BalanceEvent] {
        run(minutes, make: { i in Signals(now: self.now, idle: Double(i + 1), frontApp: "com.apple.dt.Xcode") }, tweak: { _ in })
    }

    private func run(_ minutes: Double, make: (Int) -> Signals, tweak: (inout Signals) -> Void) -> [BalanceEvent] {
        var got: [BalanceEvent] = []
        for i in 0..<Int((minutes * 60).rounded()) {
            now += 1
            var s = make(i)
            tweak(&s)
            got += engine.tick(s)
        }
        events += got
        return got
    }

    func workUntilSlumped(maxMinutes: Double = 60) {
        for _ in 0..<Int(maxMinutes * 60) where !engine.slumped { work(minutes: 1.0 / 60) }
    }
}

private extension BalanceEvent {
    var isAsk: Bool { if case .ask = self { true } else { false } }
    var askStage: Int? { if case .ask(_, let s, _, _) = self { s } else { nil } }
}

@Suite("6b: «лежит» — the engine")
@MainActor
struct SlumpEngineTests {

    @Test func heLiesDownOnceEveryBodyNeedIsEmpty() {
        let d = Desk()
        d.work(minutes: 9)
        #expect(!d.engine.slumped)
        d.workUntilSlumped()
        #expect(d.engine.slumped)
        #expect(d.events.filter { $0 == .slumped }.count == 1)
        #expect(Need.body.allSatisfy { d.engine.pressure($0) >= 1 })
    }

    @Test func oneNeedLeftOnIsNotEnough() {
        let d = Desk(off: [.water, .eyes, .walk])
        d.work(minutes: 60)
        #expect(!d.engine.slumped)
        #expect(!d.events.contains(.slumped))

        let two = Desk(off: [.eyes, .walk])                 // two are enough
        two.workUntilSlumped()
        #expect(two.engine.slumped)
    }

    @Test func softPausesTheLadderAndTheMoodWhileHeLies() {
        let d = Desk()
        d.workUntilSlumped()
        let stage = d.engine.state.episode?.stage
        let later = d.work(minutes: 30)
        #expect(!later.contains { $0.isAsk || $0 == .nudge || $0 == .mood })
        #expect(d.engine.state.episode?.stage == stage)
        #expect(d.engine.slumped)
    }

    @Test func strictKeepsClimbingToTheShadeUnderHim() {
        let d = Desk(mode: .strict)
        d.workUntilSlumped()
        d.work(minutes: 40)
        #expect(d.engine.slumped)
        #expect((d.engine.state.episode?.stage ?? 0) >= 3)
        #expect(d.events.contains { ($0.askStage ?? 0) >= 3 })
    }

    @Test func aGlassOfWaterGetsHimUp() {
        let d = Desk()
        d.workUntilSlumped()
        _ = d.engine.tookRest(.water)
        #expect(d.engine.updateSlump() == [.roseUp])
        #expect(!d.engine.slumped)
        #expect(!d.engine.refusesToTalk)
    }

    @Test func threeMinutesAwayGetsHimUp() {
        let d = Desk()
        d.workUntilSlumped()
        #expect(d.away(minutes: 3.2).contains(.roseUp))
        #expect(!d.engine.slumped)
    }

    @Test func shakingUpGetsHimUpWithoutCreditAndHeLiesAgainOnlyAfterARest() {
        let d = Desk()
        d.workUntilSlumped()
        let stretch = d.engine.pressure(.stretch)
        #expect(d.engine.shakeUp() == [.roseUp])
        #expect(!d.engine.slumped)
        #expect(d.engine.pressure(.stretch) >= stretch)           // the warm-up need is not credited
        #expect(d.engine.shakeUp().isEmpty)
        #expect(!d.work(minutes: 15).contains(.slumped))          // still empty, but he stays up

        _ = d.engine.tookRest(.water)                             // a rest re-arms him…
        d.work(minutes: 1)
        #expect(!d.engine.slumped)
        d.workUntilSlumped()                                     // …and he lies down when everything is empty again
        #expect(d.engine.slumped)
    }

    @Test func aCallHidesTheBubbleButNotThePose() {
        let d = Desk()
        d.workUntilSlumped()
        #expect(d.work(minutes: 1) { $0.inCall = true } == [.withdraw])
        #expect(d.engine.slumped)
        #expect(d.work(minutes: 1.0 / 60).contains(.slumped))
    }

    @Test func heRefusesToTalkExceptInSilence() throws {
        let d = Desk()
        d.workUntilSlumped()
        #expect(d.engine.refusesToTalk)
        _ = try d.engine.setMode(.silent)
        #expect(d.engine.slumped && !d.engine.refusesToTalk)

        let quiet = Desk(mode: .silent)
        quiet.workUntilSlumped()
        #expect(quiet.engine.slumped && !quiet.engine.refusesToTalk)
    }

    @Test func shakenUpSurvivesARestartAndOldFilesStartArmed() throws {
        let d = Desk()
        d.workUntilSlumped()
        _ = d.engine.shakeUp()
        let saved = try JSONDecoder().decode(BalanceState.self, from: JSONEncoder().encode(d.engine.state))
        #expect(saved.slumpArmed == false)
        let again = Desk(restoring: saved)
        #expect(!again.work(minutes: 2).contains(.slumped))

        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(d.engine.state)) as! [String: Any]
        json["slumpArmed"] = nil
        let old = try JSONDecoder().decode(BalanceState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.slumpArmed)
    }

    @Test func aPantomimeLeftByAnOlderBuildBecomesABubbleAtLaunch() throws {
        let d = Desk(mode: .silent)
        d.work(minutes: 11)
        #expect(d.engine.state.episode?.stage == 0)
        var state = d.engine.state
        state.mode = .strict
        let restored = Desk(restoring: state)
        #expect(restored.engine.state.episode?.stage == 1)
    }

    @Test func theCheckMenuLaysHimDown() {
        let d = Desk()
        d.work(minutes: 1)
        d.engine.makeSlumped()
        #expect(d.engine.slumped)
        #expect(d.work(minutes: 1.0 / 60).contains(.slumped))
    }
}

@Suite("6b: «лежит» — the character")
@MainActor
struct SlumpCharacterTests {
    let m = Metrics.standard

    func run(_ sim: CharacterSim, seconds: Double, pointer: CGPoint? = nil, every: ((CharacterSim) -> Void)? = nil) {
        for _ in 0..<Int(seconds * 60) {
            sim.step(dt: 1.0 / 60, pointer: pointer)
            every?(sim)
        }
    }

    @Test func heStandsExhaustedAtTheEdgeAndStraightensUpSlowly() {
        // Acceptance 2026-10-06 (decision 8, variant A): «измотан» instead of lying — no flip on his side.
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 21))
        run(sim, seconds: 1)
        let standing = sim.bodyCenter
        sim.slumped = true
        run(sim, seconds: 1.5)
        #expect(sim.pose.exhausted > 0.99 && sim.pose.mood.slumped)
        #expect(sim.pose.lying == 0 && sim.pose.roll == 0)            // standing, not turned
        let c = sim.bodyCenter
        #expect(abs(Double(c.x) - Double(standing.x)) < 8)            // at his place by the edge
        #expect(sim.contains(c))
        var antics = 0, maxOpen = 0.0, minTilt = 9.0, maxTilt = -9.0
        run(sim, seconds: 60) {
            if $0.currentAntic != nil { antics += 1 }
            maxOpen = max(maxOpen, $0.pose.eyeOpen)
            minTilt = min(minTilt, $0.pose.tilt); maxTilt = max(maxTilt, $0.pose.tilt)
        }
        #expect(antics == 0)
        #expect(maxOpen < 0.6)                                       // half-closed eyes (plain fatigue keeps them open)
        #expect(maxTilt - minTilt > 0.08)                            // a slow sway

        sim.slumped = false
        run(sim, seconds: 0.6)
        #expect(sim.pose.exhausted > 0.25 && sim.pose.exhausted < 0.9)   // slowly, not at once
        run(sim, seconds: 2)
        #expect(sim.pose.exhausted == 0 && !sim.pose.mood.slumped)
    }

    @Test func theWordsBubbleTakesItsTimeAndTheEmotionKnowsItsLength() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 2))
        #expect(abs(CharacterSim.revealTime("Ха") - 0.65) < 1e-9)
        #expect(abs(CharacterSim.revealTime("раз два три четыре") - 0.89) < 1e-9)
        sim.say("раз два три четыре", duration: 10)
        #expect(abs(sim.bubbleRevealLeft - 0.89) < 1e-6)
        run(sim, seconds: 0.5)
        #expect(sim.bubbleRevealLeft > 0.3 && sim.bubbleRevealLeft < 0.45)
        run(sim, seconds: 1)
        #expect(sim.bubbleRevealLeft == 0)
        #expect(CharacterSim.emotionAct(.laugh, strong: true) == .laugh(strong: true))
        #expect(CharacterSim.emotionAct(.offended, strong: false).duration > 1)
    }

    @Test func hoveringOverHimLyingDoesNotMakeHimHop() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 22))
        sim.slumped = true
        run(sim, seconds: 2)
        var minHop = 0.0
        run(sim, seconds: 1.5, pointer: sim.bodyCenter) { minHop = min(minHop, $0.pose.hop) }
        #expect(minHop > -6)
    }
}
