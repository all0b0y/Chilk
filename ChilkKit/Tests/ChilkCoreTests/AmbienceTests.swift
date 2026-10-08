import Foundation
import Testing
@testable import ChilkCore

// Slice 6f-1 (SPEC 22–23): the built-in display's brightness — a nightcap and sleep, a lamp, sunglasses.
// Slice 9a (SPEC «Срез 9», decision 6): the ends always react, a quarter chance between, once in 10 min.

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
    // Slice 9, decision 6: the ends always react, a quarter chance in between, nothing around the middle.
    @Test func theEndsAlwaysReactTheMiddleNeverAndAQuarterInBetween() {
        for level in [0.0, 0.05, 0.2, 0.85, 0.9, 1.0] { #expect(Ambience.chance(level: level) == 1, "\(level)") }
        for level in [0.21, 0.3, 0.4, 0.6, 0.7, 0.84] { #expect(Ambience.chance(level: level) == 0.25, "\(level)") }
        for level in [0.41, 0.46, 0.5, 0.54, 0.59] { #expect(Ambience.chance(level: level) == 0, "\(level)") }
    }

    @Test func atTheEndsTheLookComesWhateverTheRoll() {
        #expect(Ambience.pick(level: 0.1, roll: 0.999, coin: 0.2, eyesPressure: 0) == .nightcap)
        #expect(Ambience.pick(level: 0.9, roll: 0.999, coin: 0.2, eyesPressure: 0) == .sunglasses)
        #expect(Ambience.pick(level: 0.3, roll: 0.3, coin: 0.2, eyesPressure: 0) == nil)            // a quarter missed
        #expect(Ambience.pick(level: 0.3, roll: 0.2, coin: 0.7, eyesPressure: 0) == .lamp)
        #expect(Ambience.pick(level: 0.5, roll: 0, coin: 0.2, eyesPressure: 0) == nil)
    }

    @Test func aSceneComesAtMostOnceInTenMinutesAndAMissStartsNoPause() {
        var gate = AmbienceCooldown()
        #expect(gate.ready(now: 0))
        gate.played(now: 100)
        #expect(!gate.ready(now: 100))
        #expect(!gate.ready(now: 100 + 599))
        #expect(gate.ready(now: 100 + 600))
        #expect(AmbienceCooldown.pause == 600)
    }

    @Test func darkIsANightcapOrALampBrightIsSunglassesUnlessTheEyesAreTired() {
        #expect(Ambience.pick(level: 0.05, roll: 0.05, coin: 0.2, eyesPressure: 0) == .nightcap)
        #expect(Ambience.pick(level: 0.05, roll: 0.05, coin: 0.7, eyesPressure: 0) == .lamp)
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
