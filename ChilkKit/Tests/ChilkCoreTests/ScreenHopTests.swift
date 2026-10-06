import CoreGraphics
import Foundation
import Testing
@testable import ChilkCore

// Slice 6e (SPEC 20–21): he lives on a monitor and leaps to the active one.

struct ScreenHopTests {
    let a = "A", b = "B"

    @Test func atFirstHeSimplyLivesOnTheActiveScreen() {
        var hop = ScreenHop()
        #expect(hop.step(active: a, connected: [a, b], now: 0, busy: false, hidden: false, pinned: nil) == .move(to: a))
        #expect(hop.home == a)
        #expect(hop.step(active: a, connected: [a, b], now: 5, busy: false, hidden: false, pinned: nil) == .stay)
    }

    @Test func heLeapsAfterASecondOnTheOtherScreen() {
        var hop = ScreenHop(home: a)
        #expect(hop.step(active: b, connected: [a, b], now: 10, busy: false, hidden: false, pinned: nil) == .stay)
        #expect(hop.step(active: b, connected: [a, b], now: 10.9, busy: false, hidden: false, pinned: nil) == .stay)
        #expect(hop.step(active: b, connected: [a, b], now: 11.0, busy: false, hidden: false, pinned: nil) == .hop(to: b))
        #expect(hop.home == b)
    }

    @Test func aQuickLookAtTheOtherScreenDoesNothing() {
        var hop = ScreenHop(home: a)
        _ = hop.step(active: b, connected: [a, b], now: 10, busy: false, hidden: false, pinned: nil)
        #expect(hop.step(active: a, connected: [a, b], now: 10.6, busy: false, hidden: false, pinned: nil) == .stay)
        // Back to B: the second starts again.
        #expect(hop.step(active: b, connected: [a, b], now: 10.8, busy: false, hidden: false, pinned: nil) == .stay)
        #expect(hop.step(active: b, connected: [a, b], now: 11.5, busy: false, hidden: false, pinned: nil) == .stay)
        #expect(hop.step(active: b, connected: [a, b], now: 11.8, busy: false, hidden: false, pinned: nil) == .hop(to: b))
    }

    @Test func busyHeWaitsAndLeapsRightAfter() {
        var hop = ScreenHop(home: a)
        _ = hop.step(active: b, connected: [a, b], now: 0, busy: true, hidden: false, pinned: nil)
        #expect(hop.step(active: b, connected: [a, b], now: 30, busy: true, hidden: false, pinned: nil) == .stay)
        #expect(hop.home == a)
        #expect(hop.step(active: b, connected: [a, b], now: 30.1, busy: false, hidden: false, pinned: nil) == .hop(to: b))
    }

    @Test func hiddenHeJustMovesOver() {
        var hop = ScreenHop(home: a)
        _ = hop.step(active: b, connected: [a, b], now: 0, busy: false, hidden: true, pinned: nil)
        #expect(hop.step(active: b, connected: [a, b], now: 1, busy: false, hidden: true, pinned: nil) == .move(to: b))
    }

    @Test func pinnedHeStaysPutAndFollowsOnlyWhileThePinnedScreenIsAway() {
        var hop = ScreenHop(home: a)
        _ = hop.step(active: b, connected: [a, b], now: 0, busy: false, hidden: false, pinned: a)
        #expect(hop.step(active: b, connected: [a, b], now: 5, busy: false, hidden: false, pinned: a) == .stay)
        // The pinned monitor is unplugged: he cannot stay there, so he is on the active one at once.
        #expect(hop.step(active: b, connected: [b], now: 6, busy: false, hidden: false, pinned: a) == .move(to: b))
        // Plugged back in: he leaps home to it (a second later).
        _ = hop.step(active: b, connected: [a, b], now: 7, busy: false, hidden: false, pinned: a)
        #expect(hop.step(active: b, connected: [a, b], now: 8, busy: false, hidden: false, pinned: a) == .hop(to: a))
    }

    @Test func hisScreenUnpluggedHeIsOnTheActiveOneAtOnce() {
        var hop = ScreenHop(home: a)
        #expect(hop.step(active: b, connected: [b], now: 0, busy: true, hidden: false, pinned: nil) == .move(to: b))
    }
}

struct HopArcTests {
    @Test func theFlightTakesLongerTheFartherItGoes() {
        let short = HopArc(from: CGPoint(x: 1300, y: 400), to: CGPoint(x: 1500, y: 400))
        let long = HopArc(from: CGPoint(x: 1300, y: 400), to: CGPoint(x: 4600, y: 600))
        let mid = HopArc(from: CGPoint(x: 1300, y: 400), to: CGPoint(x: 2500, y: 400))
        #expect(abs(short.flight - 0.85) < 0.01)
        #expect(long.flight == 1.4)
        #expect(mid.flight > short.flight && mid.flight < long.flight)
        #expect(abs(long.total - (HopArc.crouch + 1.4 + HopArc.land)) < 1e-9)
    }

    @Test func itStartsAndEndsWhereItShouldAndArcsAboveBoth() {
        let arc = HopArc(from: CGPoint(x: 1300, y: 400), to: CGPoint(x: 2900, y: 500))
        #expect(arc.point(at: 0) == arc.from && arc.point(at: HopArc.crouch) == arc.from)
        #expect(arc.point(at: HopArc.crouch + arc.flight) == arc.to && arc.point(at: arc.total) == arc.to)
        let top = stride(from: 0.0, through: arc.total, by: 0.01).map { arc.point(at: $0).y }.max()!
        #expect(top > 500 + 80 && top < 500 + 360)                      // AppKit y-up: above the higher end
        let xs = stride(from: 0.0, through: arc.total, by: 0.01).map { arc.point(at: $0).x }
        #expect(zip(xs, xs.dropFirst()).allSatisfy { $0 <= $1 })        // never goes back
    }
}

@MainActor
struct LeapCharacterTests {
    let m = Metrics.standard

    @Test func heCrouchesFliesWithTuckedHandsAndLandsSquashed() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 61))
        for _ in 0..<60 { sim.step(dt: 1.0 / 60, pointer: nil) }
        let x0 = sim.positionX
        let arc = HopArc(from: .zero, to: CGPoint(x: 1600, y: 0))
        sim.perform(.leap(seconds: arc.total, dir: -1))
        var crouched = false, tucked = 0, flutter = 0.0, landed = false
        var t = 0.0
        while t < arc.total + 0.3 {
            sim.step(dt: 1.0 / 60, pointer: nil)
            t += 1.0 / 60
            let p = sim.pose
            #expect(sim.passesClicks || t > arc.total)
            if t < HopArc.crouch + 0.05, p.scaleY < 0.965 { crouched = true }
            if t > HopArc.crouch + 0.1, t < HopArc.crouch + arc.flight - 0.1 {
                if p.hands.count == 2, p.hands.allSatisfy({ $0.arm && abs($0.angle) > 1.6 }) { tucked += 1 }
                flutter = max(flutter, abs(p.leafAngle))
            }
            if t > arc.total - HopArc.land, p.scaleY < 0.965 { landed = true }
        }
        #expect(crouched && landed && tucked > 20 && flutter > 0.15)
        #expect(abs(sim.positionX - x0) < 1)                            // the panel flies, not he inside it
        #expect(sim.act == nil)
    }
}
