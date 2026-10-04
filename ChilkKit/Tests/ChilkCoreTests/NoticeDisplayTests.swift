import ChilkCore
import Testing

/// SPEC «Режиссёр вмешательств», decision 2026-10-04: a due timer bubble waits while the user is away and goes
/// 4.4 s after their first input once it is on screen; a click on Chilk closes it at once.
@Suite("Timer notice display")
struct NoticeDisplayTests {
    /// Steps every 0.5 s like the app; `lastInput` = when the user last touched mouse/keyboard; returns the first action.
    private func run(_ display: inout NoticeDisplay, from: Double, to: Double, lastInput: (Double) -> Double,
                     locked: (Double) -> Bool = { _ in false }, next: String? = "tea") -> (Double, NoticeDisplay.Action)? {
        var t = from
        while t <= to {
            let action = display.step(now: t, idle: t - lastInput(t), locked: locked(t), canPresent: true, next: next)
            if action != .none { return (t, action) }
            t += 0.5
        }
        return nil
    }

    @Test func itStaysWhileTheUserIsAway() {
        var d = NoticeDisplay()
        #expect(d.step(now: 0, idle: 600, locked: false, canPresent: true, next: "tea") == .show("tea"))
        #expect(run(&d, from: 0.5, to: 3_600, lastInput: { _ in -600 }) == nil)
        #expect(d.showing == "tea")
    }

    @Test func theFirstInputAfterItAppearsStartsTheCountdown() throws {
        var d = NoticeDisplay()
        _ = d.step(now: 0, idle: 600, locked: false, canPresent: true, next: "tea")
        let result = try #require(run(&d, from: 0.5, to: 300, lastInput: { $0 >= 100 ? 100 : -600 }))
        #expect(result.1 == .dismiss("tea"))
        #expect(result.0 >= 104.4 && result.0 < 105)
        #expect(d.showing == nil)
    }

    @Test func aBusyUserStillGetsTheFullCountdown() throws {
        var d = NoticeDisplay()
        _ = d.step(now: 0, idle: 0.2, locked: false, canPresent: true, next: "tea")
        let result = try #require(run(&d, from: 0.5, to: 60, lastInput: { $0 - 0.2 }))
        #expect(result.0 >= 4.4 && result.0 < 5.5)
    }

    @Test func inputBeforeTheBubbleDoesNotCountAsSeen() {
        var d = NoticeDisplay()
        _ = d.step(now: 0, idle: 1, locked: false, canPresent: true, next: "tea")
        #expect(run(&d, from: 0.5, to: 600, lastInput: { _ in -1 }) == nil)
    }

    @Test func typingThePasswordOnTheLockScreenIsNotSeeingIt() throws {
        var d = NoticeDisplay()
        _ = d.step(now: 0, idle: 600, locked: false, canPresent: true, next: "tea")
        let input: (Double) -> Double = { t in t >= 70 ? 70 : (t >= 60 ? 60 : -600) }    // password at 60, mouse at 70
        let result = try #require(run(&d, from: 0.5, to: 300, lastInput: input, locked: { $0 >= 50 && $0 < 62 }))
        #expect(result.0 >= 74.4 && result.0 < 75)
    }

    @Test func itWaitsForAFreeStageAnUnlockedScreenAndADueTimer() {
        var d = NoticeDisplay()
        #expect(d.step(now: 0, idle: 0, locked: false, canPresent: false, next: "tea") == .none)
        #expect(d.step(now: 1, idle: 0, locked: true, canPresent: true, next: "tea") == .none)
        #expect(d.step(now: 2, idle: 0, locked: false, canPresent: true, next: nil) == .none)
        #expect(d.showing == nil)
    }

    @Test func aClickClosesItAtOnce() {
        var d = NoticeDisplay()
        #expect(d.clicked() == .none)
        _ = d.step(now: 0, idle: 600, locked: false, canPresent: true, next: "tea")
        #expect(d.clicked() == .dismiss("tea"))
        #expect(d.showing == nil)
    }

    @Test func aConversationTakingTheStageBringsItBackUnseen() {
        var d = NoticeDisplay()
        _ = d.step(now: 0, idle: 600, locked: false, canPresent: true, next: "tea")
        d.interrupted()
        #expect(d.showing == nil)
        #expect(d.step(now: 30, idle: 0.3, locked: false, canPresent: true, next: "tea") == .show("tea"))
    }
}
