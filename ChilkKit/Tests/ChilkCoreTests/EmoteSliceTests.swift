import CoreGraphics
import Foundation
import Testing
@testable import ChilkCore

// Slice 6c (grilling 2026-10-06, decisions 11–16): emotions from Codex and petting.

private let t0 = ISO8601DateFormatter().date(from: "2026-10-06T12:00:00Z")!
private let day = 24 * 3600.0

struct EmoteGateTests {
    @Test func oneCallPerAnswerAndARefusalStillUsesIt() {
        var g = EmoteGate()
        #expect(g.request(.laugh, turn: "t1", now: t0, stageFree: true) == .play)
        #expect(g.request(.cheer, turn: "t1", now: t0, stageFree: true) == .onePerAnswer)
        #expect(g.request(.cheer, turn: "t2", now: t0, stageFree: true) == .play)
        // Busy: nothing plays, but the turn's try is spent — no second emotion in the same answer.
        #expect(g.request(.sad, turn: "t3", now: t0, stageFree: false) == .busy)
        #expect(g.request(.sad, turn: "t3", now: t0, stageFree: true) == .onePerAnswer)
    }

    @Test func theClownRestsFourteenDaysWithoutASubstitute() {
        var g = EmoteGate()
        #expect(g.request(.clown, turn: "a", now: t0, stageFree: true) == .play)
        #expect(g.book.clownAt == t0)
        let rest = g.request(.clown, turn: "b", now: t0 + 13 * day, stageFree: true)
        #expect(rest == .clownResting(until: t0 + 14 * day))
        // «без замены»: the refused clown used the answer's only call.
        #expect(g.request(.laugh, turn: "b", now: t0 + 13 * day, stageFree: true) == .onePerAnswer)
        #expect(g.request(.clown, turn: "c", now: t0 + 14 * day + 1, stageFree: true) == .play)
    }

    @Test func aBusyChilkDoesNotSpendTheClown() {
        var g = EmoteGate()
        #expect(g.request(.clown, turn: "a", now: t0, stageFree: false) == .busy)
        #expect(g.book.clownAt == nil)
        #expect(g.request(.clown, turn: "b", now: t0, stageFree: true) == .play)
    }

    @Test func theClownDateSurvivesARestart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("emote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("emotes.json")
        #expect(EmoteBook.load(from: url) == EmoteBook())          // no file yet: never played
        var g = EmoteGate()
        _ = g.request(.clown, turn: "a", now: t0, stageFree: true)
        try g.book.save(to: url)
        var again = EmoteGate(book: EmoteBook.load(from: url))
        #expect(again.request(.clown, turn: "b", now: t0 + day, stageFree: true) == .clownResting(until: t0 + 14 * day))
        try Data("{broken".utf8).write(to: url)
        #expect(EmoteBook.load(from: url) == EmoteBook())          // damaged: the clown is allowed, nothing crashes
    }

    @Test func onlyTheSixEmotionsExistAndNoneIsANeedSignal() {
        #expect(Set(Emotion.allCases.map(\.rawValue)) == ["cheer", "laugh", "clown", "offended", "dizzy", "sad"])
    }
}

@MainActor
struct EmoteCharacterTests {
    let m = Metrics.standard

    func run(_ sim: CharacterSim, seconds: Double, pointer: CGPoint? = nil, every: ((CharacterSim) -> Void)? = nil) {
        for _ in 0..<Int(seconds * 60) {
            sim.step(dt: 1.0 / 60, pointer: pointer)
            every?(sim)
        }
    }

    func fresh(_ seed: UInt64 = 31) -> CharacterSim {
        let s = CharacterSim(metrics: m, rng: SeededRandom(seed: seed))
        run(s, seconds: 1)
        return s
    }

    @Test func eachEmotionPlaysOnceForItsTimeAndEnds() {
        for e in Emotion.allCases {
            for strong in [false, true] where strong == false || e == .laugh {
                let sim = fresh()
                sim.emote(e, strong: strong)
                #expect(sim.isEmoting)
                let length = sim.act?.duration ?? 0
                #expect(length >= 2 && length <= 4, "\(e) strong=\(strong): \(length) s")
                run(sim, seconds: length + 0.1)
                #expect(!sim.isEmoting && sim.act == nil, "\(e) still playing")
            }
        }
    }

    @Test func heComesOutFromBehindTheEdgeToShowIt() {
        let sim = fresh()
        #expect(sim.positionX > m.peekX + 20)                       // docked: mostly behind the edge
        sim.emote(.offended, strong: false)
        run(sim, seconds: 1)
        #expect(sim.positionX <= m.peekX + 2)
        run(sim, seconds: 3)
        #expect(sim.positionX > m.peekX + 20)                       // and back
    }

    @Test func laughingHasHappyEyesTearsAndHaHaHaFromTheEdge() {
        let sim = fresh()
        sim.emote(.laugh, strong: false)
        var tears = false, ha = false, slapped = false, lyingFlat = false
        run(sim, seconds: 2) {
            let p = $0.pose
            #expect(p.mood.laughing)
            if p.tearAge != nil { tears = true }
            if p.haAge != nil { ha = true }
            if p.hands.contains(where: { $0.x > 0.6 }) { slapped = true }     // the hand on the edge side
            if abs(p.roll) > 0.3 { lyingFlat = true }
        }
        #expect(tears && ha && slapped)
        #expect(!lyingFlat)                                         // a plain laugh never falls over
    }

    @Test func aStrongLaughFallsOnHisBackKicksAndGetsUp() {
        let sim = fresh()
        sim.emote(.laugh, strong: true)
        var maxRoll = 0.0, kicked = false
        run(sim, seconds: 2) {
            maxRoll = max(maxRoll, $0.pose.roll)
            if $0.pose.feet != nil { kicked = true }
        }
        // On his BACK, towards the edge — «лежит» turns him the other way (head into the screen), with a frown.
        #expect(maxRoll > 1.1)
        #expect(kicked)
        #expect(sim.pose.lying == 0 && !sim.pose.mood.slumped)
        // The fall fits on the screen: the body stays left of the edge.
        let c = sim.bodyCenter
        #expect(Double(c.x) + m.radiusY < m.width)
        run(sim, seconds: 2)
        #expect(abs(sim.pose.roll) < 0.02 && sim.pose.feet == nil)
    }

    @Test func theClownPutsOnANoseAndAWigKeepsAStoneFaceAndTakesThemOff() {
        let sim = fresh()
        sim.emote(.clown, strong: false)
        var nose = 0.0, wig = 0.0, stone = 0.0, smiled = false
        run(sim, seconds: 3.6) {
            let p = $0.pose
            nose = max(nose, p.clownNose)
            wig = max(wig, p.clownWig)
            if p.mood.deadpan { stone += 1.0 / 60 }
            if p.mood.laughing || p.mood.cheering { smiled = true }
        }
        #expect(nose > 0.99 && wig > 0.99)
        #expect(stone > 1.3 && stone < 1.8)                         // ~1.5 s of a stone face
        #expect(!smiled)
        #expect(sim.pose.clownNose == 0 && sim.pose.clownWig == 0)
    }

    @Test func offendedSadAndDizzyUseTheExistingFaces() {
        let sim = fresh()
        sim.emote(.dizzy, strong: false)
        run(sim, seconds: 0.5)
        #expect(sim.pose.mood.dizzy)
        run(sim, seconds: 3)
        sim.emote(.sad, strong: false)
        run(sim, seconds: 0.5)
        #expect(sim.pose.mood.sad)
        run(sim, seconds: 3)
        #expect(!sim.pose.mood.sad)
        sim.emote(.offended, strong: false)
        run(sim, seconds: 0.3)
        #expect(sim.pose.mood.annoyed)                              // «><», «хмф»
        run(sim, seconds: 1)
        #expect(sim.pose.mood.sulking && sim.pose.lookX > 0.5)      // then turned away, towards the edge
    }

    // MARK: Petting (backlog item 2, decision 16)

    /// The cursor comes onto him (where the first stroke starts) and rests until he has hopped out from the edge.
    func hover(_ sim: CharacterSim, dx: Double = 20, dy: Double = 0) {
        for _ in 0..<72 {
            let c = sim.bodyCenter
            sim.step(dt: 1.0 / 60, pointer: CGPoint(x: c.x + dx, y: c.y + dy))
        }
    }

    /// Strokes the cursor across his body (relative to it, like a hand following him): `strokes` sweeps of `travel`
    /// points, one every `period` s; `first` continues the alternation of an earlier call.
    func stroke(_ sim: CharacterSim, strokes: Int, travel: Double = 40, period: Double = 0.35, vertical: Bool = false,
                first: Int = 0) {
        let steps = Int(period * 60)
        for s in first..<(first + strokes) {
            for i in 1...steps {
                let u = Double(i) / Double(steps)
                let d = (s % 2 == 0 ? -1.0 : 1.0) * (u - 0.5) * travel
                let c = sim.bodyCenter
                let p = vertical ? CGPoint(x: c.x, y: c.y + d) : CGPoint(x: c.x + d, y: c.y)
                sim.step(dt: 1.0 / 60, pointer: p)
            }
        }
    }

    @Test func threeTurnsWithinASecondAndAHalfIsPetting() {
        let sim = fresh()
        hover(sim)
        stroke(sim, strokes: 3, period: 0.4)                       // two turns of direction only
        #expect(!sim.pose.mood.petted)
        stroke(sim, strokes: 2, period: 0.4, first: 3)             // keeps going: three turns inside 1.5 s
        #expect(sim.pose.mood.petted)
        let p = sim.pose
        #expect(p.blushHot > 0.5)                                   // brighter blush
    }

    @Test func slowCursorMovesAreNotPetting() {
        let sim = fresh()
        hover(sim)
        stroke(sim, strokes: 6, period: 1.2)                       // one sweep per 1.2 s: never 3 turns in 1.5 s
        #expect(!sim.pose.mood.petted)
        let small = fresh(32)
        hover(small)
        stroke(small, strokes: 8, travel: 6, period: 0.2)          // jitter, not strokes
        #expect(!small.pose.mood.petted)
    }

    @Test func upAndDownStrokesCountToo() {
        let sim = fresh()
        hover(sim, dx: 0, dy: 17)
        stroke(sim, strokes: 6, travel: 34, period: 0.3, vertical: true)
        #expect(sim.pose.mood.petted)
    }

    @Test func whenThePettingStopsHeWinks() {
        let sim = fresh()
        hover(sim)
        stroke(sim, strokes: 8, period: 0.3)
        #expect(sim.pose.mood.petted)
        var winked = false
        for _ in 0..<120 {
            let c = sim.bodyCenter                                   // the hand rests where the last stroke ended
            sim.step(dt: 1.0 / 60, pointer: CGPoint(x: c.x + 20, y: c.y))
            if sim.pose.mood.winking { winked = true }
        }
        #expect(winked)
        #expect(!sim.pose.mood.petted && !sim.pose.mood.winking)
        #expect(sim.pose.blushHot < 0.1)
    }

    @Test func noPettingAsleepLyingOrDuringAScene() {
        let asleep = fresh()
        asleep.fallAsleep()
        run(asleep, seconds: 3)
        hover(asleep)
        stroke(asleep, strokes: 8, period: 0.3)
        #expect(!asleep.pose.mood.petted)

        let lying = fresh()
        lying.slumped = true
        run(lying, seconds: 2)
        hover(lying)
        stroke(lying, strokes: 8, period: 0.3)
        #expect(!lying.pose.mood.petted)

        let laughing = fresh()
        laughing.emote(.laugh, strong: false)
        stroke(laughing, strokes: 6, period: 0.3)
        #expect(!laughing.pose.mood.petted)
    }
}
