@testable import ChilkCore
import Testing

/// Acceptance 2026-10-06 («трясётся во сне и при пробуждении»): the breathing phase was `t · 2π / period` with the
/// period following sleep / fatigue / exhaustion. After an hour of running, a period change of a fraction of a second
/// turned `t / period` into hundreds of radians per second — 2.5 s of shaking while he falls asleep, 0.3 s on waking,
/// a twitch whenever fatigue moves. Sim tests started at t ≈ 0, where the same formula is harmless.
@MainActor
struct BreathingSmoothnessTests {
    private static let dt = 1.0 / 30

    /// He has been on screen for half an hour.
    private func runningFor(seconds: Double) -> CharacterSim {
        let sim = CharacterSim(metrics: .standard, rng: SeededRandom(seed: 9))
        for _ in 0..<Int(seconds / Self.dt) { sim.step(dt: Self.dt, pointer: nil) }
        return sim
    }

    /// Height changes of direction (breathing, squash) and the largest change from one frame to the next.
    private func watch(_ sim: CharacterSim, seconds: Double) -> (reversals: Int, maxStep: Double) {
        var values: [Double] = []
        for _ in 0..<Int(seconds / Self.dt) {
            sim.step(dt: Self.dt, pointer: nil)
            values.append(sim.pose.scaleY)
        }
        var reversals = 0, previous = 0.0, maxStep = 0.0
        for i in 1..<values.count {
            let d = values[i] - values[i - 1]
            maxStep = max(maxStep, abs(d))
            guard abs(d) > 1e-5 else { continue }
            if previous != 0, (d > 0) != (previous > 0) { reversals += 1 }
            previous = d
        }
        return (reversals, maxStep)
    }

    @Test func fallingAsleepAfterHalfAnHourBreathesSmoothly() {
        let sim = runningFor(seconds: 1800)
        sim.fallAsleep()
        let r = watch(sim, seconds: CharacterSim.fallAsleepDuration + 0.5)
        // One breath lasts ≥ 3.6 s: at most a couple of turns in 3 s, never a frame-by-frame shake.
        #expect(r.reversals <= 3, "\(r)")
        #expect(r.maxStep < 0.006, "\(r)")
    }

    @Test func wakingUpAfterHalfAnHourDoesNotShake() {
        let sim = runningFor(seconds: 1800)
        sim.fallAsleep()
        _ = watch(sim, seconds: 4)
        sim.wakeUp()
        let r = watch(sim, seconds: 1)
        // The wake-up hop squashes him once or twice; a shake would turn every frame.
        #expect(r.reversals <= 4, "\(r)")
    }

    @Test func aFatigueNudgeIsNotAJump() {
        let sim = runningFor(seconds: 1800)
        sim.fallAsleep()                                    // asleep: only breathing moves him, no antics
        _ = watch(sim, seconds: 4)
        var last = sim.pose.scaleY, worst = 0.0
        for frame in 0..<150 {
            if frame % 15 == 0 { sim.fatigue += 0.013 }     // the needs move fatigue in small steps
            sim.step(dt: Self.dt, pointer: nil)
            let now = sim.pose.scaleY
            worst = max(worst, abs(now - last))
            last = now
        }
        // Smooth breathing changes the height by ≤ 0.24 % a frame at 30 fps; a phase jump — by up to 7 %.
        #expect(worst < 0.004, "worst step after a nudge \(worst)")
    }
}
