import ChilkCore
@testable import ChilkRender
import CoreGraphics
import Testing

// Acceptance 2026-10-06 («трясётся» at rest, with the hat): the sim and the window plan are smooth at rest —
// no window resizes and only breathing-slow reversals of every part. Keeps the cause out of the sim / viewport.
@MainActor
struct RestSmoothnessTests {
    func viewportChanges(mirrored: Bool = false, setup: (CharacterSim) -> Void) -> Int {
        let m = Metrics.standard
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 9))
        for _ in 0..<90 { sim.step(dt: 1.0 / 60, pointer: nil) }
        setup(sim)
        for _ in 0..<60 { sim.step(dt: 1.0 / 30, pointer: nil) }
        var last: CGRect?
        var count = 0
        for _ in 0..<(12 * 30) {
            sim.step(dt: 1.0 / 30, pointer: nil)
            let r = SceneViewport(metrics: m, placements: ChilkRenderer.placements(pose: sim.pose, metrics: m, mirrored: mirrored)).rect
            if let l = last, l != r { count += 1 }
            last = r
        }
        return count
    }

    /// The most reversals of any part's x / y / scale in 12 s at 30 fps.
    func maxReversals(setup: (CharacterSim) -> Void) -> Int {
        let m = Metrics.standard
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 9))
        for _ in 0..<90 { sim.step(dt: 1.0 / 60, pointer: nil) }
        setup(sim)
        for _ in 0..<60 { sim.step(dt: 1.0 / 30, pointer: nil) }
        var series: [Int: [[Double]]] = [:]
        for _ in 0..<(12 * 30) {
            sim.step(dt: 1.0 / 30, pointer: nil)
            for p in ChilkRenderer.placements(pose: sim.pose, metrics: m, mirrored: false) {
                series[p.slot, default: []].append([Double(p.transform.tx), Double(p.transform.ty), Double(p.transform.d)])
            }
        }
        var worst = 0
        for s in series.values {
            for k in 0..<3 {
                var n = 0, prev = 0.0
                for i in 1..<s.count {
                    let d = s[i][k] - s[i - 1][k]
                    if abs(d) < 1e-6 { continue }
                    if prev != 0, (d > 0) != (prev > 0) { n += 1 }
                    prev = d
                }
                worst = max(worst, n)
            }
        }
        return worst
    }

    @Test func atRestTheWindowNeverResizes() {
        #expect(viewportChanges { _ in } == 0)
        #expect(viewportChanges(mirrored: true) { _ in } == 0)
        #expect(viewportChanges { $0.wear(.hat) } == 0)
        #expect(viewportChanges { $0.wear(.hat); $0.wear(.backpack) } == 0)
        #expect(viewportChanges { $0.fallAsleep() } == 0)
        #expect(viewportChanges { $0.putOnNightcap() } == 0)
        #expect(viewportChanges { $0.wear(.lamp) } == 0)
    }

    @Test func atRestEveryPartMovesSlowly() {
        // Measured 2026-10-06: idle / hat ≤ 16, asleep ≤ 12 (breathing, the leaf's sway); a shake would be ≫ 40.
        #expect(maxReversals { _ in } < 30)
        #expect(maxReversals { $0.wear(.hat) } < 30)
        #expect(maxReversals { $0.fallAsleep() } < 30)
    }

    @Test func backFromThePopoverHiddenThereIsNoPuff() {
        let sim = CharacterSim(metrics: .standard, rng: SeededRandom(seed: 4))
        sim.hidden = true
        sim.snapHidden()
        var puffs = 0
        func run(_ s: Double) { for _ in 0..<Int(s * 60) { sim.step(dt: 1.0 / 60, pointer: nil); if sim.pose.puffAge != nil { puffs += 1 } } }
        run(1)
        sim.standOut = .away                                      // the popover takes him
        run(2)
        sim.standOut = .docked                                    // closed: home again, still out of sight
        run(2)
        #expect(puffs == 0)
        sim.hidden = false; sim.standOut = .docked; run(2)        // out for real …
        sim.hidden = true; run(2)                                 // … and a real dive still puffs
        #expect(puffs > 0)
    }
}
