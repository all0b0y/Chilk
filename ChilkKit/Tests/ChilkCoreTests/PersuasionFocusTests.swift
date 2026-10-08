import Foundation
import Testing
@testable import ChilkCore

// Slice 4b (SPEC «Уговоры и фокус (В14)», decisions 1–4): persuasion by voice/chat and the focus mode.

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

/// Second-by-second driver like the app's (see BalanceTests).
@MainActor
private final class Run {
    let engine: BalanceEngine
    var now: Date
    var events: [BalanceEvent] = []

    init(start: Date = date("2026-10-05T09:00:00Z"), only need: Need? = nil, _ configure: (inout BalanceConfig) -> Void = { _ in }) {
        var c = BalanceConfig()
        c.moodEvery = 1e8...(1e8 + 1)
        if let need {
            let never = 1e6...(1e6 + 1)
            if need != .water { c.waterMinutes = never }
            if need != .stretch { c.stretchMinutes = never }
            if need != .eyes { c.eyesMinutes = never }
            if need != .walk { c.walkMinutes = never }
            if need != .endOfDay { c.weekdayBudget = 1e9; c.weekendBudget = 1e9 }
        }
        configure(&c)
        engine = BalanceEngine(config: c, rng: SeededRandom(seed: 11), calendar: utc)
        now = start
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

    @discardableResult
    func away(minutes: Double) -> [BalanceEvent] {
        var got: [BalanceEvent] = []
        for i in 0..<Int((minutes * 60).rounded()) {
            now += 1
            got += engine.tick(Signals(now: now, idle: Double(i + 1), frontApp: "com.apple.dt.Xcode"))
        }
        events += got
        return got
    }

    func workUntilStage(_ stage: Int, maxMinutes: Double = 600) {
        var spent = 0.0
        while (engine.state.episode?.stage ?? -1) < stage && spent < maxMinutes {
            work(minutes: 1.0 / 60)
            spent += 1.0 / 60
        }
    }

    func workUntilRequest(maxMinutes: Double = 600) { workUntilStage(0, maxMinutes: maxMinutes) }
}

private func refusal(_ body: () throws -> Void) -> BalanceRefusal? {
    do { try body(); return nil } catch { return error as? BalanceRefusal }
}

@MainActor
@Suite struct PersuasionFocusTests {
    // MARK: Persuasion (decisions 1, 2, 4)

    @Test func aPersuasionIsTheRequestsBusyInsideTheSharedLimit() throws {
        let run = Run(only: .stretch)
        run.workUntilRequest()
        #expect(try run.engine.maxPersuasion() == 60)
        let events = try run.engine.persuade(minutes: 30)
        #expect(events == [.deferred(.stretch, minutes: 30)])
        #expect(run.engine.state.episode == nil)
        #expect(run.engine.state.needs[.stretch]?.busyUsed == true)
        #expect(run.engine.state.day.persuaded[.stretch] == 1)
        #expect(run.engine.state.day.busy == 1)

        run.work(minutes: 29)
        #expect(run.engine.state.episode == nil)                       // quiet for the 30 minutes
        run.workUntilRequest(maxMinutes: 5)
        #expect((run.engine.state.episode?.stage ?? 0) >= 2)            // back at «настаивает», like the button
        #expect(refusal { _ = try run.engine.maxPersuasion() } == .deferralsSpent)   // «Я занят» once per request
        #expect(run.engine.buttons(for: .stretch, stage: 2).contains(.snooze))       // «Через 10 мин» is still there
    }

    @Test func theButtonsSpendTheSameLimit() throws {
        let run = Run(only: .stretch)
        run.workUntilRequest()
        _ = run.engine.handle(.snooze)
        run.workUntilRequest(maxMinutes: 15)
        _ = run.engine.handle(.snooze)
        run.workUntilRequest(maxMinutes: 15)
        #expect(run.engine.state.needs[.stretch]?.deferrals == 2)
        #expect(refusal { _ = try run.engine.persuade(minutes: 15) } == .deferralsSpent)

        let other = Run(only: .stretch)
        other.workUntilRequest()
        _ = other.engine.deferBusy(minutes: 15)                         // the «Я занят» button
        other.workUntilRequest(maxMinutes: 20)
        #expect(refusal { _ = try other.engine.persuade(minutes: 15) } == .deferralsSpent)
    }

    @Test func eachPersuasionOfTheSameNeedTodayDefersLess() throws {
        let run = Run(only: .stretch)
        run.workUntilRequest()
        #expect(try run.engine.persuade(minutes: 60) == [.deferred(.stretch, minutes: 60)])
        run.away(minutes: 4)                                            // a counted rest resets the request's limit
        run.workUntilRequest()
        #expect(try run.engine.maxPersuasion() == 30)
        #expect(try run.engine.persuade(minutes: 60) == [.deferred(.stretch, minutes: 30)])   // cut by the engine
        run.away(minutes: 4)
        run.workUntilRequest()
        #expect(try run.engine.persuade(minutes: 30) == [.deferred(.stretch, minutes: 15)])
        run.away(minutes: 4)
        run.workUntilRequest()
        #expect(try run.engine.maxPersuasion() == 15)

        let next = Run(start: date("2026-10-05T23:00:00Z"), only: .stretch)
        next.workUntilRequest()
        _ = try next.engine.persuade(minutes: 60)
        next.away(minutes: 4)
        next.work(minutes: 6 * 60)                                       // past 05:00 — a new day
        next.workUntilRequest()
        #expect(next.engine.state.day.persuaded.isEmpty)
    }

    @Test func nothingToDeferAndThePauseAreRefused() throws {
        let run = Run(only: .stretch) { $0.nextStageAfter = 60...61 }
        #expect(refusal { _ = try run.engine.persuade(minutes: 15) } == .nothingToDefer)
        run.workUntilRequest()
        #expect(refusal { _ = try run.engine.persuade(minutes: 45) } == .badDuration)
        _ = try run.engine.setMode(.strict)
        run.workUntilStage(4)
        #expect(run.engine.state.episode?.stage == 4)
        #expect(refusal { _ = try run.engine.persuade(minutes: 15) } == .pauseInProgress)
    }

    // MARK: Focus (decision 3)

    @Test func focusKeepsEveryRequestOnStagesZeroToOne() throws {
        let run = Run(only: .stretch) { $0.nextStageAfter = 60...61 }
        _ = try run.engine.setMode(.strict)
        let start = try run.engine.startFocus(seconds: 2 * 3600, now: run.now)
        #expect(start.until == run.now.addingTimeInterval(2 * 3600))
        #expect(!start.shortened)
        run.work(minutes: 110)
        #expect(run.engine.state.episode?.stage == 1)
        #expect(!run.events.contains(.nudge))
    }

    @Test func aRequestOnStageTwoComesDownToOneAtOnce() throws {
        let run = Run(only: .stretch) { $0.nextStageAfter = 60...61 }
        run.workUntilStage(2)
        let start = try run.engine.startFocus(seconds: 3600, now: run.now)
        #expect(start.events == [.ask(.stretch, stage: 1, buttons: [.going, .snooze, .busy], again: false)])
        #expect(run.engine.state.episode?.stage == 1)
    }

    @Test func whenFocusEndsWhatPiledUpStartsAtInsists() throws {
        let run = Run { c in
            c.waterMinutes = 30...30
            c.stretchMinutes = 50...50
            c.eyesMinutes = 1e6...(1e6 + 1)
            c.walkMinutes = 1e6...(1e6 + 1)
            c.weekdayBudget = 1e9
            c.nextStageAfter = 60...61
        }
        _ = try run.engine.startFocus(seconds: 3600, now: run.now)
        run.work(minutes: 59)
        #expect(run.engine.state.episode?.need == .water)
        #expect(run.engine.state.episode?.stage == 1)
        let end = run.work(minutes: 2)
        #expect(end.contains(.focusEnded))
        #expect(end.contains(.nudge))
        #expect(run.engine.state.episode?.stage == 2)
        #expect(run.engine.state.needs[.stretch]?.debt == true)         // came due under the focus
        #expect(run.engine.state.day.pushed[.water] == 1)

        _ = run.engine.handle(.done)                                    // water on the word
        run.workUntilRequest(maxMinutes: 10)
        #expect(run.engine.state.episode?.need == .stretch)
        #expect(run.engine.state.episode?.stage == 2)                   // straight at «настаивает»
    }

    @Test func silentStaysSilentAfterTheFocus() throws {
        let run = Run(only: .stretch)
        _ = try run.engine.setMode(.silent)
        _ = try run.engine.startFocus(seconds: 3 * 3600, now: run.now)
        run.workUntilRequest()
        let end = run.engine.endFocus(now: run.now)
        #expect(end == [.focusEnded])
        #expect(run.engine.state.episode?.stage == 0)
    }

    @Test func endingEarlyGivesTheUnusedTimeBack() throws {
        let run = Run(only: .stretch)
        _ = try run.engine.startFocus(seconds: 3 * 3600, now: run.now)
        run.work(minutes: 30)
        #expect(run.engine.endFocus(now: run.now) == [.focusEnded])
        #expect(!run.engine.focusing)
        #expect(abs(run.engine.state.day.focus - 30 * 60) < 2)
        #expect(abs(run.engine.focusLeftToday - 3.5 * 3600) < 2)
        #expect(run.engine.endFocus(now: run.now).isEmpty)
    }

    @Test func atMostThreeHoursAtATimeAndFourADay() throws {
        let run = Run(only: .water) { $0.waterMinutes = 1e6...(1e6 + 1) }
        let first = try run.engine.startFocus(seconds: 5 * 3600, now: run.now)
        #expect(first.shortened)
        #expect(first.until == run.now.addingTimeInterval(3 * 3600))
        let again = try run.engine.startFocus(seconds: 3600, now: run.now.addingTimeInterval(600))   // replaces it
        #expect(!again.shortened)
        #expect(abs(run.engine.state.day.focus - (600 + 3600)) < 1)
        run.away(minutes: 70)
        #expect(run.events.contains(.focusEnded))
        let third = try run.engine.startFocus(seconds: 3 * 3600, now: run.now)
        #expect(third.shortened)
        #expect(abs(third.until.timeIntervalSince(run.now) - (4 * 3600 - 600 - 3600)) < 1)
        run.away(minutes: 175)
        #expect(!run.engine.focusing)
        #expect(refusal { _ = try run.engine.startFocus(seconds: 3600, now: run.now) } == .focusSpent)
        #expect(refusal { _ = try run.engine.startFocus(seconds: 30, now: run.now) } == .badDuration)
    }

    @Test func aFocusAcrossTheDayBoundaryCountsInTheNewDay() throws {
        let run = Run(start: date("2026-10-06T04:00:00Z"), only: .water) { $0.waterMinutes = 1e6...(1e6 + 1) }
        _ = try run.engine.startFocus(seconds: 3 * 3600, now: run.now)
        run.away(minutes: 61)                                            // 05:01 — a new day
        #expect(run.engine.focusing)
        #expect(abs(run.engine.state.day.focus - 120 * 60) < 2)   // counted from 05:00
        let replaced = try run.engine.startFocus(seconds: 3 * 3600, now: run.now)
        #expect(!replaced.shortened)                                     // 3 h left of the new day's 4 h: fits
        run.away(minutes: 181)
        let last = try run.engine.startFocus(seconds: 3 * 3600, now: run.now)
        #expect(last.shortened)
        #expect(abs(last.until.timeIntervalSince(run.now) - 59 * 60) < 2)   // 4 h a day: 1 min of the old one + 180 min
    }

    @Test func aRestartLongAfterTheDayBoundaryStillCountsFromTheBoundary() throws {
        let run = Run(start: date("2026-10-06T04:00:00Z"), only: .water) { $0.waterMinutes = 1e6...(1e6 + 1) }
        _ = try run.engine.startFocus(seconds: 3 * 3600, now: run.now)         // 04:00–07:00
        let saved = run.engine.state
        let restored = BalanceEngine(config: run.engine.config, restoring: saved, rng: SeededRandom(seed: 5), calendar: utc)
        _ = restored.tick(Signals(now: date("2026-10-06T06:00:00Z")))
        #expect(abs(restored.state.day.focus - 2 * 3600) < 1)                  // 05:00–07:00, not 06:00–07:00
        #expect(abs((restored.state.history.last?.focus ?? -1) - 3600) < 1)    // and 04:00–05:00 stays in the old day
    }

    @Test func aFailedWriteHandsNothingOut() throws {
        struct Disk: Error {}
        let run = Run(only: .stretch)
        run.workUntilRequest()
        let before = run.engine.state
        #expect(throws: Disk.self) { try run.engine.committing({ _ in throw Disk() }) { try run.engine.persuade(minutes: 30) } }
        #expect(run.engine.state == before)
        #expect(throws: Disk.self) {
            try run.engine.committing({ _ in throw Disk() }) { try run.engine.startFocus(seconds: 3600, now: run.now) }
        }
        #expect(!run.engine.focusing)
        var written: BalanceState?
        _ = try run.engine.committing({ written = $0 }) { try run.engine.persuade(minutes: 30) }
        #expect(written?.day.persuaded[.stretch] == 1)
    }

    @Test func endOfDayPastMidnightGetsTheDebtToo() throws {
        let run = Run(start: date("2026-10-05T23:30:00Z"), only: .water) { $0.waterMinutes = 1e6...(1e6 + 1) }
        _ = try run.engine.startFocus(seconds: 3600, now: run.now)
        run.work(minutes: 61)                                                  // 00:31: «конец дня» is due by the clock
        #expect(run.engine.state.needs[.endOfDay]?.debt == true)
    }

    @Test func focusIsRefusedOnStagesThreeToFour() throws {
        let run = Run(only: .stretch) { $0.nextStageAfter = 60...61 }
        _ = try run.engine.setMode(.strict)
        run.workUntilStage(3)
        #expect(refusal { _ = try run.engine.startFocus(seconds: 3600, now: run.now) } == .softeningDuringEscalation)
        #expect(!run.engine.focusing)
    }

    @Test func focusSurvivesARestartAndOldFilesDecode() throws {
        let run = Run(only: .stretch)
        _ = try run.engine.startFocus(seconds: 3600, now: run.now)
        let data = try JSONEncoder().encode(run.engine.state)
        let back = try JSONDecoder().decode(BalanceState.self, from: data)
        #expect(back.focusUntil == run.engine.state.focusUntil)
        #expect(back.day.focus == 3600)

        let restored = BalanceEngine(config: run.engine.config, restoring: back, rng: SeededRandom(seed: 3), calendar: utc)
        #expect(restored.focusing)
        _ = restored.tick(Signals(now: run.now.addingTimeInterval(1800)))
        #expect(restored.focusing)
        #expect(restored.tick(Signals(now: run.now.addingTimeInterval(3601))).contains(.focusEnded))

        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "focusUntil")
        var day = json["day"] as! [String: Any]
        day.removeValue(forKey: "focus")
        day.removeValue(forKey: "persuaded")
        json["day"] = day
        let old = try JSONDecoder().decode(BalanceState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.focusUntil == nil)
        #expect(old.day.focus == 0)
        #expect(old.day.persuaded.isEmpty)
    }

    // MARK: Codex's [контекст]

    @Test func theBriefTellsCodexTheRequestItsLimitsAndTheFocus() throws {
        let run = Run(only: .stretch)
        let zone = TimeZone(identifier: "UTC")!
        let none = VoiceContext.text(sittingMinutes: 5, now: run.now, zone: zone, balance: run.engine.brief())
        #expect(none.contains("просьбы на экране нет; «Не беспокоить» не включено, на сегодня осталось 240 мин «Не беспокоить»]"))

        run.workUntilRequest()
        _ = try run.engine.persuade(minutes: 15)
        run.away(minutes: 4)
        run.workUntilRequest()
        _ = try run.engine.startFocus(seconds: 3600, now: date("2026-10-05T11:00:00Z"))
        let text = VoiceContext.text(sittingMinutes: 50, now: run.now, zone: zone, balance: run.engine.brief())
        #expect(text.contains("на экране просьба «размяться», ступень 1 из 4, отсрочек осталось 2, уговором можно до 30 мин, "   // starts on 1 (6a)
                              + "сегодня её уже откладывали уговором 1 раз; «Не беспокоить» до 12:00, на сегодня ещё 180 мин «Не беспокоить»]"))

        _ = try run.engine.persuade(minutes: 15)
        run.work(minutes: 16)
        run.workUntilRequest()
        let after = VoiceContext.text(sittingMinutes: 70, now: run.now, zone: zone, balance: run.engine.brief())
        #expect(after.contains("уговор для неё уже был — осталась только кнопка «Через 10 мин»"))
    }
}
