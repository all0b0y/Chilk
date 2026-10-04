import ChilkCore
import ChilkRender
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import Testing

@Suite("Screen-only character clipping")
@MainActor
struct ViewportTests {
    let m = Metrics.standard

    /// Replays the old flight bug: a one-off reframe, then the sim resumes its docked x.
    @Test func eyeFlightDoesNotClipTheCharacterAtAnInvisiblePanelEdge() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 42))
        sim.eyesWide = true
        sim.reframe(x: m.carryX)
        for _ in 0..<60 { sim.step(dt: 1.0 / 60, pointer: nil, carryVelocity: 500) }
        let plan = ChilkRenderer.placements(pose: sim.pose, metrics: m, mirrored: false)
        let viewport = SceneViewport(metrics: m, placements: plan).rect
        let painted = plan.reduce(CGRect.null) { $0.union($1.part.bounds(metrics: m).applying($1.transform)) }
        #expect(viewport.contains(painted), "Invisible canvas clips the flying character: paint=\(painted), canvas=\(viewport)")
    }

    @Test func everyScenarioFrameFitsOnBothSides() {
        var frames = 0, failures: [String] = []
        func audit(_ pose: CharacterPose) {
            for mirrored in [false, true] {
                let plan = ChilkRenderer.placements(pose: pose, metrics: m, mirrored: mirrored)
                let viewport = SceneViewport(metrics: m, placements: plan)
                for p in plan where p.alpha > 0 {
                    if !viewport.rect.contains(p.part.bounds(metrics: m).applying(p.transform)) {
                        failures.append("t=\(pose.time), mirror=\(mirrored), part=\(p.part)")
                    }
                }
                frames += 1
            }
        }
        // Hover, carry, release/return, fling, call, click/triple click, sleep/wake, all directed acts,
        // props, ladder bubbles/buttons and listening/thinking. Includes the formerly cropped return.
        playScenario { pose, _ in audit(pose) }
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 20))
        var seen = Set<Antic>()
        for _ in 0..<(600 * 60) {
            sim.step(dt: 1.0 / 60, pointer: nil)
            if let antic = sim.currentAntic { seen.insert(antic) }
            audit(sim.pose)
        }
        #expect(seen == Set(Antic.allCases))
        #expect(failures.isEmpty, "\(failures.prefix(5))")
        print("viewport audit: \(frames) frames, all \(seen.count) antics, both orientations")
    }

    @Test func expandingTheCanvasNeverMovesAPixelOnScreen() {
        let sceneOrigin = CGPoint(x: -1200, y: 400) // non-zero / negative monitor coordinates
        for mirrored in [false, true] {
            var pose = CharacterPose()
            pose.x = m.dockX
            pose.tilt = 0.55
            pose.props = Set(Prop.allCases)
            pose.earsUp = 1.1
            let plan = ChilkRenderer.placements(pose: pose, metrics: m, mirrored: mirrored)
            let viewport = SceneViewport(metrics: m, placements: plan)
            let frame = viewport.panelFrame(sceneOrigin: sceneOrigin)
            for p in plan {
                let point = CGPoint.zero.applying(p.transform)
                let original = CGPoint(x: sceneOrigin.x + point.x, y: sceneOrigin.y + m.height - point.y)
                let canvas = CGPoint(x: point.x + viewport.drawingOffset.x, y: point.y + viewport.drawingOffset.y)
                let after = CGPoint(x: frame.minX + canvas.x, y: frame.maxY - canvas.y)
                #expect(abs(after.x - original.x) < 0.000001)
                #expect(abs(after.y - original.y) < 0.000001)
                let mapped = viewport.scenePoint(screenPoint: after, sceneOrigin: sceneOrigin)
                #expect(abs(mapped.x - point.x) < 0.000001)
                #expect(abs(mapped.y - point.y) < 0.000001)
            }
        }
    }

    @Test func onlyThePhysicalScreenHidesTheDockedHalf() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
        for mirrored in [false, true] {
            var pose = CharacterPose()
            pose.x = m.dockX
            let plan = ChilkRenderer.placements(pose: pose, metrics: m, mirrored: mirrored)
            let viewport = SceneViewport(metrics: m, placements: plan)
            let body = plan.first { $0.slot == Slot.body }!
            let paint = body.part.bounds(metrics: m).applying(body.transform)
            #expect(viewport.rect.contains(paint)) // no truncation at the window boundary
            func screenPaint(at origin: CGPoint) -> CGRect {
                CGRect(x: origin.x + paint.minX, y: origin.y + m.height - paint.maxY, width: paint.width, height: paint.height)
            }
            let dock = EdgePlacement(edge: mirrored ? .left : .right, verticalFraction: 0.5)
                .panelOrigin(panelSize: m.sceneSize, visibleFrame: screen)
            #expect(!screen.contains(screenPaint(at: dock))) // the true screen edge intentionally hides him
            #expect(screen.contains(screenPaint(at: CGPoint(x: 400, y: 200)))) // full body away from the edge
        }
    }

    @Test func windowSizeStaysStableWhileBreathingAtTheEdge() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 42))
        var sizes = Set<String>()
        for _ in 0..<300 { // before the first random antic
            sim.step(dt: 1.0 / 60, pointer: nil)
            let plan = ChilkRenderer.placements(pose: sim.pose, metrics: m, mirrored: false)
            sizes.insert(String(describing: SceneViewport(metrics: m, placements: plan).rect))
        }
        #expect(sizes.count == 1, "Breathing must not resize the window every frame: \(sizes)")
    }

    @Test func expandedLayerHostLooksLikeAnUnclippedVectorReference() throws {
        let rig = LayerRig(metrics: m, palette: .peach, rasterScale: 3)
        let host = CALayer()
        host.masksToBounds = false
        host.addSublayer(rig.root)
        var compared = 0, worst = 0.0
        var poses: [(String, CharacterPose)] = []
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 42))
        sim.eyesWide = true
        for _ in 0..<60 { sim.step(dt: 1.0 / 60, pointer: nil, carryVelocity: 500) }
        poses.append(("flight", sim.pose))
        sim.eyesWide = false
        sim.perform(.stretches)
        for _ in 0..<8 { sim.step(dt: 1.0 / 60, pointer: nil) }
        poses.append(("stretch", sim.pose))
        sim.stopAct()
        sim.isCarried = true
        sim.reframe(x: m.carryX)
        for _ in 0..<60 { sim.step(dt: 1.0 / 60, pointer: nil, carryVelocity: 700) }
        poses.append(("carry", sim.pose))
        sim.isCarried = false
        sim.reframe(x: m.dockX)
        sim.poke(); sim.poke(); sim.poke()
        for _ in 0..<12 { sim.step(dt: 1.0 / 60, pointer: nil, carryVelocity: -700) }
        poses.append(("release-dizzy", sim.pose))
        for prop in Prop.allCases { sim.wear(prop) }
        sim.listening = true
        for _ in 0..<30 { sim.step(dt: 1.0 / 60, pointer: nil) }
        poses.append(("props-ears", sim.pose))

        for (name, pose) in poses {
            for mirrored in [false, true] {
                let plan = ChilkRenderer.placements(pose: pose, metrics: m, mirrored: mirrored)
                let viewport = SceneViewport(metrics: m, placements: plan)
                // Independent, generous canvas — not sized from the production viewport. It catches
                // real painted pixels missed by a part's bounds or by either window transform.
                let padding = 200.0
                let size = CGSize(width: m.width + padding * 2, height: m.height + padding * 2)
                let reference = Bitmap(size: size, scale: 2, yDown: true)
                reference.ctx.translateBy(x: padding, y: padding)
                ChilkRenderer.draw(plan, in: reference.ctx, metrics: m, palette: .peach)
                let a = viewport.rect.offsetBy(dx: padding, dy: padding)
                #expect(reference.paintedOutside(xRange: Int(a.minX * 2)..<Int(a.maxX * 2), yRange: Int(a.minY * 2)..<Int(a.maxY * 2)) == 0)

                let vector = Bitmap(size: viewport.rect.size, scale: 2, yDown: true)
                vector.ctx.translateBy(x: viewport.drawingOffset.x, y: viewport.drawingOffset.y)
                ChilkRenderer.draw(plan, in: vector.ctx, metrics: m, palette: .peach)
                let layers = Bitmap(size: viewport.rect.size, scale: 2, yDown: false)
                host.frame = CGRect(origin: .zero, size: viewport.rect.size)
                rig.root.frame = CGRect(origin: viewport.layerOffset, size: m.sceneSize)
                rig.apply(plan)
                host.render(in: layers.ctx)
                let d = vector.difference(from: layers)
                worst = max(worst, d.mean)
                #expect(d.mean < 0.5, "\(name), mirror=\(mirrored): \(d)")
                #expect(d.bigShare < 0.004)
                if let dir = ProcessInfo.processInfo.environment["CHILK_VIEWPORT_DUMP"] {
                    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(mirrored ? "left" : "right").png")
                    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
                    CGImageDestinationAddImage(dest, layers.ctx.makeImage()!, nil)
                    #expect(CGImageDestinationFinalize(dest))
                }
                compared += 1
            }
        }
        print("unclipped pixel audit: \(compared) frames, worst mean difference \(worst)/255")
    }
}
