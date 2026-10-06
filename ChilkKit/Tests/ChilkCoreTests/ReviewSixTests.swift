import Foundation
import Testing
@testable import ChilkCore

// Fixes after the slice 6 review (2026-10-06).

struct ReviewSixCoreTests {
    @Test func datesAndOrdinalsAreNotOpenHours() {
        #expect(ClockWords.ambiguousHours(in: "сделай до 10 октября").isEmpty)
        #expect(ClockWords.ambiguousHours(in: "к 5 ноября подготовь отчёт").isEmpty)
        #expect(ClockWords.ambiguousHours(in: "напомни к 8-му числу").isEmpty)
        #expect(ClockWords.ambiguousHours(in: "напомни в 8") == [8])
    }

    @Test func theQuestionBackNamesTheMorningNotTheNight() {
        #expect(ClockWords.askBack(hour: 3) == "В 3 ночи или в 15:00?")
        #expect(ClockWords.askBack(hour: 8) == "В 8 утра или в 20:00?")
        #expect(ClockWords.askBack(hour: 12) == "В 12 дня или в 00:00?")
    }

    @Test func answeringTheDateQuestionDropsTheDayNote() {
        var cal = Calendar(identifier: .gregorian)
        let zone = TimeZone(identifier: "Europe/Moscow")!
        cal.timeZone = zone
        let night = cal.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 1))!
        #expect(ClockWords.hint(for: "завтра в 9 утра", now: night, zone: zone) != nil)
        #expect(ClockWords.hint(for: "завтра, после сна", now: night, zone: zone, dayOpen: false) == nil)
    }

    @Test func anUnluckyRollWaitsTwentyMinutesEvenAcrossAPause() {
        var d = Disco()
        var danced: [Double] = []
        func play(_ from: Int, _ to: Int, music: Bool) {
            for s in from..<to where d.tick(seconds: 1, music: music, free: true, now: Double(s + 1), roll: { 0.9 }) {
                danced.append(Double(s + 1))
            }
        }
        play(0, 30, music: true)                                   // the roll at 30 s: unlucky
        play(30, 40, music: false)                                 // a pause: the music starts over
        var rolls = 0
        for s in 40..<1229 { _ = d.tick(seconds: 1, music: true, free: true, now: Double(s + 1), roll: { rolls += 1; return 0.9 }) }
        #expect(rolls == 0)                                        // not again after 30 s of the new music
        _ = d.tick(seconds: 1, music: true, free: true, now: 1230, roll: { rolls += 1; return 0.9 })
        #expect(rolls == 1 && danced.isEmpty)
        #expect(!d.resting(now: 1230))
    }

    @Test func aPairThatNeverWentToCodexStaysInThePickedChat() {
        var log = ChatLog()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let a = log.record(question: "привет", answer: "привет!", via: .text, chips: [], thread: "t-a", continuing: nil, at: now)
        let b = log.record(question: "как дела", answer: "норм", via: .text, chips: [], thread: "t-b", continuing: nil, at: now)
        // The live thread is B's, the user picked A: the refusal goes into A, and no thread is mapped to it.
        let id = log.recordLocal(question: "ты тут?", answer: "Помоги мне…", via: .text, continuing: a,
                                 at: now.addingTimeInterval(5))
        #expect(id == a && id != b)
        #expect(log.session(a)?.turns.count == 4 && log.session(b)?.turns.count == 2)
        let fresh = log.recordLocal(question: "эй", answer: "Помоги мне…", via: .text, continuing: nil, at: now)
        #expect(fresh != a && fresh != b && log.session(fresh)?.turns.count == 2)
    }
}

@MainActor
struct ReviewSixCharacterTests {
    @Test func theHatTakesTheNightcapOff() {
        let sim = CharacterSim(metrics: .standard, rng: SeededRandom(seed: 5))
        sim.putOnNightcap()
        sim.wear(.hat)
        #expect(sim.props.contains(.hat) && !sim.props.contains(.nightcap))
    }

    @Test func theStretchIntroHopsTakeClicks() {
        let sim = CharacterSim(metrics: .standard, rng: SeededRandom(seed: 5))
        sim.perform(.hops)
        #expect(sim.passesClicks)
        sim.hopsTakeClicks = true
        #expect(!sim.passesClicks)
    }
}
