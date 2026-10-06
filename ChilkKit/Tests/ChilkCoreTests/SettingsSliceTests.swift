import Foundation
import Testing
@testable import ChilkCore

// Slice 5c (SPEC «Срез 5», decisions 18–20): Settings, «договор с собой», «Сегодня» / «Неделя».

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
    func work(minutes: Double, _ tweak: (inout Signals) -> Void = { _ in }) -> [BalanceEvent] {
        var got: [BalanceEvent] = []
        for i in 0..<Int((minutes * 60).rounded()) {
            now += 1
            var s = Signals(now: now, idle: Double(i % 6), frontApp: "com.apple.dt.Xcode")
            tweak(&s)
            got += engine.tick(s)
        }
        events += got
        return got
    }

    @discardableResult
    func away(minutes: Double, _ tweak: (inout Signals) -> Void = { _ in }) -> [BalanceEvent] {
        var got: [BalanceEvent] = []
        for i in 0..<Int((minutes * 60).rounded()) {
            now += 1
            var s = Signals(now: now, idle: Double(i + 1), frontApp: "com.apple.dt.Xcode")
            tweak(&s)
            got += engine.tick(s)
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
}

private extension BalanceEvent {
    var isAsk: Bool { if case .ask = self { return true } else { return false } }
    var isHintOrAsk: Bool {
        switch self {
        case .hint, .ask: true
        default: false
        }
    }
}

@Suite("Slice 5c: settings and «договор с собой»")
@MainActor
struct SettingsSliceTests {
    // MARK: Care (decision 19)

    @Test func defaultCareMatchesTheEngineDefaults() {
        var c = BalanceConfig()
        c.waterMinutes = 1...2
        CareSettings().apply(to: &c)
        let d = BalanceConfig()
        #expect(c.waterMinutes == d.waterMinutes && c.stretchMinutes == d.stretchMinutes)
        #expect(c.eyesMinutes == d.eyesMinutes && c.walkMinutes == d.walkMinutes)
        #expect(c.weekdayBudget == d.weekdayBudget && c.weekendBudget == d.weekendBudget)
        #expect(c.needsOff.isEmpty)
    }

    @Test func lessCareSoftensMoreCareTightens() {
        let s = CareSettings()
        #expect(s.softens(.need(.water, on: false)))
        #expect(!s.softens(.need(.water, on: true)))
        #expect(s.softens(.low(.water, 45)))
        #expect(!s.softens(.low(.water, 35)))
        #expect(s.softens(.high(.stretch, 80)))
        #expect(!s.softens(.high(.stretch, 70)))
        #expect(s.softens(.budget(weekend: false, hours: 9)))
        #expect(!s.softens(.budget(weekend: true, hours: 3)))
        // Raising «от» past «до» lifts «до» as well; lowering «до» under «от» brings «от» down.
        #expect(s.applying(.low(.water, 90)).range(.water) == MinuteRange(90, 90))
        #expect(s.applying(.high(.water, 20)).range(.water) == MinuteRange(20, 20))
        // Limits.
        #expect(s.applying(.low(.eyes, 1)).range(.eyes).low == 15)
        #expect(s.applying(.high(.walk, 900)).range(.walk).high == 300)
        #expect(s.applying(.budget(weekend: false, hours: 30)).weekdayHours == 16)
    }

    @Test func duringStages3To4TheEngineRefusesSofterCareAndTakesTighterCare() throws {
        let r = Run(only: .stretch)
        _ = try r.engine.setMode(.strict)
        r.workUntilStage(3)
        let before = r.engine.state.care
        for change in [CareChange.need(.stretch, on: false), .need(.water, on: false), .high(.walk, 195), .low(.eyes, 35),
                       .budget(weekend: true, hours: 5)] {
            #expect(throws: BalanceRefusal.softeningDuringEscalation) { try r.engine.setCare(before.applying(change)) }
        }
        #expect(r.engine.state.care == before)
        #expect(r.engine.state.episode?.stage == 3)                          // nothing let the request go
        try r.engine.setCare(before.applying(.low(.walk, 90)))
        try r.engine.setCare(r.engine.state.care.applying(.budget(weekend: false, hours: 7)))
        #expect(r.engine.state.care.range(.walk).low == 90 && r.engine.state.care.weekdayHours == 7)
        #expect(r.engine.config.walkMinutes.lowerBound == 90 && r.engine.config.weekdayBudget == 7 * 3600)
        r.away(minutes: 3.1)                                                 // rested: free again
        try r.engine.setCare(r.engine.state.care.applying(.need(.walk, on: false)))
        #expect(!r.engine.state.care.isOn(.walk))
    }

    @Test func careIsKeptWithTheEngineStateAndADamagedValueLosesOnlyItself() throws {
        var state = BalanceState(needs: [:], nextMood: 0)
        state.care = CareSettings().applying(.need(.eyes, on: false)).applying(.low(.water, 30))
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(BalanceState.self, from: data).care == state.care)
        let json = #"{"mode":"strict","care":{"off":["water","nonsense"],"ranges":{"eyes":{"low":1,"high":999},"walk":"junk"},"weekdayHours":"x","weekendHours":40}}"#
        let s = try JSONDecoder().decode(BalanceState.self, from: Data(json.utf8))
        #expect(s.mode == .strict)
        #expect(s.care.off == [.water])
        #expect(s.care.range(.eyes) == MinuteRange(15, 90))                  // clamped
        #expect(s.care.range(.walk) == MinuteRange(120, 180))                // the broken one only
        #expect(s.care.weekdayHours == 8 && s.care.weekendHours == 16)
        let broken = try JSONDecoder().decode(BalanceState.self, from: Data(#"{"mode":"strict","care":"junk"}"#.utf8))
        #expect(broken.mode == .strict && broken.care == CareSettings())
    }

    @Test func otherSettingsLoadFieldByField() throws {
        let empty = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(empty == AppSettings())
        #expect(empty.launchAtLogin == nil)
        let json = #"{"apps":{"overrides":{"a":"call","b":"nonsense"},"recent":5},"hotkey":"junk","screen":{"pinned":{"id":"A","name":"Studio"}}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.apps.overrides == ["a": .call] && s.apps.recent.isEmpty)
        #expect(s.hotkey == .standard)
        #expect(s.screen == .pinned(id: "A", name: "Studio"))
        var t = AppSettings()
        t.launchAtLogin = false
        t.screen = .pinned(id: "B", name: "LG")
        #expect(try JSONDecoder().decode(AppSettings.self, from: try JSONEncoder().encode(t)) == t)
    }

    // MARK: App categories

    @Test func appCategoriesOverrideTheAutomaticOnesAndMovingToALooserOneSoftens() throws {
        var r = AppRules()
        #expect(r.category(of: "com.tinyspeck.slackmacgap", automatic: .work) == .work)
        try r.set("com.tinyspeck.slackmacgap", to: .call, automatic: .work, locked: false)
        #expect(r.category(of: "com.tinyspeck.slackmacgap", automatic: .work) == .call)
        #expect(r.softens("com.apple.dt.Xcode", to: .leisure, automatic: .work))
        #expect(r.softens("com.apple.dt.Xcode", to: .untouchable, automatic: .work))
        #expect(!r.softens("com.apple.Music", to: .work, automatic: .leisure))
        #expect(r.softens("com.apple.Music", to: .call, automatic: .leisure))
        #expect(!r.softens("com.tinyspeck.slackmacgap", to: .untouchable, automatic: .work))   // out of a call: tighter
        #expect(!r.softens("com.tinyspeck.slackmacgap", to: nil, automatic: .work))             // back to auto = work
        // Decision A (2026-10-06): «Не трогать» keeps the stage-4 pause, «Созвон» takes it down — into a call is softer.
        try r.set("com.apple.Notes", to: .untouchable, automatic: .work, locked: false)
        #expect(r.softens("com.apple.Notes", to: .call, automatic: .work))
        #expect(AppRules.softens(from: .untouchable, to: .call) && !AppRules.softens(from: .call, to: .untouchable))
        #expect(throws: BalanceRefusal.softeningDuringEscalation) {
            var c = r
            try c.set("com.apple.dt.Xcode", to: .leisure, automatic: .work, locked: true)
        }
        try r.set("com.tinyspeck.slackmacgap", to: nil, automatic: .work, locked: true)
        #expect(r.category(of: "com.tinyspeck.slackmacgap", automatic: .work) == .work)
    }

    @Test func recentAppsAreAShortListOfBundleIdsOnly() {
        var r = AppRules()
        let first = r.noteFront("a")
        let again = r.noteFront("a")
        #expect(first && !again)
        r.noteFront("b")
        r.noteFront("a")
        #expect(r.recent == ["a", "b"])
        for i in 0..<40 { r.noteFront("app\(i)") }
        #expect(r.recent.count == AppRules.recentLimit && r.recent.first == "app39")
        try? r.set("only.overridden", to: .leisure, automatic: .work, locked: false)
        #expect(r.listed.last == "only.overridden")
    }

    // MARK: Hotkey and screen

    @Test func aHotkeyNeedsCommandControlOrOptionAndShowsInTheSystemOrder() {
        let space = HotkeySpec.recorded(keyCode: 49, modifiers: HotkeySpec.control | HotkeySpec.option, characters: " ")
        #expect(space == .standard)
        let k = HotkeySpec.recorded(keyCode: 40, modifiers: HotkeySpec.command | HotkeySpec.shift | HotkeySpec.control, characters: "k")
        #expect(k?.label == "⌃⇧⌘K")
        #expect(HotkeySpec.recorded(keyCode: 40, modifiers: HotkeySpec.shift, characters: "K") == nil)       // ⇧ alone
        #expect(HotkeySpec.recorded(keyCode: 53, modifiers: HotkeySpec.command, characters: "\u{1b}") == nil) // Esc
        #expect(HotkeySpec.recorded(keyCode: 58, modifiers: HotkeySpec.option, characters: "") == nil)       // ⌥ alone
        #expect(HotkeySpec.recorded(keyCode: 122, modifiers: HotkeySpec.option, characters: nil)?.label == "⌥F1")
    }

    @Test func aPinnedScreenWinsWhileConnectedOtherwiseTheActiveOne() {
        #expect(ScreenChoice.follow.pick(ids: ["A", "B"], active: 1) == 1)
        #expect(ScreenChoice.pinned(id: "A", name: "Studio").pick(ids: ["A", "B"], active: 1) == 0)
        #expect(ScreenChoice.pinned(id: "C", name: "Old").pick(ids: ["A", "B"], active: 1) == 1)
    }

    // MARK: The engine follows the settings

    @Test func aNeedSwitchedOffNeitherGrowsNorAsksAndItsRequestGoesQuietly() throws {
        let r = Run(only: .water)
        // Only water is cared about, so nothing else can become due while it is off.
        let base = [Need.stretch, .eyes, .walk, .endOfDay].reduce(CareSettings()) { $0.applying(.need($1, on: false)) }
        try r.engine.setCare(base)
        r.work(minutes: 75)
        #expect(r.engine.state.episode?.need == .water)
        #expect(try r.engine.setCare(base.applying(.need(.water, on: false))) == [.withdraw])
        #expect(r.engine.state.episode == nil)
        #expect(r.engine.pressure(.water) == 0)
        #expect(r.work(minutes: 200).filter(\.isHintOrAsk).isEmpty)
        #expect(r.engine.state.needs[.water]?.sitting == 0)
        #expect(r.engine.leafFatigue == 0)
        // Back on: from scratch.
        #expect(try r.engine.setCare(base).isEmpty)
        #expect(r.engine.pressure(.water) == 0)
        #expect(r.work(minutes: 39).filter(\.isHintOrAsk).isEmpty)
    }

    @Test func endOfDaySwitchedOffNeverAsksAndBackOnCountsTheBudgetFromThen() {
        let r = Run(only: .endOfDay) { $0.weekdayBudget = 3600; $0.needsOff = [.endOfDay] }
        #expect(r.work(minutes: 120).filter(\.isHintOrAsk).isEmpty)
        #expect(r.engine.pressure(.endOfDay) == 0)
        var c = r.engine.config
        c.needsOff = []
        r.engine.updateConfig(c)
        #expect(r.engine.pressure(.endOfDay) < 0.01)                         // not «already over» after 2 hours
        #expect(r.work(minutes: 50).filter(\.isHintOrAsk).isEmpty)
        #expect(abs(r.engine.today(now: r.now).left - 10 * 60) < 5)
        r.work(minutes: 15)
        #expect(r.events.contains(.hint(.endOfDay)) || r.events.contains { if case .ask(.endOfDay, _, _, _) = $0 { true } else { false } })
    }

    @Test func aRestoredRequestOfANeedThatIsOffGoesAtLaunch() throws {
        let r = Run(only: .water)
        r.work(minutes: 75)
        #expect(r.engine.state.episode?.need == .water)
        var saved = r.engine.state
        saved.care = CareSettings().applying(.need(.water, on: false))      // as if switched off before a restart
        let again = BalanceEngine(config: r.engine.config, restoring: saved, rng: SeededRandom(seed: 3), calendar: utc)
        #expect(again.applyCare() == [.withdraw])
        #expect(again.state.episode == nil && again.pressure(.water) == 0)
    }

    @Test func aTighterRangeActsAtOnce() {
        let r = Run(only: .water)
        r.work(minutes: 25)
        #expect(r.events.filter(\.isHintOrAsk).isEmpty)
        var c = r.engine.config
        c.waterMinutes = 15...20
        r.engine.updateConfig(c)
        #expect(r.engine.state.needs[.water]!.threshold <= 20 * 60)
        #expect(r.work(minutes: 4).contains(.hint(.water)))
    }

    @Test func aCallAppKeepsHimQuietAndIdleIsNotRestAnUntouchableAppOnlyKeepsHimQuiet() {
        let call = Run(only: .stretch)
        call.work(minutes: 80) { $0.category = .call }
        #expect(call.events.filter(\.isHintOrAsk).isEmpty)
        call.away(minutes: 4) { $0.category = .call }
        #expect(call.engine.pressure(.stretch) >= 1)                        // a quiet call is not a break

        let quiet = Run(only: .stretch)
        quiet.work(minutes: 80) { $0.category = .untouchable }
        #expect(quiet.events.filter(\.isHintOrAsk).isEmpty)
        quiet.away(minutes: 3.1) { $0.category = .untouchable }
        #expect(quiet.engine.pressure(.stretch) == 0)                       // rest still counts
        #expect(quiet.work(minutes: 1).isEmpty)
    }

    @Test func settingsAreLockedOnlyWhileARequestIsOnStage3Or4() throws {
        let r = Run(only: .stretch)
        _ = try r.engine.setMode(.strict)
        r.workUntilStage(2)
        #expect(!r.engine.settingsLocked)
        r.workUntilStage(3)
        #expect(r.engine.settingsLocked)
        r.away(minutes: 3.1)
        #expect(!r.engine.settingsLocked)
    }

    // MARK: «Дожимал» (decision 18)

    @Test func aRequestThatHadToBePushedCountsOnceUntilItIsRested() throws {
        let r = Run(only: .water)
        r.workUntilStage(2)
        #expect(r.engine.state.day.pushed[.water] == 1)
        _ = r.engine.handle(.snooze)
        r.work(minutes: 12)                                                 // back on the same stage
        #expect(r.engine.state.episode?.stage == 2)
        #expect(r.engine.state.day.pushed[.water] == 1)
        _ = r.engine.handle(.done)
        #expect(r.engine.state.day.credited[.water] == 1)
        r.workUntilStage(2)
        #expect(r.engine.state.day.pushed[.water] == 2)
        // A request rested at stage 1 is not «pushed».
        let easy = Run(only: .eyes)
        easy.workUntilStage(1)
        _ = easy.engine.handle(.done)
        #expect(easy.engine.state.day.pushed[.eyes] == nil)
        #expect(easy.engine.state.day.credited[.eyes] == 1)
    }

    @Test func anEmergencyExitEndsTheRequestAndTheNextOneCountsAgain() throws {
        let r = Run(only: .stretch)
        _ = try r.engine.setMode(.strict)
        r.workUntilStage(3)
        #expect(r.engine.state.day.pushed[.stretch] == 1)
        _ = try r.engine.emergencyExit(reason: "дедлайн", minutes: 15, now: r.now)
        #expect(r.engine.state.day.pushed[.stretch] == 1)
        r.work(minutes: 18)                                                 // comes back at «настаивает» (the debt)
        #expect(r.engine.state.episode?.stage == 2)
        #expect(r.engine.state.day.pushed[.stretch] == 2)
    }

    @Test func olderFilesWithoutTheNewCountersLoad() throws {
        let day = try JSONDecoder().decode(DayStats.self, from: Data(#"{"key":"2026-10-01","credited":{"water":2}}"#.utf8))
        #expect(day.pushed.isEmpty && day.credited[.water] == 2)
        let track = try JSONDecoder().decode(NeedTrack.self, from: Data(#"{"threshold":60}"#.utf8))
        #expect(!track.pushed)
        let state = try JSONDecoder().decode(BalanceState.self, from: Data(#"{"mode":"soft"}"#.utf8))
        #expect(state.streak == 0)
    }

    // MARK: Сегодня / Неделя (decision 18)

    @Test func todayShowsTheStreakTheDayTheBudgetLeftAndWhatHappened() throws {
        let r = Run(only: .water) { $0.weekdayBudget = 8 * 3600 }
        r.work(minutes: 30)
        r.away(minutes: 3.5)
        r.work(minutes: 20)
        let t = r.engine.today(now: r.now)
        #expect(abs(t.streak - 20 * 60) < 2)
        #expect(abs(t.active - 51 * 60) < 5)                                // the first idle minute is still «at the Mac»
        #expect(t.budget == 8 * 3600)
        #expect(t.left == t.budget - t.active)
        #expect(t.tallies.map(\.need) == [.water, .stretch, .eyes, .walk, .endOfDay])
        #expect(t.tallies.first { $0.need == .stretch }?.credited == 1)        // 3.5 minutes away
        #expect(t.deferrals == 0 && t.exits.isEmpty)
    }

    @Test func theWeekHasSevenDaysWithTheirBudgetsAndTotals() throws {
        // Saturday 2026-10-10; the week runs Sunday 4th … Saturday 10th.
        var state = BalanceState(needs: [:], nextMood: 0)
        var mon = DayStats(key: "2026-10-05")
        mon.active = 6 * 3600
        mon.credited = [.water: 3]
        mon.pushed = [.water: 1]
        mon.snoozes = 2
        mon.exits = [EmergencyExit(at: date("2026-10-05T15:00:00Z"), need: .stretch, minutes: 15, reason: "релиз", held: false)]
        var old = DayStats(key: "2026-09-30")                                   // outside the week
        old.credited = [.water: 9]
        var sat = DayStats(key: "2026-10-10")
        sat.active = 2 * 3600
        sat.credited = [.water: 1, .walk: 1]
        sat.busy = 1
        sat.exits = [EmergencyExit(at: date("2026-10-10T11:00:00Z"), need: .walk, minutes: 30, reason: "гости", held: true)]
        state.history = [old, mon]
        state.day = sat
        let w = Summaries.week(state, config: BalanceConfig(), now: date("2026-10-10T12:00:00Z"), calendar: utc)
        #expect(w.days.map(\.key) == ["2026-10-04", "2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08", "2026-10-09", "2026-10-10"])
        #expect(w.days.map { $0.budget / 3600 } == [4, 8, 8, 8, 8, 8, 4])
        #expect(w.days.map { $0.active / 3600 } == [0, 6, 0, 0, 0, 0, 2])
        #expect(w.tallies.first { $0.need == .water } == NeedTally(need: .water, credited: 4, pushed: 1))
        #expect(w.tallies.first { $0.need == .walk }?.credited == 1)
        #expect(w.deferrals == 3)
        #expect(w.exits.map(\.reason) == ["гости", "релиз"])
        // Early in the morning it is still yesterday.
        let early = Summaries.week(state, config: BalanceConfig(), now: date("2026-10-11T03:00:00Z"), calendar: utc)
        #expect(early.days.last?.key == "2026-10-10")
    }

    @Test func theHeroCardMarksSwitchedOffNeeds() {
        let card = HeroCard.make(pressure: { _ in 0.5 }, exitsLeft: 3, exitsMax: 3, mode: .soft, off: [.eyes])
        #expect(card.stats.map(\.off) == [false, false, true, false, false])
    }
}
