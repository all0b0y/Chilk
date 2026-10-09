import Foundation
import Testing
@testable import ChilkCore

/// Slice 10 (SPEC «Срез 10», Б8, decisions 15–17): he dozes off only when neither the user's input nor his own deed has
/// happened for three minutes; a wait without a time limit keeps him awake ten.
struct SliceTenSleepTests {
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    /// Steps the tracker once a second over `[from, to)`; `lastInput` is the second of the user's last input.
    func run(_ p: inout PresenceTracker, from: Int, to: Int, lastInput: Int, deed: PresenceTracker.Deed) -> [(Int, PresenceTracker.Event)] {
        var out: [(Int, PresenceTracker.Event)] = []
        for s in from..<to {
            let idle = Double(max(0, s - lastInput))
            if let e = p.update(idleSeconds: idle, now: t0.addingTimeInterval(Double(s)), deed: deed) { out.append((s, e)) }
        }
        return out
    }

    @Test func aWarmUpWithoutTheMouseKeepsHimAwakeAndTheThreeMinutesCountFromItsEnd() {
        var p = PresenceTracker()
        // Five minutes of a warm-up, the user does the exercises: no input since 0.
        #expect(run(&p, from: 0, to: 300, lastInput: 0, deed: .busy).isEmpty)
        // «Готово!» at 300: still awake for three minutes, asleep at 300 + 180.
        let after = run(&p, from: 300, to: 600, lastInput: 0, deed: .none)
        #expect(after.count == 1)
        #expect(after.first?.0 == 299 + 180)
        #expect(after.first?.1 == .wentAway)
    }

    @Test func noWelcomeBackAfterHisDeed() {
        var p = PresenceTracker()
        _ = run(&p, from: 0, to: 300, lastInput: 0, deed: .busy)
        // The user touches the mouse a minute after the warm-up: they never went away — no «returned».
        #expect(run(&p, from: 300, to: 420, lastInput: 0, deed: .none).isEmpty)
        #expect(run(&p, from: 420, to: 500, lastInput: 420, deed: .none).isEmpty)
        #expect(!p.isAway)
    }

    @Test func aConversationIsBeingHereEvenWithoutInput() {
        var p = PresenceTracker()
        let away = run(&p, from: 0, to: 400, lastInput: 0, deed: .none)
        #expect(away.map(\.1) == [.wentAway])
        // «Чилк, …» by voice at 400: the user is back, the absence counted from the last input.
        let back = run(&p, from: 400, to: 401, lastInput: 0, deed: .talking)
        #expect(back.map(\.1) == [.returned(after: 400)])
        // A long talk without the mouse never puts him to sleep; three minutes after it — asleep.
        #expect(run(&p, from: 401, to: 700, lastInput: 0, deed: .talking).isEmpty)
        let later = run(&p, from: 700, to: 900, lastInput: 0, deed: .none)
        #expect(later.map(\.0) == [699 + 180])
        #expect(later.map(\.1) == [.wentAway])
    }

    @Test func hisOwnDeedWakesHimWhileTheUserIsAwayAndHeDozesAgainAfter() {
        var p = PresenceTracker()
        _ = run(&p, from: 0, to: 200, lastInput: 0, deed: .none)            // away at 180
        #expect(p.isDozing)
        // A dance to the music at 200–230: he is up, the user still away — no greeting.
        let dance = run(&p, from: 200, to: 230, lastInput: 0, deed: .busy)
        #expect(dance.map(\.1) == [.roused])
        #expect(p.isAway && !p.isDozing)
        let after = run(&p, from: 230, to: 500, lastInput: 0, deed: .none)
        #expect(after.map(\.1) == [.dozedOff])
        #expect(after.first?.0 == 229 + 180)
        // Back at 600: the absence still counts from the last input.
        let back = run(&p, from: 600, to: 601, lastInput: 600, deed: .none)
        #expect(back.map(\.1) == [.returned(after: 600)])
    }

    @Test func aWaitWithoutATimeLimitKeepsHimAwakeTenMinutesThenHeDozesBesideIt() {
        var p = PresenceTracker()
        let events = run(&p, from: 0, to: 700, lastInput: 0, deed: .waiting)
        #expect(events.map(\.0) == [600])
        #expect(events.map(\.1) == [.wentAway])
        // The card is still there; input wakes him (the greeting is the app's business).
        #expect(run(&p, from: 700, to: 701, lastInput: 700, deed: .waiting).map(\.1) == [.returned(after: 700)])
    }

    @Test func theTenMinutesCountFromTheLaterOfInputAndTheWaitsStart() {
        var p = PresenceTracker()
        // The card appears at 0; the user moves the mouse at 300 and leaves: asleep at 900, not 600.
        #expect(run(&p, from: 0, to: 300, lastInput: 0, deed: .waiting).isEmpty)
        let events = run(&p, from: 300, to: 1000, lastInput: 300, deed: .waiting)
        #expect(events.map(\.0) == [900])
    }

    @Test func aWaitThatBeginsWhileTheUserIsAwayWakesHimForTenMinutes() {
        var p = PresenceTracker()
        _ = run(&p, from: 0, to: 1000, lastInput: 0, deed: .none)
        // A timed message at 1000 (the user is out): he wakes beside it, dozes again ten minutes later.
        let events = run(&p, from: 1000, to: 1700, lastInput: 0, deed: .waiting)
        #expect(events.map(\.1) == [.roused, .dozedOff])
        #expect(events.map(\.0) == [1000, 1600])
    }

    @Test func aConversationOverAWaitingCardGivesTheCardFreshTenMinutes() {
        var p = PresenceTracker()
        // The card came in a conversation (0–60), then the talk ended: ten minutes from 60.
        #expect(run(&p, from: 0, to: 60, lastInput: 0, deed: .talking).isEmpty)
        let events = run(&p, from: 60, to: 800, lastInput: 0, deed: .waiting)
        #expect(events.map(\.0) == [660])
    }

    @Test func withoutADeedNothingChanges() {
        var p = PresenceTracker()
        let events = run(&p, from: 0, to: 400, lastInput: 0, deed: .none)
        #expect(events.map(\.0) == [180])
        #expect(events.map(\.1) == [.wentAway])
    }
}
