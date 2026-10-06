import Foundation
import Testing
@testable import ChilkCore

// Slice 6f-1 (SPEC 22–23): the built-in display's brightness — a nightcap and sleep, a lamp, sunglasses.

struct BrightnessWatchTests {
    @Test func theFirstReadingIsOnlyThePlace() {
        var w = BrightnessWatch()
        #expect(w.feed(0.46, now: 0) == nil)
        for t in stride(from: 0.5, through: 5, by: 0.5) { #expect(w.feed(0.46, now: t) == nil) }
    }

    @Test func aNewPlaceCountsOnceAfterOneAndAHalfStillSeconds() {
        var w = BrightnessWatch()
        _ = w.feed(0.46, now: 0)
        #expect(w.feed(0.40, now: 1) == nil)              // a step down — still moving
        #expect(w.feed(0.33, now: 1.4) == nil)
        #expect(w.feed(0.33, now: 2.5) == nil)            // still 1.1 s
        #expect(w.feed(0.331, now: 2.9) == 0.331)         // 1.5 s still (within ±0.003): settled
        #expect(w.feed(0.331, now: 4) == nil)             // once
    }

    @Test func aSmallDriftIsNotANewPlace() {
        var w = BrightnessWatch()
        _ = w.feed(0.46, now: 0)
        #expect(w.feed(0.42, now: 1) == nil)
        for t in stride(from: 1.5, through: 6, by: 0.5) { #expect(w.feed(0.42, now: t) == nil) }   // 0.04 < 0.06
        #expect(w.feed(0.36, now: 7) == nil)
        #expect(w.feed(0.36, now: 8.6) == 0.36)           // 0.10 from the place
    }
}

struct AmbienceTests {
    @Test func theChanceGrowsGeometricallyTowardsTheEnds() {
        #expect(Ambience.chance(level: 0.5) == 0)
        #expect(Ambience.chance(level: 0.52) == 0)
        #expect(abs(Ambience.chance(level: 0.25) - 0.01) < 1e-9)
        #expect(abs(Ambience.chance(level: 0.75) - 0.01) < 1e-9)
        #expect(abs(Ambience.chance(level: 0) - 0.1) < 1e-9 && abs(Ambience.chance(level: 1) - 0.1) < 1e-9)
        #expect(Ambience.chance(level: 0.45) > 0.001 && Ambience.chance(level: 0.45) < 0.002)
    }

    @Test func darkIsANightcapOrALampBrightIsSunglassesUnlessTheEyesAreTired() {
        #expect(Ambience.pick(level: 0.05, roll: 0.05, coin: 0.2, eyesPressure: 0) == .nightcap)
        #expect(Ambience.pick(level: 0.05, roll: 0.05, coin: 0.7, eyesPressure: 0) == .lamp)
        #expect(Ambience.pick(level: 0.05, roll: 0.2, coin: 0.2, eyesPressure: 0) == nil)          // unlucky
        #expect(Ambience.pick(level: 0.95, roll: 0.05, coin: 0.2, eyesPressure: 0.3) == .sunglasses)
        #expect(Ambience.pick(level: 0.95, roll: 0.05, coin: 0.2, eyesPressure: 0.5) == nil)      // bags first
    }

    @Test func eachLookStaysOnlyWhileItFits() {
        #expect(Ambience.lamp.keeps(level: 0.3, eyesPressure: 0))
        #expect(!Ambience.lamp.keeps(level: 0.55, eyesPressure: 0))
        #expect(Ambience.sunglasses.keeps(level: 0.8, eyesPressure: 0.2))
        #expect(!Ambience.sunglasses.keeps(level: 0.45, eyesPressure: 0.2))
        #expect(!Ambience.sunglasses.keeps(level: 0.8, eyesPressure: 0.6))
        #expect(Ambience.nightcap.keeps(level: 0.4, eyesPressure: 0))
        #expect(!Ambience.nightcap.keeps(level: 0.6, eyesPressure: 0))   // brightness > 50 % wakes him
    }
}

@MainActor
struct AmbienceCharacterTests {
    @Test func theNightcapReplacesTheHatAndHeFallsAsleepInIt() {
        let sim = CharacterSim(metrics: .standard, rng: SeededRandom(seed: 71))
        sim.wear(.hat)
        sim.putOnNightcap()
        #expect(sim.props.contains(.nightcap) && !sim.props.contains(.hat))
        for _ in 0..<(60 * 4) { sim.step(dt: 1.0 / 60, pointer: nil) }
        #expect(sim.isAsleep)
        sim.wakeUp()
        sim.step(dt: 1.0 / 60, pointer: nil)
        #expect(!sim.props.contains(.nightcap))                          // awake — the cap comes off
    }
}
