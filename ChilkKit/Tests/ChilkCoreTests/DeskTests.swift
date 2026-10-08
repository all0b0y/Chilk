import Foundation
import Testing
@testable import ChilkCore

// Slice 9d (SPEC «Срез 9», decisions 30–31): Chilk and the desktops (Spaces).

struct DeskKeeperTests {
    typealias S = DeskKeeper.Situation

    @Test func followingHeArrivesOnEveryNewDesktop() {
        var k = DeskKeeper()
        #expect(k.step(S(mode: .follow, onActive: true, now: 0)) == .stay)
        // A swipe: his window went away with the old desktop.
        #expect(k.step(S(mode: .follow, onActive: false, now: 1)) == .arrive)
        #expect(k.step(S(mode: .follow, onActive: true, now: 1.1)) == .stay)
        // A swipe into a full-screen app is a desktop like any other.
        #expect(k.step(S(mode: .follow, onActive: false, now: 5)) == .arrive)
    }

    @Test func draggedOrInALeapHeArrivesRightAfter() {
        var k = DeskKeeper()
        #expect(k.step(S(mode: .follow, onActive: false, canMove: false, now: 0)) == .stay)
        #expect(k.step(S(mode: .follow, onActive: false, canMove: false, now: 3)) == .stay)
        #expect(k.step(S(mode: .follow, onActive: false, now: 3.1)) == .arrive)
    }

    @Test func sharedOverlaysPutHimOnEveryDesktopAsBefore() {
        var k = DeskKeeper()
        #expect(k.step(S(mode: .follow, onActive: true, everywhere: true, now: 0)) == .allDesks)
        #expect(k.everywhere)
        #expect(k.step(S(mode: .follow, onActive: true, everywhere: true, now: 1)) == .stay)
        #expect(k.step(S(mode: .follow, onActive: false, everywhere: true, now: 2)) == .stay)
        // Over: one desktop again — the one the user is on.
        #expect(k.step(S(mode: .follow, onActive: true, now: 3)) == .oneDeskAgain)
        #expect(!k.everywhere)
        #expect(k.step(S(mode: .follow, onActive: true, now: 3.1)) == .stay)
    }

    @Test func onOneDeskHeStaysHomeWhileTheUserIsElsewhere() {
        var k = DeskKeeper()
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: true, now: 0)) == .stay)
        for t in stride(from: 1.0, through: 60, by: 0.1) {
            #expect(k.step(S(mode: .oneDesk, onActive: false, homeActive: false, now: t)) == .stay)
        }
        #expect(!k.visiting)
    }

    @Test func anErrandBringsHimOverAndHeGoesHomeAfterIt() {
        var k = DeskKeeper()
        _ = k.step(S(mode: .oneDesk, onActive: false, homeActive: false, now: 0))
        #expect(k.step(S(mode: .oneDesk, onActive: false, homeActive: false, errand: true, now: 1)) == .arrive)
        #expect(k.visiting)
        // Talking for a while.
        for t in stride(from: 1.1, through: 20, by: 0.1) {
            #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, errand: true, now: t)) == .stay)
        }
        // Free: he lingers 1.5 s (the next errand often comes right away), dives, and goes home.
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 21)) == .stay)
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 22.4)) == .stay)
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 22.5)) == .leave)
        #expect(k.isLeaving)
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 22.8)) == .stay)
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 22.95)) == .sendHome)
        #expect(!k.visiting && !k.isLeaving)
        // At home now (not on the active desktop): nothing more.
        #expect(k.step(S(mode: .oneDesk, onActive: false, homeActive: false, now: 23)) == .stay)
    }

    @Test func aNewErrandDuringTheDiveBringsHimBackOut() {
        var k = DeskKeeper()
        _ = k.step(S(mode: .oneDesk, onActive: true, homeActive: false, errand: true, now: 0))
        _ = k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 1))
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 2.5)) == .leave)
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, errand: true, now: 2.7)) == .stopLeaving)
        #expect(!k.isLeaving && k.visiting)
        // And the linger starts over once it is done.
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 10)) == .stay)
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 11.5)) == .leave)
    }

    @Test func theErrandFollowsTheUserToTheNextDesktop() {
        var k = DeskKeeper()
        #expect(k.step(S(mode: .oneDesk, onActive: false, homeActive: false, errand: true, now: 0)) == .arrive)
        _ = k.step(S(mode: .oneDesk, onActive: true, homeActive: false, errand: true, now: 0.1))
        // Swiped to a third desktop mid-conversation.
        #expect(k.step(S(mode: .oneDesk, onActive: false, homeActive: false, errand: true, now: 3)) == .arrive)
        // Swiped home mid-conversation: he comes along and is home.
        #expect(k.step(S(mode: .oneDesk, onActive: false, homeActive: true, errand: true, now: 5)) == .arrive)
        #expect(!k.visiting)
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: true, now: 9)) == .stay)
    }

    @Test func theUserLeftTheVisitedDesktopSoHeGoesHomeUnseen() {
        var k = DeskKeeper()
        _ = k.step(S(mode: .oneDesk, onActive: true, homeActive: false, errand: true, now: 0))
        _ = k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 1))
        #expect(k.step(S(mode: .oneDesk, onActive: false, homeActive: false, now: 1.5)) == .sendHome)
        #expect(!k.visiting)
        #expect(k.step(S(mode: .oneDesk, onActive: false, homeActive: false, now: 2)) == .stay)
    }

    @Test func swipedHomeWhileHeIsElsewhereHePeeksOutThere() {
        var k = DeskKeeper()
        _ = k.step(S(mode: .oneDesk, onActive: true, homeActive: false, errand: true, now: 0))
        _ = k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 1))
        #expect(k.step(S(mode: .oneDesk, onActive: false, homeActive: true, now: 1.2)) == .arrive)
        #expect(!k.visiting)
    }

    @Test func afterASharedOverlayOnAnotherDesktopHeGoesHome() {
        var k = DeskKeeper()
        _ = k.step(S(mode: .oneDesk, onActive: true, homeActive: true, now: 0))
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, everywhere: true, now: 1)) == .allDesks)
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 60)) == .oneDeskAgain)
        #expect(k.visiting)
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 60.1)) == .stay)
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 61.6)) == .leave)
    }

    @Test func switchingToFollowStopsTheWayHomeAndHeComesAlong() {
        var k = DeskKeeper()
        _ = k.step(S(mode: .oneDesk, onActive: true, homeActive: false, errand: true, now: 0))
        _ = k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 1))
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 2.5)) == .leave)
        #expect(k.step(S(mode: .follow, onActive: true, now: 2.6)) == .stopLeaving)
        #expect(k.step(S(mode: .follow, onActive: true, now: 2.7)) == .stay)
        // Living at home and switched to follow while the user is elsewhere: he comes.
        var j = DeskKeeper()
        _ = j.step(S(mode: .oneDesk, onActive: false, homeActive: false, now: 0))
        #expect(j.step(S(mode: .follow, onActive: false, now: 1)) == .arrive)
    }

    @Test func whatCountsAsAnErrand() {
        // Waits for the user: a bubble with buttons or with no end (a request, a due timer / reminder).
        #expect(DeskKeeper.onErrand(standOut: .peek, bubbleWaits: true))
        #expect(DeskKeeper.onErrand(standOut: .docked, bubbleWaits: true))
        #expect(DeskKeeper.onErrand(standOut: .out, bubbleWaits: false))          // a conversation listening, a card
        #expect(DeskKeeper.onErrand(standOut: .center, bubbleWaits: false))       // stage 3–4
        #expect(!DeskKeeper.onErrand(standOut: .docked, bubbleWaits: false))
        #expect(!DeskKeeper.onErrand(standOut: .away, bubbleWaits: false))        // in the popover or the notebook
        #expect(!DeskKeeper.onErrand(standOut: .lurk, bubbleWaits: false))        // hidden, peeking from behind the edge
        // A request's pantomime (a stage-0 hint, the intro before the bubble) is an errand; a dance or a leap is not.
        #expect(DeskKeeper.onErrand(standOut: .docked, bubbleWaits: false, act: .drink))
        #expect(DeskKeeper.onErrand(standOut: .docked, bubbleWaits: false, act: .hops))
        #expect(!DeskKeeper.onErrand(standOut: .docked, bubbleWaits: false, act: .dance(seconds: 5)))
        #expect(!DeskKeeper.onErrand(standOut: .docked, bubbleWaits: false, act: .leap(seconds: 1, dir: 1)))
    }

    @MainActor @Test func shortLinesAndACheerAreNoErrandButWaitingBubblesAre() {
        func errand(_ sim: CharacterSim) -> Bool {
            DeskKeeper.onErrand(standOut: sim.standOut, bubbleWaits: sim.bubbleWaits, act: sim.act)
        }
        // A «спасибо» / clock line: out at the edge (`.peek`) with a 3.5 s bubble.
        let thanks = CharacterSim(metrics: .standard)
        thanks.standOut = .peek
        thanks.say("Спасибо!", duration: 3.5)
        thanks.step(dt: 1.0 / 60, pointer: nil)
        #expect(thanks.isTalking && !errand(thanks))
        // The cheer (6a): `.peek` and the jump, no bubble.
        let cheer = CharacterSim(metrics: .standard)
        cheer.standOut = .peek
        cheer.perform(.cheer)
        cheer.step(dt: 1.0 / 60, pointer: nil)
        #expect(!errand(cheer))
        // A call's own line (an ears notice uses it too) without a conversation: short, no buttons.
        let called = CharacterSim(metrics: .standard)
        called.call(line: "Слушаю")
        called.step(dt: 1.0 / 60, pointer: nil)
        #expect(called.isTalking && !errand(called))
        // A request's bubble (buttons), a due timer's (no end): they wait for the user.
        let request = CharacterSim(metrics: .standard)
        request.standOut = .peek
        request.say("Глоток воды?", buttons: ["Попил", "Позже"])
        request.step(dt: 1.0 / 60, pointer: nil)
        #expect(errand(request))
        let timer = CharacterSim(metrics: .standard)
        timer.standOut = .peek
        timer.say("Таймер: чай", duration: .infinity)
        for _ in 0..<600 { timer.step(dt: 1.0 / 60, pointer: nil) }
        #expect(errand(timer))
        // A short line with a «Подробнее» button (a long answer) waits too, but it comes inside a conversation anyway.
        let ended = CharacterSim(metrics: .standard)
        ended.say("Готово", duration: 1)
        for _ in 0..<120 { ended.step(dt: 1.0 / 60, pointer: nil) }
        #expect(!ended.bubbleWaits)
    }

    @Test func swipedAwayMidDiveWhileHeCannotMoveHeGoesHomeOnceHeMay() {
        // The dive started, then the user swiped away while he was held (dragged / a leap): the way home waits for it.
        var k = DeskKeeper()
        _ = k.step(S(mode: .oneDesk, onActive: true, homeActive: false, errand: true, now: 0))
        _ = k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 1))
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 2.5)) == .leave)
        #expect(k.step(S(mode: .oneDesk, onActive: false, homeActive: false, canMove: false, now: 2.6)) == .stay)
        #expect(k.isLeaving)
        #expect(k.step(S(mode: .oneDesk, onActive: false, homeActive: false, canMove: false, now: 5)) == .stay)
        #expect(k.step(S(mode: .oneDesk, onActive: false, homeActive: false, now: 5.1)) == .sendHome)
        #expect(!k.isLeaving && !k.visiting)
    }

    @Test func heldMidDiveOnTheVisitedDesktopTheDiveStartsOver() {
        // The popover (or a drag) takes him during the dive: no move home under it; after it the linger starts over.
        var k = DeskKeeper()
        _ = k.step(S(mode: .oneDesk, onActive: true, homeActive: false, errand: true, now: 0))
        _ = k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 1))
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 2.5)) == .leave)
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, canMove: false, now: 2.6)) == .stopLeaving)
        for t in stride(from: 2.7, through: 30, by: 0.1) {
            #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, canMove: false, now: t)) == .stay)
        }
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 31)) == .stay)
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 32.5)) == .leave)
        #expect(k.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 33)) == .sendHome)
    }

    @Test func anOverlayDuringAnArrivalWinsAndHeStaysWhereTheUserIs() {
        // `.arrive` sent (the window moves on the next frame: canMove is false meanwhile), then the shade comes.
        var k = DeskKeeper()
        #expect(k.step(S(mode: .follow, onActive: false, now: 0)) == .arrive)
        #expect(k.step(S(mode: .follow, onActive: false, everywhere: true, canMove: false, now: 0.02)) == .allDesks)
        #expect(k.step(S(mode: .follow, onActive: true, everywhere: true, now: 0.1)) == .stay)
        #expect(k.step(S(mode: .follow, onActive: true, now: 9)) == .oneDeskAgain)
        // One desk, an errand's arrival interrupted by stage 3: on every desktop, then home after it.
        var j = DeskKeeper()
        #expect(j.step(S(mode: .oneDesk, onActive: false, homeActive: false, errand: true, now: 0)) == .arrive)
        #expect(j.step(S(mode: .oneDesk, onActive: false, homeActive: false, errand: true, everywhere: true,
                         canMove: false, now: 0.02)) == .allDesks)
        #expect(j.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 20)) == .oneDeskAgain)
        #expect(j.visiting)
        #expect(j.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 20.1)) == .stay)
        #expect(j.step(S(mode: .oneDesk, onActive: true, homeActive: false, now: 21.6)) == .leave)
    }

    @Test func withoutFramesTheWatchdogAloneBringsHimForAnErrand() {
        // His display link stopped (his window is on a desktop nobody sees): only the 3 Hz watchdog steps the keeper.
        #expect(DeskKeeper.needsWatchdog(onActive: false, oneDesk: false))
        #expect(DeskKeeper.needsWatchdog(onActive: true, oneDesk: true))
        #expect(!DeskKeeper.needsWatchdog(onActive: true, oneDesk: false))
        var k = DeskKeeper()
        var onActive = false
        var commands: [(Double, DeskKeeper.Command)] = []
        let dt = DeskKeeper.watchdogInterval
        for i in 0..<180 {                                       // 60 s at 3 Hz
            let t = Double(i) * dt
            let errand = t >= 10 && t < 18                       // a request at 10 s, answered at 18 s
            let c = k.step(S(mode: .oneDesk, onActive: onActive, homeActive: false, errand: errand, now: t))
            if c != .stay { commands.append((t, c)) }
            if c == .arrive { onActive = true }
            if c == .sendHome { onActive = false }
        }
        #expect(commands.map(\.1) == [.arrive, .leave, .sendHome])
        #expect(commands[0].0 - 10 < dt + 1e-9)                  // within one watchdog tick
        // A stale read at the notification («he is here») is corrected by a re-read: then he comes.
        var f = DeskKeeper()
        #expect(f.step(S(mode: .follow, onActive: true, now: 0)) == .stay)    // stale, at the notification
        #expect(f.step(S(mode: .follow, onActive: false, now: DeskKeeper.rereadsAfterSwitch[0])) == .arrive)
    }

    @Test func driving60SecondsOfAVisitAtTenHertzEndsHomeOnce() {
        // A whole visit as the app drives it: the errand lasts 8 s, then he goes home exactly once.
        var k = DeskKeeper()
        var onActive = false
        var commands: [DeskKeeper.Command] = []
        for i in 0..<600 {
            let t = Double(i) / 10
            let errand = t >= 5 && t < 13
            let c = k.step(S(mode: .oneDesk, onActive: onActive, homeActive: false, errand: errand, now: t))
            if c != .stay { commands.append(c) }
            if c == .arrive { onActive = true }
            if c == .sendHome { onActive = false }
        }
        #expect(commands == [.arrive, .leave, .sendHome])
    }
}

struct ScreenHopErrandTests {
    let a = "A", b = "B"

    @Test func pinnedHeComesToTheActiveMonitorForAnErrandAtOnceEvenBusy() {
        var hop = ScreenHop(home: a)
        #expect(hop.step(active: b, connected: [a, b], now: 0, busy: false, hidden: false, pinned: a) == .stay)
        #expect(hop.step(active: b, connected: [a, b], now: 1, busy: true, hidden: false, pinned: a, errand: true) == .visit(to: b))
        #expect(hop.home == b)
        #expect(hop.step(active: b, connected: [a, b], now: 5, busy: true, hidden: false, pinned: a, errand: true) == .stay)
        // Done and free: after a second he leaps home to the pinned monitor.
        #expect(hop.step(active: b, connected: [a, b], now: 9, busy: false, hidden: false, pinned: a) == .stay)
        #expect(hop.step(active: b, connected: [a, b], now: 10, busy: false, hidden: false, pinned: a) == .hop(to: a))
        #expect(hop.home == a)
    }

    @Test func anErrandOnThePinnedMonitorItselfKeepsHimThere() {
        var hop = ScreenHop(home: a)
        #expect(hop.step(active: a, connected: [a, b], now: 0, busy: true, hidden: false, pinned: a, errand: true) == .stay)
    }

    @Test func followingTheErrandChangesNothing() {
        // Not pinned: the 6e rule — busy, he waits for the end of it.
        var hop = ScreenHop(home: a)
        _ = hop.step(active: b, connected: [a, b], now: 0, busy: true, hidden: false, pinned: nil, errand: true)
        #expect(hop.step(active: b, connected: [a, b], now: 5, busy: true, hidden: false, pinned: nil, errand: true) == .stay)
        #expect(hop.step(active: b, connected: [a, b], now: 5.1, busy: false, hidden: false, pinned: nil) == .hop(to: b))
    }

    @Test func theErrandFollowsTheUserBackToThePinnedMonitor() {
        var hop = ScreenHop(home: a)
        #expect(hop.step(active: b, connected: [a, b], now: 0, busy: true, hidden: false, pinned: a, errand: true) == .visit(to: b))
        #expect(hop.step(active: a, connected: [a, b], now: 2, busy: true, hidden: false, pinned: a, errand: true) == .visit(to: a))
        #expect(hop.step(active: a, connected: [a, b], now: 9, busy: false, hidden: false, pinned: a) == .stay)
    }
}

struct ScreenHopVisitGoneTests {
    let a = "A", b = "B", c = "C"

    @Test func thePinnedMonitorUnpluggedAnErrandIsNoVisit() {
        // Pinned to C, which is gone: he lives by the follow rule; an errand does not «visit», it waits like 6e.
        var hop = ScreenHop(home: a)
        let first = hop.step(active: b, connected: [a, b], now: 0, busy: true, hidden: false, pinned: c, errand: true)
        #expect(first == .stay)
        #expect(hop.step(active: b, connected: [a, b], now: 5, busy: true, hidden: false, pinned: c, errand: true) == .stay)
        #expect(hop.step(active: b, connected: [a, b], now: 5.1, busy: false, hidden: false, pinned: c) == .hop(to: b))
    }

    @Test func theActiveMonitorUnpluggedHeStaysOnThePinnedOne() {
        // Pinned to A; the «active» monitor is gone (not connected): no visit, he stays home.
        var hop = ScreenHop(home: a)
        #expect(hop.step(active: c, connected: [a, b], now: 0, busy: true, hidden: false, pinned: a, errand: true) == .stay)
        #expect(hop.home == a)
        // Visiting B, then B is unplugged mid-errand: back on the pinned monitor at once (his monitor is gone).
        #expect(hop.step(active: b, connected: [a, b], now: 1, busy: true, hidden: false, pinned: a, errand: true) == .visit(to: b))
        #expect(hop.step(active: b, connected: [a], now: 2, busy: true, hidden: false, pinned: a, errand: true) == .move(to: a))
        #expect(hop.home == a)
    }
}

struct DeskSettingTests {
    @Test func oneDeskIsOffByDefaultAndSurvivesARoundTrip() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"screen":"follow"}"#.utf8))
        #expect(!old.oneDesk)
        let junk = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"oneDesk":"yes"}"#.utf8))
        #expect(!junk.oneDesk)
        var s = AppSettings()
        s.oneDesk = true
        let back = try JSONDecoder().decode(AppSettings.self, from: try JSONEncoder().encode(s))
        #expect(back.oneDesk && back == s)
    }
}
