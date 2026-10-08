import Foundation
import Testing
@testable import ChilkCore

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

/// Drives the engine second by second through an evening and a night (slice 9c).
@MainActor
private final class Night {
    let engine: BalanceEngine
    var now: Date
    var timeline: [(at: Date, e: BalanceEvent)] = []

    /// The care is what the app applies (it sets the ranges and the needs that are on); `tweak` changes it first.
    init(start: Date, mode: BalanceMode = .soft, bedtime: Int = 23 * 60, sleepOn: Bool = true,
         _ tweak: (inout CareSettings) -> Void = { _ in }) {
        var c = BalanceConfig()
        c.moodEvery = 1e8...(1e8 + 1)
        engine = BalanceEngine(config: c, rng: SeededRandom(seed: 7), calendar: utc)
        var care = CareSettings()
        care.sleepOn = sleepOn
        care.bedtime = bedtime
        tweak(&care)
        _ = try? engine.setCare(care)
        if mode != .soft { _ = try? engine.setMode(mode) }
        now = start
        timeline += engine.tick(Signals(now: now, idle: 120)).map { (start, $0) }     // arriving: not at the Mac yet
    }

    @discardableResult
    func work(minutes: Double, _ tweak: (inout Signals) -> Void = { _ in }) -> [BalanceEvent] {
        run(minutes, { i in Signals(now: self.now, idle: Double(i % 6), frontApp: "com.apple.dt.Xcode") }, tweak)
    }

    @discardableResult
    func away(minutes: Double, locked: Bool = false) -> [BalanceEvent] {
        run(minutes, { i in Signals(now: self.now, idle: Double(i) + 61, locked: locked, frontApp: "com.apple.dt.Xcode") }, { _ in })
    }

    /// Works until `match` shows up (at most `maxMinutes`).
    func work(until match: (BalanceEvent) -> Bool, maxMinutes: Double = 120) {
        let start = now
        while !timeline.contains(where: { $0.at > start && match($0.e) }) && now.timeIntervalSince(start) < maxMinutes * 60 {
            work(minutes: 1.0 / 60)
        }
    }

    private func run(_ minutes: Double, _ make: (Int) -> Signals, _ tweak: (inout Signals) -> Void) -> [BalanceEvent] {
        var got: [BalanceEvent] = []
        for i in 0..<Int((minutes * 60).rounded()) {
            now += 1
            var s = make(i)
            tweak(&s)
            let ev = engine.tick(s)
            got += ev
            timeline += ev.map { (now, $0) }
        }
        return got
    }

    @discardableResult
    func react(_ r: Reaction) -> [BalanceEvent] {
        let ev = engine.handle(r)
        timeline += ev.map { (now, $0) }
        return ev
    }

    func asks(_ n: Need) -> [(stage: Int, again: Bool, at: Date)] {
        timeline.compactMap { if case .ask(n, let stage, _, let again) = $0.e { (stage, again, $0.at) } else { nil } }
    }
}

@MainActor
@Suite("«Сон» (slice 9c, decisions 19–28)")
struct SleepTests {
    @Test func theClockOfTheNight() {
        let clock = SleepClock(bedtime: 23 * 60)
        let n = clock.night(for: at("2026-10-05T22:00:00Z"), calendar: utc)
        #expect(n.start == at("2026-10-05T23:00:00Z"))
        #expect(n.end == at("2026-10-06T05:00:00Z"))
        #expect(clock.isNight(at("2026-10-06T02:00:00Z"), calendar: utc))
        #expect(!clock.isNight(at("2026-10-06T05:00:00Z"), calendar: utc))
        #expect(!clock.isNight(at("2026-10-05T22:59:59Z"), calendar: utc))
        let late = SleepClock(bedtime: 30)                                     // 00:30 — the next calendar date
        #expect(late.night(for: at("2026-10-05T23:40:00Z"), calendar: utc).start == at("2026-10-06T00:30:00Z"))
        #expect(!late.isNight(at("2026-10-05T23:40:00Z"), calendar: utc))
        #expect(late.isNight(at("2026-10-06T00:40:00Z"), calendar: utc))
        #expect(!SleepClock.isValid(19 * 60 + 59))
        #expect(SleepClock.isValid(20 * 60) && SleepClock.isValid(3 * 60) && SleepClock.isValid(23 * 60 + 30))
        #expect(!SleepClock.isValid(3 * 60 + 1))
        #expect(SleepClock.order(60) > SleepClock.order(23 * 60))
    }

    @Test func careFromBeforeTheSliceKeepsSleepOff() throws {
        let old = try JSONDecoder().decode(CareSettings.self, from: Data(#"{"off": [], "weekdayHours": 8}"#.utf8))
        #expect(!old.sleepOn)
        #expect(old.bedtime == 23 * 60)
        var c = BalanceConfig()
        c.needsOff = []
        old.apply(to: &c)
        #expect(c.needsOff.contains(.sleep))
        let bad = try JSONDecoder().decode(CareSettings.self, from: Data(#"{"sleepOn": true, "bedtime": 1500}"#.utf8))
        #expect(bad.sleepOn && bad.bedtime == 23 * 60)
        var on = CareSettings()
        on = on.applying(.need(.sleep, on: true)).applying(.bedtime(22 * 60 + 30))
        let back = try JSONDecoder().decode(CareSettings.self, from: try JSONEncoder().encode(on))
        #expect(back.sleepOn && back.bedtime == 22 * 60 + 30)
        #expect(on.applying(.bedtime(19 * 60)).bedtime == 22 * 60 + 30)                 // outside 20:00–03:00: unchanged
        #expect(on.isSofter(on.applying(.bedtime(23 * 60))))
        #expect(!on.isSofter(on.applying(.bedtime(22 * 60))))
        #expect(on.isSofter(on.applying(.need(.sleep, on: false))))
    }

    @Test func offByDefaultNothingHappensAtNight() {
        let night = Night(start: at("2026-10-05T22:50:00Z"), sleepOn: false) { $0.off = [.water, .stretch, .eyes, .walk, .endOfDay] }
        night.work(minutes: 30)
        #expect(night.asks(.sleep).isEmpty)
        #expect(!night.timeline.contains { if case .bedtimeSoon = $0.e { true } else { false } })
    }

    @Test func theWarningComesOnceAnHourBeforeAndNotAfterBedtime() {
        let night = Night(start: at("2026-10-05T21:58:00Z"))
        night.work(minutes: 10)
        let warnings = night.timeline.compactMap { if case .bedtimeSoon(let bed) = $0.e { ($0.at, bed) } else { nil } }
        #expect(warnings.count == 1)
        #expect(warnings.first?.1 == at("2026-10-05T23:00:00Z"))
        #expect(warnings.first.map { $0.0 >= at("2026-10-05T22:00:00Z") && $0.0 < at("2026-10-05T22:00:02Z") } == true)
        let late = Night(start: at("2026-10-05T23:10:00Z"))                     // arrived after bedtime: no warning
        late.work(minutes: 2)
        #expect(!late.timeline.contains { if case .bedtimeSoon = $0.e { true } else { false } })
        #expect(late.asks(.sleep).first?.stage == 1)
    }

    @Test func atBedtimeOnlySleepAsksAtOnceAndOnEveryApp() {
        let night = Night(start: at("2026-10-05T22:40:00Z")) { $0.ranges[.water] = MinuteRange(1, 1) }
        night.work(minutes: 19)                                                  // water comes before bedtime
        #expect(!night.asks(.water).isEmpty)
        night.work(minutes: 2) { $0.category = .leisure; $0.fullscreen = true }    // a film after bedtime
        let sleep = night.asks(.sleep)
        #expect(sleep.first?.stage == 1)
        #expect(sleep.first.map { $0.at <= at("2026-10-05T23:00:01Z") } == true)
        #expect(night.engine.state.episode?.need == .sleep)
        let waterAfter = night.asks(.water).filter { $0.at >= at("2026-10-05T23:00:00Z") }
        night.react(.busy)
        _ = night.engine.deferBusy(minutes: 60)
        night.work(minutes: 30)
        #expect(waterAfter.isEmpty)
        #expect(night.asks(.water).filter { $0.at >= at("2026-10-05T23:00:00Z") }.isEmpty)   // decision 25
        let call = Night(start: at("2026-10-05T23:05:00Z"))
        call.work(minutes: 3) { $0.inCall = true }
        #expect(call.asks(.sleep).isEmpty)                                       // a call still holds him
    }

    @Test func goingToSleepIsFiveMinutesOfWork() {
        let night = Night(start: at("2026-10-05T23:00:00Z"))
        night.work(minutes: 0.2)
        #expect(night.asks(.sleep).count == 1)
        night.react(.going)
        night.work(minutes: 4.5)
        #expect(night.asks(.sleep).count == 1)                                   // not 90 s as for the others
        night.work(minutes: 1)
        #expect(night.asks(.sleep).last.map { $0.stage == 2 && $0.again } == true)
    }

    @Test func awayAfterThePromiseAndBackIsAStepUpAtOnce() {
        let night = Night(start: at("2026-10-05T23:00:00Z"))
        night.work(minutes: 0.2)
        night.react(.going)
        night.away(minutes: 40, locked: true)
        #expect(night.asks(.sleep).count == 1)
        night.work(minutes: 0.1)
        #expect(night.asks(.sleep).last.map { $0.stage == 2 && $0.again } == true)
    }

    @Test func strictWarnsFiveMinutesBeforeThePauseAndAgainAfterAnAbsence() {
        let night = Night(start: at("2026-10-05T23:00:00Z"), mode: .strict)
        night.work(until: { if case .pauseSoon(.sleep) = $0 { true } else { false } })
        guard let warned = night.timeline.last(where: { if case .pauseSoon = $0.e { true } else { false } })?.at else {
            Issue.record("no warning before the pause")
            return
        }
        #expect(night.engine.state.episode?.stage == 3)
        night.work(minutes: 4.9)
        #expect(night.engine.state.episode?.stage == 3)
        night.away(minutes: 2)                                                   // away: the 5 minutes start again
        night.work(until: { if case .pauseSoon(.sleep) = $0 { true } else { false } }, maxMinutes: 2)
        let again = night.timeline.filter { if case .pauseSoon = $0.e { true } else { false } }
        #expect(again.count == 2)
        night.work(minutes: 5.1)
        let pause = night.asks(.sleep).first { $0.stage == 4 }
        #expect(pause != nil)
        #expect(pause.map { $0.at.timeIntervalSince(warned) > 300 } == true)
        #expect(night.engine.nightPause)
        #expect(night.engine.buttons(for: .sleep, stage: 4).isEmpty)
    }

    @Test func thePauseHoldsAllNightAndSleepCountsAtFive() {
        let night = Night(start: at("2026-10-05T23:00:00Z"), mode: .strict)
        night.work(until: { if case .ask(.sleep, 4, _, _) = $0 { true } else { false } })
        night.away(minutes: 60, locked: true)                                   // a lock proves nothing (decision 22)
        #expect(night.engine.nightPause)
        night.work(minutes: 1)
        #expect(night.engine.nightPause)                                         // back at night: the pause at once
        night.away(minutes: at("2026-10-06T05:01:00Z").timeIntervalSince(night.now) / 60, locked: true)
        #expect(night.timeline.contains { $0.e == .credited(.sleep, byRest: true, endedEpisode: true) })
        #expect(night.engine.state.episode == nil)
        #expect(night.engine.state.history.last?.credited[.sleep] == 1)
        #expect(night.engine.state.history.last?.pushed[.sleep] == 1)
        night.work(minutes: 60)                                                  // after 05:00 «Сон» is quiet
        #expect(night.asks(.sleep).filter { $0.at > at("2026-10-06T05:00:00Z") }.isEmpty)
    }

    @Test func anEmergencyExitAtNightComesBackAtStageTwo() throws {
        let night = Night(start: at("2026-10-05T23:00:00Z"), mode: .strict)
        night.work(until: { if case .ask(.sleep, 3, _, _) = $0 { true } else { false } })
        _ = try night.engine.emergencyExit(reason: "дедлайн", minutes: 15, now: night.now)
        night.work(minutes: 14)
        #expect(night.engine.state.episode == nil)
        night.work(minutes: 2)
        #expect(night.asks(.sleep).last?.stage == 2)
    }

    @Test func focusStopsAtBedtimeAndIsRefusedAtNight() throws {
        let night = Night(start: at("2026-10-05T21:30:00Z"))
        let start = try night.engine.startFocus(seconds: 3 * 3600, now: night.now)
        #expect(start.until == at("2026-10-05T23:00:00Z"))
        #expect(start.untilBedtime)
        night.work(minutes: 100)
        #expect(throws: BalanceRefusal.sleepTime) { _ = try night.engine.startFocus(seconds: 3600, now: night.now) }
    }

    @Test func theNightContractLetsOnlyEarlier() throws {
        let night = Night(start: at("2026-10-05T21:00:00Z"))
        var care = night.engine.state.care
        care.bedtime = 23 * 60 + 30
        try night.engine.setCare(care)                                           // before the warning: later is fine
        night.work(minutes: 110)                                                 // 22:50 — after the warning (22:30)
        care.bedtime = 23 * 60 + 45
        #expect(throws: BalanceRefusal.sleepContract) { try night.engine.setCare(care) }
        care.sleepOn = false
        #expect(throws: BalanceRefusal.sleepContract) { try night.engine.setCare(care) }
        care.sleepOn = true
        care.bedtime = 23 * 60
        try night.engine.setCare(care)                                           // earlier: always
        #expect(throws: BalanceRefusal.sleepContract) { try night.engine.shiftBedtime(tonight: 23 * 60 + 30, now: night.now) }
        try night.engine.shiftBedtime(tonight: 22 * 60 + 55, now: night.now)
        #expect(night.engine.sleepStatus(night.now)?.bedtime == at("2026-10-05T22:55:00Z"))
    }

    @Test func tonightOnlyAndAtMostTwoHoursLater() throws {
        let night = Night(start: at("2026-10-05T20:00:00Z"))
        let bed = try night.engine.shiftBedtime(tonight: 60, now: night.now)       // «сегодня лягу в час»
        #expect(bed == at("2026-10-06T01:00:00Z"))
        #expect(throws: BalanceRefusal.tooLate) { try night.engine.shiftBedtime(tonight: 90, now: night.now) }
        #expect(night.engine.sleepStatus(at("2026-10-06T10:00:00Z"))?.bedtime == at("2026-10-06T23:00:00Z"))   // next night
    }

    @Test func theMidnightRuleOfEndOfDayIsOffWithSleep() {
        let night = Night(start: at("2026-10-05T23:30:00Z"), bedtime: 2 * 60)
        night.work(minutes: 60)                                                  // 00:30, bedtime 02:00
        #expect(night.asks(.endOfDay).isEmpty)
    }

    @Test func aRestartAtNightKeepsTheDeferrals() {
        let night = Night(start: at("2026-10-05T23:00:00Z"))
        night.work(minutes: 0.2)
        night.react(.snooze)
        let saved = night.engine.state
        let again = BalanceEngine(config: BalanceConfig(), restoring: saved, rng: SeededRandom(seed: 7), calendar: utc)
        again.applyCare()
        #expect(again.state.needs[.sleep]?.deferrals == 1)
        #expect(again.state.needs[.sleep]?.quietUntil == saved.needs[.sleep]?.quietUntil)
    }

    @Test func goingToSleepDuringTheCountdownStartsItAgain() {
        let night = Night(start: at("2026-10-05T23:00:00Z"), mode: .strict)
        night.work(until: { if case .pauseSoon(.sleep) = $0 { true } else { false } })
        night.react(.going)
        #expect(night.engine.state.episode?.pauseIn == nil)
        night.work(minutes: 5.1)                                                 // the broken promise: «сохраняйся» again
        let warnings = night.timeline.filter { if case .pauseSoon = $0.e { true } else { false } }
        #expect(warnings.count == 2)
        #expect(night.engine.state.episode?.stage == 3)
    }

    @Test func aNewUsualBedtimeEndsTonightsShift() throws {
        let night = Night(start: at("2026-10-05T20:00:00Z"))
        try night.engine.shiftBedtime(tonight: 23 * 60 + 30, now: night.now)
        var care = night.engine.state.care
        care.bedtime = 22 * 60 + 30
        try night.engine.setCare(care)
        #expect(night.engine.sleepStatus(night.now)?.bedtime == at("2026-10-05T22:30:00Z"))
    }

    @Test func aNightTheMacSleptThroughIsOnRecord() {
        let night = Night(start: at("2026-10-05T21:00:00Z"))
        _ = night.engine.tick(Signals(now: at("2026-10-06T06:00:00Z")))        // lid closed until the morning
        #expect(night.engine.state.history.last?.bedtime == 23 * 60)
        #expect(night.engine.state.history.last?.credited[.sleep] == 1)
        #expect(night.engine.today(now: at("2026-10-06T06:00:00Z")).sleep?.lastActivity == nil)
    }

    @Test func switchedOnItStartsAt23() {
        var care = CareSettings()
        care.bedtime = 21 * 60
        #expect(care.applying(.need(.sleep, on: true)).bedtime == 23 * 60)
    }

    @Test func noNewGamesAtNightAndARunningOneWaitsAQuarterOfAnHour() {
        #expect(GameGate.refusal(kind: .ticTacToe, exhausted: false, stage: 0, exercise: false, night: true) == .night)
        #expect(GameGate.refusal(kind: .ticTacToe, exhausted: false, stage: 0, exercise: false) == nil)
        func decide(waiting: TimeInterval, between: Bool = false) -> GameBreakAction {
            GameBreakPolicy.decide(stage: 1, need: .sleep, slumped: false, silent: false, betweenGames: between, waiting: waiting)
        }
        #expect(decide(waiting: 700) == .keepPlaying)                          // longer than the day's 10 minutes
        #expect(decide(waiting: 900) == .card)
        #expect(decide(waiting: 0, between: true) == .card)
    }

    @Test func theDayRemembersItsNight() {
        let night = Night(start: at("2026-10-05T23:00:00Z"))
        night.work(minutes: 0.2)
        _ = night.engine.deferBusy(minutes: 60)
        night.work(minutes: 39.8)                                                // the last action ≈ 23:40
        night.away(minutes: 330, locked: true)                                   // until 05:10
        night.work(minutes: 1)
        let today = night.engine.today(now: night.now)
        #expect(today.sleep?.bedtime == 23 * 60)
        #expect(today.sleep?.lastActivity.map { abs($0.timeIntervalSince(at("2026-10-05T23:40:00Z"))) < 5 } == true)
        #expect(today.sleep?.pushed == false)
    }
}
