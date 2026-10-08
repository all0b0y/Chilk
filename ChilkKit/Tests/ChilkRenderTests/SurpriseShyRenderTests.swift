import ChilkCore
import CoreGraphics
import Testing
@testable import ChilkRender

// Slice 9 (decision 34): the faces of «удивление» and «смущение» on both edges.
@Suite("Surprise and shyness are drawn")
@MainActor
struct SurpriseShyRenderTests {
    let m = Metrics.standard

    func pose(_ e: Emotion, at seconds: Double) -> CharacterPose {
        let s = CharacterSim(metrics: m, rng: SeededRandom(seed: 42))
        s.emote(e, strong: false)
        for _ in 0..<Int(seconds * 60) { s.step(dt: 1.0 / 60, pointer: nil) }
        return s.pose
    }

    func centre(_ t: CGAffineTransform) -> CGPoint { CGPoint(x: t.tx, y: t.ty) }

    func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        ((Double(a.x) - Double(b.x)) * (Double(a.x) - Double(b.x)) + (Double(a.y) - Double(b.y)) * (Double(a.y) - Double(b.y))).squareRoot()
    }

    @Test func surpriseHasRoundEyesAnOMouthAndAnExclamationThatReadsForwardOnBothEdges() {
        let p = pose(.surprised, at: 0.8)
        for mirrored in [false, true] {
            let plan = ChilkRenderer.placements(pose: p, metrics: m, mirrored: mirrored)
            let eyes = plan.filter { $0.slot == Slot.eye || $0.slot == Slot.eye + 1 }.map(\.part)
            #expect(eyes == [.eyeRound(lw: 1), .eyeRound(lw: 1)])
            #expect(plan.first { $0.slot == Slot.mouth }?.part == .mouthO)
            let bang = plan.first { $0.slot == Slot.exclaim }
            #expect(bang?.part == .exclaim)
            guard let b = bang else { continue }
            #expect(b.transform.a > 0, "mirrored=\(mirrored): the «!» must not be flipped")
            // Inside the scene and over his head (above the body's top).
            let r = Part.exclaim.bounds(metrics: m).applying(b.transform)
            #expect(r.minX >= 0 && r.maxX <= m.width && r.minY >= 0, "\(r)")
            let body = plan.first { $0.slot == Slot.body }!
            let top = CGPoint(x: 0, y: -m.radiusY).applying(body.transform)
            #expect(b.transform.ty < top.y, "baseline \(b.transform.ty) vs head top \(top)")   // the glyph sits on it
        }
    }

    @Test func theExclamationStandsOnTheScreenSideOfTheHeadAndLeansOutwardOnBothEdges() {
        // Review 9e-art: un-mirroring the glyph also un-mirrored its tilt, so on the left edge it leaned into the head.
        let p = pose(.surprised, at: 0.8)
        for mirrored in [false, true] {
            let plan = ChilkRenderer.placements(pose: p, metrics: m, mirrored: mirrored)
            guard let b = plan.first(where: { $0.slot == Slot.exclaim }) else { Issue.record("no «!»"); continue }
            let body = plan.first { $0.slot == Slot.body }!
            let head = CGPoint(x: 0, y: -m.radiusY).applying(body.transform)
            let foot = CGPoint(x: 0, y: 0).applying(b.transform)                    // the baseline under the dot
            let tip = CGPoint(x: 0, y: -TextKit.exclaimMetrics.1).applying(b.transform)   // the top of the stroke
            // In panel space the screen is to the left on the right edge (x grows towards the edge), to the right when mirrored.
            let screenward: (CGPoint, CGPoint) -> Bool = { a, b in mirrored ? a.x > b.x : a.x < b.x }
            #expect(screenward(foot, head), "mirrored=\(mirrored): «!» at \(foot.x), head at \(head.x)")
            #expect(screenward(tip, foot), "mirrored=\(mirrored): leans \(tip.x - foot.x) — must lean away from the head")
            #expect(abs(Double(tip.x) - Double(foot.x)) > 3, "mirrored=\(mirrored): visibly tilted")
        }
    }

    @Test func theExclamationBoundsAreMeasuredOnce() {
        let (w, ascent, descent) = TextKit.metrics("!", font: TextKit.exclaimFont)
        #expect(TextKit.exclaimMetrics == (w, ascent, descent))
        let r = Part.exclaim.bounds(metrics: m)
        let exact = CGRect(x: -w / 2 - 4, y: -ascent - 4, width: w + 8, height: ascent + descent + 8).integral
        #expect(r == exact, "\(r) vs \(exact)")
    }

    @Test func shyCoversTheClosedEyesWithTheMittensAndBlushesWithLines() {
        let covered = ChilkRenderer.placements(pose: pose(.shy, at: 0.8), metrics: m, mirrored: false)
        let eyes = covered.filter { $0.slot == Slot.eye || $0.slot == Slot.eye + 1 }
        #expect(eyes.map(\.part) == [.eyeSleep(lw: 1), .eyeSleep(lw: 1)])     // ‿ ‿ — not ^ ^ (joy)
        #expect(covered.filter { $0.part == .blushShy }.count == 2)
        let hands = covered.filter { $0.slot == Slot.hand || $0.slot == Slot.hand + 1 }
        #expect(hands.count == 2)
        for (eye, hand) in zip(eyes, hands) {
            #expect(distance(centre(eye.transform), centre(hand.transform)) < 6)
        }
        // The peek: the screen-side mitten slid off, that eye is open; the other stays hidden.
        let peek = ChilkRenderer.placements(pose: pose(.shy, at: 1.45), metrics: m, mirrored: true)
        let pe = peek.filter { $0.slot == Slot.eye || $0.slot == Slot.eye + 1 }
        let ph = peek.filter { $0.slot == Slot.hand || $0.slot == Slot.hand + 1 }
        #expect(pe.map(\.part) == [.eyeOpen, .eyeSleep(lw: 1)])
        #expect(distance(centre(pe[0].transform), centre(ph[0].transform)) > 12)
        #expect(distance(centre(pe[1].transform), centre(ph[1].transform)) < 6)
    }

    @Test func aBlinkNeverTurnsTheNewFacesIntoASmile() {
        for set in [{ (m: inout Mood) in m.surprised = true }, { $0.shy = true }] {
            var p = CharacterPose()
            p.x = m.dockX
            p.eyeOpen = 0.05
            set(&p.mood)
            let eyes = ChilkRenderer.placements(pose: p, metrics: m, mirrored: false)
                .filter { $0.slot == Slot.eye || $0.slot == Slot.eye + 1 }.map(\.part)
            #expect(eyes.count == 2 && !eyes.contains(.eyeHappy(lw: 1)), "\(eyes)")
        }
    }
}
