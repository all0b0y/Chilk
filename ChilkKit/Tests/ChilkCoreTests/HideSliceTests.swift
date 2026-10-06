import CoreGraphics
import Foundation
import Testing
@testable import ChilkCore

// Slice 6d (grilling 2026-10-06, decisions 17–19): hiding behind the screen edge.

struct HideoutTests {
    @Test func hidingSetsThePeekClockAndShowingEndsIt() {
        var h = Hideout()
        var rng = SeededRandom(seed: 1)
        #expect(!h.hidden)
        #expect(!h.tick(seconds: 3000, working: true, quiet: false, rng: &rng))      // not hidden: never peeks
        h.hide(rng: &rng)
        #expect(h.hidden && Hideout.peekEvery.contains(h.peekIn))
        h.show()
        #expect(!h.hidden)
    }

    @Test func hePeeksAfterTwentyToFortyMinutesOfWorkOnly() {
        var h = Hideout()
        var rng = SeededRandom(seed: 2)
        h.hide(rng: &rng)
        let due = h.peekIn
        var peeks = 0
        for _ in 0..<5000 { if h.tick(seconds: 1, working: false, quiet: false, rng: &rng) { peeks += 1 } }
        #expect(peeks == 0)                                          // away from the Mac: no clock
        var at = 0
        for s in 1...Int(due) + 2 where h.tick(seconds: 1, working: true, quiet: false, rng: &rng) { at = s; peeks += 1 }
        #expect(peeks == 1 && abs(Double(at) - due) <= 1)
        #expect(Hideout.peekEvery.contains(h.peekIn))                // the next one, 20–40 min later
    }

    @Test func aCallOrFullScreenDelaysThePeekUntilItEnds() {
        var h = Hideout(hidden: true, peekIn: 10)
        var rng = SeededRandom(seed: 3)
        for _ in 0..<600 { #expect(!h.tick(seconds: 1, working: true, quiet: true, rng: &rng)) }
        #expect(h.tick(seconds: 1, working: true, quiet: false, rng: &rng))
        h.postpone(60)                                               // Chilk was busy: try again in a minute
        #expect(h.peekIn == 60)
    }

    @Test func theChanceToStayGrowsWithTheStage() {
        #expect([0, 1, 2, 3, 4].map(Hideout.chance(stage:)) == [0.05, 0.25, 0.5, 0.8, 0.99])
        #expect(Hideout.chance(stage: 7) == 0.99)
        #expect(Hideout.stays(stage: 0, roll: 0.04) && !Hideout.stays(stage: 0, roll: 0.06))
        #expect(Hideout.stays(stage: 4, roll: 0.985) && !Hideout.stays(stage: 4, roll: 0.995))
        var rng = SeededRandom(seed: 4)
        for stage in 0...4 {
            var stayed = 0
            for _ in 0..<20000 where Hideout.stays(stage: stage, roll: rng.next()) { stayed += 1 }
            #expect(abs(Double(stayed) / 20000 - Hideout.chance(stage: stage)) < 0.015, "stage \(stage)")
        }
    }

    @Test func itIsSavedFieldByField() throws {
        let h = Hideout(hidden: true, peekIn: 777)
        let back = try JSONDecoder().decode(Hideout.self, from: try JSONEncoder().encode(h))
        #expect(back == h)
        #expect(try JSONDecoder().decode(Hideout.self, from: Data("{}".utf8)) == Hideout())
        let onlyHidden = try JSONDecoder().decode(Hideout.self, from: Data(#"{"hidden":true}"#.utf8))
        #expect(onlyHidden.hidden && Hideout.peekEvery.contains(onlyHidden.peekIn))
    }
}

struct HidingEdgeTests {
    @Test func codexIsToldHeIsHidden() {
        #expect(VoiceContext.text(sittingMinutes: 5, hidden: true).hasSuffix("; Чилк спрятан за краем экрана]\n"))
        #expect(!VoiceContext.text(sittingMinutes: 5).contains("спрятан"))
    }

    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func moreThanHalfBeyondTheEdgeHidesThere() {
        #expect(EdgePlacement.hidingEdge(bodyCenterX: 1441, visibleFrame: screen) == .right)
        #expect(EdgePlacement.hidingEdge(bodyCenterX: -1, visibleFrame: screen) == .left)
        #expect(EdgePlacement.hidingEdge(bodyCenterX: 1440, visibleFrame: screen) == nil)   // exactly half: back
        #expect(EdgePlacement.hidingEdge(bodyCenterX: 700, visibleFrame: screen) == nil)
    }

    @Test func dragReachesFarEnoughBeyondTheEdge() {
        let range = EdgePlacement.carryRangeX(screen: screen, panelWidth: 300, radiusX: 54)
        // The body (centred in the panel) can go most of the way behind either edge, not stop at half.
        #expect(range.upperBound + 150 >= screen.maxX + 54 * 0.8)
        #expect(range.lowerBound + 150 <= screen.minX - 54 * 0.8)
        #expect(range.upperBound + 150 < screen.maxX + 54)            // a sliver stays to grab him back
    }
}

@MainActor
struct HideCharacterTests {
    let m = Metrics.standard

    func run(_ sim: CharacterSim, seconds: Double, pointer: CGPoint? = nil, every: ((CharacterSim) -> Void)? = nil) {
        for _ in 0..<Int(seconds * 60) {
            sim.step(dt: 1.0 / 60, pointer: pointer)
            every?(sim)
        }
    }

    func fresh(_ seed: UInt64 = 41) -> CharacterSim {
        let s = CharacterSim(metrics: m, rng: SeededRandom(seed: seed))
        run(s, seconds: 1)
        return s
    }

    @Test func hiddenHeDivesBehindTheEdgeLeaningInWithAPuff() {
        let sim = fresh()
        sim.hidden = true
        var minTilt = 0.0, puffs = 0, puffX = 0.0
        var lastAge: Double?
        run(sim, seconds: 2) {
            minTilt = min(minTilt, $0.pose.tilt)
            if let a = $0.pose.puffAge {
                if lastAge == nil { puffs += 1; puffX = Double($0.pose.puffOrigin.x) }
                lastAge = a
            } else { lastAge = nil }
        }
        #expect(minTilt < -0.25)                                     // the head trails: the sprout goes last
        #expect(puffs == 1 && abs(puffX - m.width) < 12)             // «пф!» at the screen edge, once
        #expect(Double(sim.bodyCenter.x) - m.radiusX * 1.1 > m.width) // all of him behind the edge
    }

    @Test func atHomeBehindTheEdgeHeNeitherTalksVisiblyNorDoesAntics() {
        let sim = fresh()
        sim.hidden = true
        run(sim, seconds: 2)
        sim.say("Шутка дня", duration: 5)
        var antics = 0
        run(sim, seconds: 60) { if $0.currentAntic != nil { antics += 1 } }
        #expect(antics == 0)
        sim.say("Шутка дня", duration: 5)
        #expect(sim.pose.bubble == nil)
        sim.standOut = .peek                                          // a timer brings him out: then it shows
        #expect(sim.pose.bubble == "Шутка дня")
    }

    @Test func aConversationBringsHimOutAndHomeIsBehindTheEdgeAgain() {
        let sim = fresh()
        sim.hidden = true
        run(sim, seconds: 2)
        sim.standOut = .out
        var hopped = false
        run(sim, seconds: 1.5) { if $0.pose.hop < -6 { hopped = true } }
        #expect(hopped && abs(sim.positionX - m.outX) < 6)
        sim.standOut = .docked
        run(sim, seconds: 2)
        #expect(Double(sim.bodyCenter.x) - m.radiusX * 1.1 > m.width)
    }

    @Test func hePeeksOutLeaningFromBehindTheEdgeAndFollowsTheCursor() {
        let sim = fresh()
        sim.hidden = true
        run(sim, seconds: 2)
        sim.standOut = .lurk
        let cursor = CGPoint(x: 60, y: 120)                          // far up-left on the screen
        run(sim, seconds: 1.2, pointer: cursor)
        let c = sim.bodyCenter
        #expect(Double(c.x) > m.width - 45 && Double(c.x) < m.width + 12)  // mostly behind the edge
        #expect(sim.contains(CGPoint(x: m.width - 12, y: Double(c.y))))    // the part that shows can be clicked
        #expect(!sim.contains(CGPoint(x: m.width - 70, y: Double(c.y))))
        #expect(sim.pose.tilt < -0.25)
        #expect(sim.pose.lookX < -0.3 && sim.pose.lookY < 0)        // looks at the cursor
        // Hovering over the part that shows does not pull him out: a click does (the app).
        run(sim, seconds: 1, pointer: CGPoint(x: Double(c.x) - 20, y: Double(c.y)))
        #expect(sim.positionX > m.width - 20)
        sim.standOut = .docked
        run(sim, seconds: 2)
        #expect(Double(sim.bodyCenter.x) - m.radiusX * 1.1 > m.width)
    }

    @Test func unhiddenHeHopsBackToHisPlace() {
        let sim = fresh()
        sim.hidden = true
        run(sim, seconds: 2)
        sim.hidden = false
        var hopped = false
        run(sim, seconds: 2) { if $0.pose.hop < -6 { hopped = true } }
        #expect(hopped && abs(sim.positionX - m.dockX) < 3)
    }

    @Test func atLaunchHiddenHeIsAlreadyGoneWithoutAPuff() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 42))
        sim.hidden = true
        sim.snapHidden()
        var puffed = false
        run(sim, seconds: 2) { if $0.pose.puffAge != nil { puffed = true } }
        #expect(!puffed)
        #expect(Double(sim.bodyCenter.x) - m.radiusX * 1.1 > m.width)
    }
}
