import Foundation
import Testing
@testable import ChilkCore

// Slice 6f-2 (SPEC 24–25): music and the disco.

struct MusicAppsTests {
    @Test func knownPlayersAndMarkedAppsAreMusicBrowsersAreNot() {
        #expect(MusicApps.isMusic("com.spotify.client", marked: []))
        #expect(MusicApps.isMusic("com.spotify.client.helper", marked: []))
        #expect(MusicApps.isMusic("com.apple.Music", marked: []))
        #expect(MusicApps.isMusic("ru.yandex.desktop.music", marked: []))
        #expect(!MusicApps.isMusic("com.google.Chrome", marked: []))
        #expect(!MusicApps.isMusic("com.apple.MusicRecognition", marked: []))   // a prefix of letters is not enough
        #expect(MusicApps.isMusic("com.google.Chrome", marked: ["com.google.Chrome"]))
        #expect(MusicApps.isMusic("com.google.Chrome.helper.Renderer", marked: ["com.google.Chrome"]))
    }

    @Test func theMusicMarkIsSavedFieldByField() throws {
        var rules = AppRules()
        rules.setMusic("com.google.Chrome", true)
        let back = try JSONDecoder().decode(AppRules.self, from: JSONEncoder().encode(rules))
        #expect(back.music == ["com.google.Chrome"])
        let old = try JSONDecoder().decode(AppRules.self, from: Data(#"{"overrides":{},"recent":[]}"#.utf8))
        #expect(old.music.isEmpty)
    }
}

struct DiscoTests {
    func run(_ d: inout Disco, seconds: Int, from t0: Double = 0, music: Bool = true, free: Bool = true,
             roll: Double) -> [Double] {
        var at: [Double] = []
        for s in 0..<seconds {
            let now = t0 + Double(s + 1)
            if d.tick(seconds: 1, music: music, free: free, now: now, roll: { roll }) { at.append(now) }
        }
        return at
    }

    @Test func afterThirtySecondsOfMusicALuckyRollDances() {
        var d = Disco()
        #expect(run(&d, seconds: 29, roll: 0.1).isEmpty)
        #expect(run(&d, seconds: 1, from: 29, roll: 0.1) == [30])
    }

    @Test func anUnluckyRollTriesAgainAfterTwentyMinutesAndDancesAtMostHourly() {
        var d = Disco()
        #expect(run(&d, seconds: 30, roll: 0.9).isEmpty)
        #expect(run(&d, seconds: 1199, from: 30, roll: 0.1).isEmpty)      // the next roll only at 30 + 1200
        #expect(run(&d, seconds: 1, from: 1229, roll: 0.1) == [1230])
        #expect(run(&d, seconds: 3500, from: 1230, roll: 0.1).isEmpty)  // 20 min later — but not within the hour
        #expect(run(&d, seconds: 100, from: 4730, roll: 0.1) == [4830])  // an hour after the dance
    }

    @Test func busyTheRollWaitsAndAPauseEndsTheMusic() {
        var d = Disco()
        #expect(run(&d, seconds: 40, free: false, roll: 0.1).isEmpty)
        #expect(run(&d, seconds: 1, from: 40, roll: 0.1) == [41])
        var e = Disco()
        _ = run(&e, seconds: 25, roll: 0.1)
        _ = run(&e, seconds: 2, from: 25, music: false, roll: 0.1)        // a track change: the music goes on
        #expect(run(&e, seconds: 5, from: 27, roll: 0.1) == [32])       // 30 s of music, the 2 s gap not counted
        var f = Disco()
        _ = run(&f, seconds: 25, roll: 0.1)
        _ = run(&f, seconds: 4, from: 25, music: false, roll: 0.1)        // stopped: start over
        #expect(run(&f, seconds: 29, from: 29, roll: 0.1).isEmpty)
    }
}

@MainActor
struct DanceCharacterTests {
    @Test func heDancesAtTheEdgeWithoutJumpingArmsInTurnAndBowsAtTheEnd() {
        let m = Metrics.standard
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 81))
        for _ in 0..<60 { sim.step(dt: 1.0 / 60, pointer: nil) }
        sim.perform(.dance(seconds: 20))
        var maxHop = 0.0, leftUp = 0, rightUp = 0, spun = false, minX = 999.0, bowed = false
        for i in 0..<(20 * 60) {
            sim.step(dt: 1.0 / 60, pointer: nil)
            let p = sim.pose
            maxHop = max(maxHop, -p.hop)
            minX = min(minX, sim.positionX)
            if let h = p.hands.first(where: { $0.arm }) { if h.x < 0 { leftUp += 1 } else { rightUp += 1 } }
            if p.scaleX < 0.5 { spun = true }
            if Double(i) / 60 > 19, p.tilt < -0.25 { bowed = true }
        }
        #expect(maxHop < 8)                                              // no jumps
        #expect(leftUp > 60 && rightUp > 60)                             // the arms take turns
        #expect(spun && bowed)
        #expect(minX > m.peekX - 6)                                      // out to «выглядывает», no further
        #expect(sim.act == nil)
    }
}
