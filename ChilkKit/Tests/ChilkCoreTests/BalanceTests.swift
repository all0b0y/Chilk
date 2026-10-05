import Foundation
import Testing
@testable import ChilkCore

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
private let monday9 = date("2026-10-05T09:00:00Z")

/// Drives the engine second by second, like the app does.
@MainActor
private final class Day {
    let engine: BalanceEngine
    var now: Date
    var elapsed: TimeInterval = 0
    var timeline: [(t: TimeInterval, e: BalanceEvent)] = []

    init(start: Date = monday9, seed: UInt64 = 7, _ configure: (inout BalanceConfig) -> Void = { _ in }) {
        var c = BalanceConfig()
        c.moodEvery = 1e8...(1e8 + 1)          // mood has its own test
        configure(&c)
        engine = BalanceEngine(config: c, rng: SeededRandom(seed: seed), calendar: utc)
        now = start
        _ = engine.tick(Signals(now: now))
    }

    /// At the Mac: typing with short pauses (idle cycles 0…5 s) unless `idle` is fixed.
    @discardableResult
    func work(minutes: Double, idle: Double? = nil, _ tweak: (inout Signals) -> Void = { _ in }) -> [BalanceEvent] {
        run(minutes, make: { i in Signals(now: self.now, idle: idle ?? Double(i % 6), frontApp: "com.apple.dt.Xcode") }, tweak: tweak)
    }

    /// Away from the keyboard (idle keeps growing), optionally with the screen locked.
    @discardableResult
    func away(minutes: Double, locked: Bool = false, _ tweak: (inout Signals) -> Void = { _ in }) -> [BalanceEvent] {
        run(minutes, make: { i in Signals(now: self.now, idle: Double(i + 1), locked: locked, frontApp: "com.apple.dt.Xcode") }, tweak: tweak)
    }

    private func run(_ minutes: Double, make: (Int) -> Signals, tweak: (inout Signals) -> Void) -> [BalanceEvent] {
        var got: [BalanceEvent] = []
        for i in 0..<Int((minutes * 60).rounded()) {
            now += 1
            elapsed += 1
            var s = make(i)
            tweak(&s)
            let ev = engine.tick(s)
            got += ev
            timeline += ev.map { (elapsed, $0) }
        }
        return got
    }

    /// Works second by second until `event` shows up (a need's threshold is random).
    func work(until event: BalanceEvent, maxMinutes: Double = 300) {
        while !timeline.contains(where: { $0.e == event }) && elapsed < maxMinutes * 60 { work(minutes: 1.0 / 60) }
    }

    @discardableResult
    func react(_ r: Reaction) -> [BalanceEvent] {
        let ev = engine.handle(r)
        timeline += ev.map { (elapsed, $0) }
        return ev
    }

    func times(_ match: (BalanceEvent) -> Bool) -> [TimeInterval] { timeline.filter { match($0.e) }.map(\.t) }
}

/// Only `need` can ever become due.
private func only(_ need: Need) -> (inout BalanceConfig) -> Void {
    { c in
        let never = 1e6...(1e6 + 1)
        if need != .water { c.waterMinutes = never }
        if need != .stretch { c.stretchMinutes = never }
        if need != .eyes { c.eyesMinutes = never }
        if need != .walk { c.walkMinutes = never }
        if need != .endOfDay { c.weekdayBudget = 1e9; c.weekendBudget = 1e9 }
    }
}

private extension BalanceEvent {
    var askStage: Int? { if case .ask(_, let s, _, _) = self { return s } else { return nil } }
    var askAgain: Bool { if case .ask(_, _, _, let again) = self { return again } else { return false } }
    var askButtons: [Reaction]? { if case .ask(_, _, let b, _) = self { return b } else { return nil } }
    var isCredit: Bool { if case .credited = self { return true } else { return false } }
}

@Suite("Balance: needs, ladder, director")
@MainActor
struct BalanceTests {

    @Test func waterIsDueAfter40To70MinutesOfSittingAndStartsAsASilentHint() {
        let d = Day(only(.water))
        #expect(d.work(minutes: 39).isEmpty)
        d.work(minutes: 33)
        let hints = d.times { $0 == .hint(.water) }
        #expect(hints.count == 1)
        #expect((40 * 60...71 * 60).contains(hints[0]))
    }

    @Test func ladderClimbsAfter5To10MinutesOfWorkAndStopsAtInsistInSlice2() {
        let d = Day(only(.water))
        d.work(minutes: 71)
        let hint = d.times { $0 == .hint(.water) }[0]
        d.work(minutes: 60)
        let asks = d.timeline.filter { $0.e.askStage != nil }
        #expect(asks.map { $0.e.askStage! } == [1, 2])
        #expect((hint + 300...hint + 601).contains(asks[0].t))
        #expect((asks[0].t + 300...asks[0].t + 601).contains(asks[1].t))
        let bounces = d.times { $0 == .bounceDock }
        #expect(bounces.first == asks[1].t)
        #expect(bounces.count >= 5)
        #expect(zip(bounces, bounces.dropFirst()).allSatisfy { $1 - $0 >= 300 })
    }

    @Test func neverStepsInDuringCallsOrFullscreenAndThePauseFreezesTheLadder() {
        let d = Day(only(.water))
        d.work(minutes: 71) { $0.fullscreen = true }
        #expect(d.timeline.isEmpty)                                   // due, but fullscreen
        #expect(d.work(minutes: 1) == [.hint(.water)])
        _ = d.engine.pokedDuringHint()
        let inCall = d.work(minutes: 30) { $0.inCall = true }
        #expect(inCall == [.withdraw])                                 // no climbing during the call
        let after = d.work(minutes: 1)
        #expect(after.first?.askStage == 1)
        #expect(after.first?.askAgain == true)
    }

    @Test func waterAndEyesCountOnTheUsersWord() {
        let d = Day(only(.water))
        d.work(minutes: 71)
        #expect(d.react(.done) == [.credited(.water, byRest: false, endedEpisode: true)])
        #expect(d.engine.state.episode == nil)
        #expect(d.engine.pressure(.water) == 0)
    }

    @Test func waterCanBeReportedWithoutABubbleButAWalkCannot() {
        let d = Day(only(.water))
        d.work(minutes: 30)
        #expect(d.engine.tookRest(.water) == [.credited(.water, byRest: false, endedEpisode: false)])
        #expect(d.engine.pressure(.water) == 0)
        #expect(d.engine.tookRest(.walk).isEmpty)
    }

    @Test func manualTriggerStartsTheNeedRightAway() {
        let d = Day(only(.water))
        d.work(minutes: 5)
        d.engine.makeDue(.stretch)
        #expect(d.work(minutes: 1.0 / 60, idle: 0.3) == [.hint(.stretch)])
    }

    @Test func stretchCountsOnlyAfterThreeMinutesAwayFromTheKeyboard() {
        let d = Day(only(.stretch))
        d.work(minutes: 76)
        #expect(d.react(.going) == [.promised(.stretch)])
        d.away(minutes: 3.2)
        let credits = d.timeline.filter { $0.e == .credited(.stretch, byRest: true, endedEpisode: true) }
        #expect(credits.count == 1)
        #expect(credits[0].t - d.timeline.first { $0.e == .promised(.stretch) }!.t >= 180)
    }

    @Test func aBrokenPromiseIsNoticedAfter90SecondsOfWorkAndCostsAStep() {
        let d = Day(only(.stretch))
        d.work(minutes: 76)
        let before = d.engine.state.episode?.stage ?? 0
        d.react(.going)
        let asks = d.work(minutes: 2).filter { $0.askStage != nil }
        #expect(asks.count == 1)
        #expect(asks[0].askAgain)
        #expect(asks[0].askStage == min(before + 1, 2))
    }

    @Test func twoDeferralsPerRequestBothButtonsTogetherAndTheLadderKeepsItsStage() {
        let d = Day(only(.water))
        d.work(until: .hint(.water))
        let ask = d.engine.pokedDuringHint()
        #expect(ask.first?.askButtons == [.done, .snooze, .busy])
        #expect(d.react(.snooze) == [.snoozed(.water)])
        #expect(d.work(minutes: 9.5).isEmpty)                          // quiet for 10 minutes
        let second = d.work(minutes: 1.5)
        #expect(second.first?.askStage == 1)                           // back where it was, not lower
        #expect(d.engine.deferBusy(minutes: 15) == [.deferred(.water, minutes: 15)])
        let third = d.work(minutes: 16)
        #expect(third.first?.askStage == 2)                            // «Я занят»: back insisting
        #expect(third.first?.askButtons == [.done])                    // two deferrals spent: only «Попил»
        #expect(d.react(.snooze).isEmpty && d.engine.deferBusy(minutes: 15).isEmpty)
        #expect(d.engine.state.episode?.need == .water)

        #expect(d.react(.done) == [.credited(.water, byRest: false, endedEpisode: true)])   // a real rest resets
        #expect(d.engine.buttons(for: .water) == [.done, .snooze, .busy])
    }

    @Test func busyAsksForHowLongOnceAndComesBackInsisting() {
        let d = Day(only(.water))
        d.work(minutes: 71)
        #expect(d.engine.deferBusy(minutes: 20).isEmpty)                // only 15 / 30 / 60
        #expect(d.engine.deferBusy(minutes: 60) == [.deferred(.water, minutes: 60)])
        #expect(d.work(minutes: 59.5).isEmpty)
        let back = d.work(minutes: 1.5)
        #expect(back.first?.askStage == 2)
        #expect(back.first?.askButtons == [.done, .snooze])            // «Я занят» is once per request
        #expect(back.contains(.bounceDock))
        #expect(d.engine.pressure(.water) > 1)                         // a deferral is not a rest
        #expect(d.engine.deferBusy(minutes: 15).isEmpty)
    }

    @Test func waterOnTheWordCountsAtMostOnceIn20Minutes() {
        let d = Day(only(.water))
        #expect(d.engine.tookRest(.water) == [.credited(.water, byRest: false, endedEpisode: false)])
        d.work(minutes: 10)
        #expect(d.engine.tookRest(.water) == [.tooSoon(.water)])
        d.work(minutes: 10.5)
        #expect(d.engine.tookRest(.water) == [.credited(.water, byRest: false, endedEpisode: false)])
    }

    @Test func anOldNeedTrackKeepsItsSnoozesAsDeferrals() throws {
        let old = try JSONDecoder().decode(NeedTrack.self, from: Data(#"{"sitting":5,"threshold":3000,"debt":false,"snoozesInRow":1,"quietUntil":0}"#.utf8))
        #expect(old.deferrals == 1 && old.threshold == 3000 && !old.busyUsed && old.resumeStage == 0)
    }

    @Test func walkCountsAfterFifteenMinutesAwayOrLockedButNotDuringCallsOrVideo() {
        let busy = Day()
        busy.work(minutes: 20)
        #expect(!busy.away(minutes: 20) { $0.inCall = true }.contains { $0.isCredit })
        #expect(!busy.away(minutes: 20) { $0.video = true }.contains { $0.isCredit })

        let d = Day()
        d.work(minutes: 20)
        let ev = d.away(minutes: 16, locked: true)
        #expect(ev.contains(.credited(.stretch, byRest: true, endedEpisode: false)))
        #expect(ev.contains(.credited(.walk, byRest: true, endedEpisode: false)))
        #expect(ev.contains(.credited(.eyes, byRest: true, endedEpisode: false)))
        #expect(d.engine.pressure(.walk) == 0)
    }

    @Test func aSleepingMacCountsAsRest() {
        let d = Day()
        d.work(minutes: 30)
        d.now += 30 * 60                                               // lid closed, no ticks
        #expect(d.work(minutes: 0.1).contains(.credited(.walk, byRest: true, endedEpisode: false)))
    }

    @Test func atMostFourInterventionsPerHour() {
        let d = Day { c in
            only(.water)(&c)
            c.waterMinutes = 1...1.5
            c.waterMinGap = 0                                          // this test is about the budget only
        }
        for _ in 0..<120 {
            if d.work(minutes: 1).contains(where: { $0 == .hint(.water) }) { d.react(.done) }
        }
        let hints = d.times { $0 == .hint(.water) }
        for h in hints {
            #expect(hints.filter { $0 >= h && $0 < h + 3600 }.count <= 4)
        }
        #expect(hints.count >= 6)                                      // budget, not a dead end
    }

    @Test func moodComesTwoToThreeTimesAnHourAndNeverTooOften() {
        let d = Day { c in
            only(.endOfDay)(&c)
            c.weekdayBudget = 1e9
            c.moodEvery = 15.0 * 60...30.0 * 60
        }
        d.work(minutes: 180)
        let moods = d.times { $0 == .mood }
        #expect((6...12).contains(moods.count))
        #expect(zip(moods, moods.dropFirst()).allSatisfy { $1 - $0 >= 15 * 60 })
    }

    @Test func waitsForAConvenientMomentButNotForever() {
        let d = Day(only(.water))
        d.work(minutes: 75, idle: 0.3)                                 // typing without pauses
        let hint = d.times { $0 == .hint(.water) }[0]
        let due = d.engine.state.needs[.water]!.threshold              // re-rolled only after rest
        _ = due
        let thresholdMoment = hint - 180
        #expect(thresholdMoment >= 40 * 60 && thresholdMoment <= 70 * 60 + 1)

        let switching = Day(only(.water))
        var app = "a"
        switching.work(minutes: 75, idle: 0.3) { s in
            if Int(s.now.timeIntervalSince1970) % 120 == 0 { app = app == "a" ? "b" : "a" }
            s.frontApp = app
        }
        let early = switching.times { $0 == .hint(.water) }[0]
        #expect(early < hint)                                          // an app switch is used right away
    }

    @Test func endOfDayAfterEightHoursOnWeekdaysOnlyInWorkApps() {
        let d = Day(only(.endOfDay))
        d.work(minutes: 8 * 60 - 1)
        #expect(d.timeline.isEmpty)
        d.work(minutes: 5) { $0.category = .leisure }
        #expect(d.timeline.isEmpty)                                     // games and films are fine
        #expect(d.work(minutes: 1).first == .hint(.endOfDay))
    }

    @Test func endOfDayAfterFourHoursOnWeekends() {
        let d = Day(start: date("2026-10-03T10:00:00Z"), only(.endOfDay))
        d.work(minutes: 4 * 60 + 2)
        let hints = d.times { $0 == .hint(.endOfDay) }
        #expect(hints.count == 1)
        #expect(hints[0] >= 4 * 3600)
    }

    @Test func workingPastMidnightIsEndOfDay() {
        let d = Day(start: date("2026-10-05T23:30:00Z"), only(.endOfDay))
        d.work(minutes: 40)
        let hints = d.times { $0 == .hint(.endOfDay) }
        #expect(hints.count == 1)
        #expect((30 * 60...33 * 60).contains(hints[0]))
    }

    @Test func theDayStartsAtFiveInTheMorning() {
        let d = Day(start: date("2026-10-05T04:50:00Z"))
        d.work(minutes: 5)
        #expect(d.engine.state.day.key == "2026-10-04")
        d.work(minutes: 10)
        #expect(d.engine.state.day.key == "2026-10-05")
        #expect(d.engine.state.day.active < 6 * 60)
    }

    @Test func theSproutWiltsAsANeedGrows() {
        let d = Day(only(.water))
        let threshold = d.engine.state.needs[.water]!.threshold
        d.work(minutes: threshold * 0.45 / 60)
        #expect(d.engine.leafFatigue == 0)
        d.work(minutes: threshold * 0.8 / 60)                          // 1.25 × threshold, still not drunk
        #expect(d.engine.leafFatigue > 0.95)
    }

    @Test func stateSurvivesARestartAndDowntimeIsNotRest() throws {
        let d = Day()
        d.work(minutes: 50)
        let data = try JSONEncoder().encode(d.engine.state)
        let saved = try JSONDecoder().decode(BalanceState.self, from: data)
        #expect(saved == d.engine.state)
        let restored = BalanceEngine(restoring: saved, rng: SeededRandom(seed: 1), calendar: utc)
        let ev = restored.tick(Signals(now: d.now + 3 * 3600, idle: 1))   // Chilk was not running for 3 h
        #expect(!ev.contains { $0.isCredit })
        #expect(restored.pressure(.stretch) == d.engine.pressure(.stretch))
    }

    @Test func timeScaleMakesMinutesPassInSeconds() {
        let d = Day { c in
            only(.water)(&c)
            c.timeScale = 60
        }
        d.work(minutes: 1.2)                                           // 72 s real = 72 min
        #expect(d.times { $0 == .hint(.water) }.count == 1)
    }
}

// MARK: - Slice 4: Strict mode, stages 3–4, the emergency exit (decisions 2026-10-05)

@MainActor
private extension Day {
    /// Strict mode, then work until the stretch ladder reaches `stage`.
    func climb(to stage: Int, need: Need = .stretch) {
        _ = try? engine.setMode(.strict)
        while !timeline.contains(where: { $0.e.askStage == stage }) && elapsed < 600 * 60 { work(minutes: 1.0 / 60) }
    }
}

@Suite("Balance: Strict mode, pause, emergency exit")
@MainActor
struct BalanceStrictTests {

    @Test func softIsTheDefaultAndStrictClimbsToThePauseOnlyForStretchWalkAndEndOfDay() {
        #expect(Day().engine.state.mode == .soft)
        let d = Day(only(.stretch))
        d.climb(to: 4)
        let asks = d.timeline.compactMap { $0.e.askStage }
        #expect(asks == [1, 2, 3, 4])
        let pause = d.timeline.last { $0.e.askStage == 4 }!.e
        #expect(pause.askButtons == [])                                    // only the emergency exit
        #expect(d.engine.pauseRest == Optional(TimeInterval(180)))

        let w = Day(only(.water))
        _ = try? w.engine.setMode(.strict)
        w.work(minutes: 140)
        #expect(w.timeline.compactMap { $0.e.askStage } == [1, 2])         // water never goes past «настаивает»
    }

    @Test func thePauseIgnoresButtonsStaysUpWhileAwayAndEndsWithTheRest() {
        let d = Day(only(.stretch))
        d.climb(to: 4)
        #expect(d.react(.snooze).isEmpty && d.react(.busy).isEmpty && d.react(.going).isEmpty)
        #expect(d.engine.state.episode?.stage == 4)
        let away = d.away(minutes: 3.1)
        #expect(!away.contains(.withdraw))
        #expect(away.contains(.credited(.stretch, byRest: true, endedEpisode: true)))
        #expect(d.engine.state.episode == nil)
    }

    @Test func aVideoUnderThePauseDoesNotBlockTheRestButACallTakesThePauseDown() {
        let d = Day(only(.stretch))
        d.climb(to: 4)
        #expect(d.away(minutes: 3.1) { $0.video = true }.contains(.credited(.stretch, byRest: true, endedEpisode: true)))

        let c = Day(only(.stretch))
        c.climb(to: 4)
        #expect(c.work(minutes: 2) { $0.inCall = true } == [.withdraw])
        let back = c.work(minutes: 1.0 / 60)
        #expect(back.first?.askStage == 4 && back.first?.askAgain == true)
    }

    @Test func softerModesWaitUntilTheEscalationIsOverStricterOnesApplyAtOnce() throws {
        let d = Day(only(.stretch))
        d.climb(to: 3)
        #expect(throws: BalanceRefusal.softeningDuringEscalation) { try d.engine.setMode(.soft) }
        #expect(throws: BalanceRefusal.softeningDuringEscalation) { try d.engine.setMode(.silent) }
        #expect(d.engine.state.mode == .strict)

        let s = Day(only(.stretch))
        s.climb(to: 2)
        #expect(try s.engine.setMode(.silent) == [.hint(.stretch)])        // down to the pantomime right away
        #expect(s.engine.state.episode?.stage == 0)
        #expect(try s.engine.setMode(.strict).isEmpty)
    }

    @Test func theEmergencyExitNeedsAReasonAndLetsGoForTheChosenTime() throws {
        let d = Day(only(.stretch))
        #expect(throws: BalanceRefusal.nothingToExit) { try d.engine.emergencyExit(reason: "созвон", minutes: 15, now: d.now) }
        d.climb(to: 4)
        #expect(throws: BalanceRefusal.reasonRequired) { try d.engine.emergencyExit(reason: "  \n", minutes: 15, now: d.now) }
        #expect(throws: BalanceRefusal.badDuration) { try d.engine.emergencyExit(reason: "созвон", minutes: 20, now: d.now) }
        #expect(try d.engine.emergencyExit(reason: "  срочный созвон ", minutes: 15, now: d.now) == [.released(.stretch, minutes: 15)])
        #expect(d.engine.state.episode == nil && d.engine.state.exitsLeft == 2)
        #expect(d.engine.state.day.exits.map(\.reason) == ["срочный созвон"])
        #expect(d.engine.state.day.exits.first?.held == false)

        #expect(d.work(minutes: 14.5).isEmpty)                              // let go: nothing at all
        d.work(minutes: 5)
        #expect(d.timeline.last { $0.e.askStage != nil }?.e.askStage == 2)  // back at «настаивает» (the debt)
    }

    @Test func aDeferralOnStage3ComesBackOnStage3AndBrokenPromisesClimbToThePause() {
        let d = Day(only(.stretch))
        d.climb(to: 3)
        #expect(d.react(.snooze) == [.snoozed(.stretch)])
        d.work(minutes: 11)
        #expect(d.timeline.last { $0.e.askStage != nil }?.e.askStage == 3)

        let p = Day(only(.stretch))
        p.climb(to: 1)
        for expected in [2, 3, 4] {
            p.react(.going)
            let back = p.work(minutes: 1.6).compactMap(\.askStage)
            #expect(back == [expected])                                // «Иду» and keep working → one step up
        }
    }

    @Test func withNoExitsLeftTheButtonIsHeldAndAWalkRefillsThem() throws {
        let d = Day { c in only(.stretch)(&c); c.emergencyExits = 1 }
        d.climb(to: 3)
        _ = try d.engine.emergencyExit(reason: "дедлайн", minutes: 15, now: d.now)
        #expect(d.engine.state.exitsLeft == 0)
        d.work(minutes: 16)
        d.climb(to: 3)
        while d.engine.state.episode?.stage ?? 0 < 3 { d.work(minutes: 1.0 / 60) }
        #expect(throws: BalanceRefusal.holdRequired) { try d.engine.emergencyExit(reason: "дедлайн", minutes: 30, now: d.now) }
        #expect(try d.engine.emergencyExit(reason: "дедлайн", minutes: 30, held: true, now: d.now) == [.released(.stretch, minutes: 30)])
        #expect(d.engine.state.day.exits.map(\.held) == [false, true])
        #expect(d.engine.state.exitsLeft == 0)

        d.away(minutes: 15.1)                                               // a walk
        #expect(d.engine.state.exitsLeft == 1)
    }

    @Test func olderStateFilesLoadWithDefaultsAndFinishedDaysAreKept() throws {
        let d = Day(only(.stretch))
        d.work(minutes: 10)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(d.engine.state)) as! [String: Any]
        for key in ["mode", "exitsLeft", "releasedUntil", "history"] { json.removeValue(forKey: key) }
        var day = json["day"] as! [String: Any]
        day.removeValue(forKey: "exits")
        json["day"] = day
        let old = try JSONDecoder().decode(BalanceState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.mode == .soft && old.exitsLeft == 3 && old.history.isEmpty)
        #expect(old.day.active == d.engine.state.day.active)
        #expect(old.needs == d.engine.state.needs)
        let tiny = try JSONDecoder().decode(BalanceState.self, from: Data(#"{"mode":"strict"}"#.utf8))
        #expect(tiny.mode == .strict)
        let restored = BalanceEngine(restoring: tiny, rng: SeededRandom(seed: 1), calendar: utc)
        #expect(Set(restored.state.needs.keys) == Set(Need.allCases))          // missing needs get fresh tracks

        let late = Day(start: date("2026-10-05T23:30:00Z"), only(.stretch))
        late.work(minutes: 10)
        late.away(minutes: 6 * 60)                                          // past 05:00 — a new day
        late.work(minutes: 1)
        #expect(late.engine.state.history.map(\.key) == ["2026-10-05"])
    }
}
