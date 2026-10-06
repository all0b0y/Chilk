import ChilkCore
import ChilkRender
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import Testing

/// Premultiplied BGRA bitmap of the scene at `scale` px/pt.
final class Bitmap {
    let ctx: CGContext
    let width: Int, height: Int
    var rowBytes: Int { width * 4 }

    /// - Parameter yDown: flip so the renderer's y-down coordinates work; `false` for CALayer.render(in:).
    init(size: CGSize, scale: Double, yDown: Bool) {
        width = Int((size.width * scale).rounded()); height = Int((size.height * scale).rounded())
        ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        if yDown {
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: scale, y: -scale)
        } else {
            ctx.scaleBy(x: scale, y: scale)
        }
    }

    var bytes: UnsafeMutablePointer<UInt8> { ctx.data!.assumingMemoryBound(to: UInt8.self) }

    func clear() { memset(ctx.data!, 0, rowBytes * height) }

    /// Mean absolute difference per channel (0…255) and share of pixels differing by more than `big`.
    func difference(from other: Bitmap, big: Int = 48) -> (mean: Double, bigShare: Double) {
        let a = bytes, b = other.bytes
        var sum = 0, bigCount = 0
        for px in 0..<(width * height) {
            var worst = 0
            for c in 0..<4 {
                let d = abs(Int(a[px * 4 + c]) - Int(b[px * 4 + c]))
                sum += d
                worst = max(worst, d)
            }
            if worst > big { bigCount += 1 }
        }
        return (Double(sum) / Double(width * height * 4), Double(bigCount) / Double(width * height))
    }

    /// Rows with any painted pixel outside `rect` (pixel coordinates, y-down rows).
    func paintedOutside(xRange: Range<Int>, yRange: Range<Int>) -> Int {
        var dirty = 0
        for row in 0..<height {
            let p = bytes + row * rowBytes
            for x in 0..<width where !(yRange.contains(row) && xRange.contains(x)) {
                if p[x * 4 + 3] != 0 { dirty += 1; break }
            }
        }
        return dirty
    }
}

/// Everything that moves him a lot: hover from the edge, triple click, violent drag across the screen
/// (mirror flips), fling, call with bubble, tiredness, sleep with z's, wake-up hop, antics.
@MainActor
func playScenario(_ visit: (_ pose: CharacterPose, _ mirrored: Bool) -> Void) {
    let m = Metrics.standard
    let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 99))
    var mirrored = false
    func run(_ seconds: Double, pointer: CGPoint? = nil, carry: (Int) -> Double = { _ in 0 }) {
        for i in 0..<Int(seconds * 60) {
            sim.step(dt: 1.0 / 60, pointer: pointer, carryVelocity: carry(i))
            visit(sim.pose, mirrored)
        }
    }
    run(2)
    let c = sim.bodyCenter
    run(1.5, pointer: CGPoint(x: m.width - 8, y: Double(c.y)))
    run(1, pointer: CGPoint(x: 20, y: 20))
    sim.poke(); run(0.3); sim.poke(); run(0.2); sim.poke(); run(1.5)
    sim.reframe(x: m.carryX); sim.isCarried = true
    run(1.0, carry: { i in (i / 6) % 2 == 0 ? 5000 : -5000 })
    mirrored = true
    run(0.7, carry: { _ in -3000 })
    sim.isCarried = false; sim.reframe(x: m.dockX)
    run(1.0)
    sim.call(line: "Звал? 👀 Длинная фраза, чтобы облачко перенеслось на вторую строку"); run(5)
    sim.fatigue = 1; run(3)
    sim.fallAsleep(); run(5)
    sim.wakeUp(); run(1)
    // Slice 2: ladder bubble with buttons (one hovered), props and directed acts, on both edges.
    sim.standOut = .peek
    sim.say("Попей водички 💧 Кружка уже ждёт", buttons: ["Попил", "Через 10 мин", "Я занят"]); run(1.5)
    sim.hoveredButton = 1; run(0.5)
    sim.clearBubble(); sim.perform(.drink); run(3.2)
    sim.standOut = .out; sim.wear(.hat); sim.perform(.pack); run(2.5)
    sim.perform(.breathe(seconds: 6)); run(6)
    sim.perform(.stretches); run(3.4)
    sim.perform(.lookAway); run(4)
    mirrored = true
    sim.say("Пора закругляться 🌙", buttons: ["Заканчиваю", "Я занят"]); run(1.5)
    sim.clearBubble(); sim.takeOff(.hat); sim.takeOff(.backpack); sim.standOut = .docked
    // Slice 3: listening ears (twitching with the voice), then thinking.
    sim.listening = true; sim.hearing = 0.6; sim.say("Слушаю…", duration: 3); run(1.5)
    sim.earsDroop = 0.7; run(0.5); sim.earsDroop = 0
    sim.listening = false; sim.perform(.think(seconds: 2)); run(2.2)
    // Slice 6a: the eyes mirror, the stretch hint's hops, «ликует», the two new antics — on both edges.
    sim.eyeStrain = 1; run(5)
    sim.perform(.hops); run(4.4)
    mirrored = true
    sim.standOut = .peek; sim.perform(.cheer); run(2.8)
    sim.startAntic(.scratchLeaf); run(2)
    mirrored = false
    sim.startAntic(.catchSpeck); run(3)
    sim.eyeStrain = 0; sim.standOut = .docked; run(1.5)
    sim.fatigue = 0.37
    mirrored = false
    run(20)
}

@Suite("Layer rig")
@MainActor
struct RigTests {
    let m = Metrics.standard
    let palette = Palette.peach

    /// Every shape variant the scenario produces, plus the extremes.
    func allParts() -> Set<Part> {
        var parts = Set<Part>()
        playScenario { pose, mirrored in
            for p in ChilkRenderer.placements(pose: pose, metrics: m, mirrored: mirrored) { parts.insert(p.part) }
        }
        for f in [0, 50, 100] {
            parts.insert(.stem(f: f, lw: 1)); parts.insert(.leaf(index: 0, f: f, lw: 1)); parts.insert(.leaf(index: 1, f: f, lw: 1))
        }
        for k in 0..<Part.waveFrames { parts.insert(.mouthWave(phase: k, lw: 1)) }
        for t in [0, 100] { parts.insert(.mouthSmile(tired: t, lw: 1)) }
        parts.insert(.body(lw: 4.8))                               // 16 px icon: thick outline
        return parts
    }

    @Test func partsStayInsideTheirBitmaps() {
        var failures: [String] = []
        for part in allParts() {
            let r = part.bounds(metrics: m)
            let pad = 30.0, scale = 3.0
            let bmp = Bitmap(size: CGSize(width: r.width + pad * 2, height: r.height + pad * 2), scale: scale, yDown: true)
            bmp.ctx.translateBy(x: pad - r.minX, y: pad - r.minY)
            part.draw(in: bmp.ctx, metrics: m, palette: palette)
            let x0 = Int(pad * scale), y0 = Int(pad * scale)
            let rows = bmp.paintedOutside(xRange: x0..<(x0 + Int(r.width * scale)), yRange: y0..<(y0 + Int(r.height * scale)))
            if rows > 0 { failures.append("\(part): \(rows) rows outside \(r)") }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5).joined(separator: "\n"))")
    }

    @Test func rigLooksLikeTheVectorRenderer() {
        let rig = LayerRig(metrics: m, palette: palette, rasterScale: 3)
        var frame = 0, compared = 0
        var worst = (mean: 0.0, big: 0.0, frame: 0), worstText = (mean: 0.0, big: 0.0, frame: 0)
        playScenario { pose, mirrored in
            frame += 1
            let plan = ChilkRenderer.placements(pose: pose, metrics: m, mirrored: mirrored)
            rig.apply(plan)
            guard frame % 25 == 0 else { return }
            // Compare the FULL paint viewport, not two equally cropped 300×300 canvases.
            let viewport = SceneViewport(metrics: m, placements: plan)
            let vector = Bitmap(size: viewport.rect.size, scale: 2, yDown: true)
            let layers = Bitmap(size: viewport.rect.size, scale: 2, yDown: false)
            vector.ctx.translateBy(x: viewport.drawingOffset.x, y: viewport.drawingOffset.y)
            layers.ctx.translateBy(x: viewport.layerOffset.x, y: viewport.layerOffset.y)
            ChilkRenderer.draw(plan, in: vector.ctx, metrics: m, palette: palette)
            rig.root.render(in: layers.ctx)
            let d = vector.difference(from: layers)
            compared += 1
            if let dir = ProcessInfo.processInfo.environment["CHILK_DUMP"], frame % 100 == 0 {
                for (name, b) in [("vector", vector), ("layers", layers)] {
                    let url = URL(fileURLWithPath: dir).appendingPathComponent("\(frame)-\(name).png")
                    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
                    CGImageDestinationAddImage(dest, b.ctx.makeImage()!, nil)
                    CGImageDestinationFinalize(dest)
                }
                print("frame \(frame): mean \(d.mean) big \(d.bigShare)")
            }
            if pose.bubble != nil {
                if d.mean > worstText.mean { worstText = (d.mean, max(worstText.big, d.bigShare), frame) }
                worstText.big = max(worstText.big, d.bigShare)
            } else {
                if d.mean > worst.mean { worst = (d.mean, max(worst.big, d.bigShare), frame) }
                worst.big = max(worst.big, d.bigShare)
            }
        }
        #expect(compared > 40)
        // Only resampling of the 3× part bitmaps may differ: tiny on average, a few edge pixels at most.
        #expect(worst.mean < 0.5, "worst mean diff \(worst.mean) at frame \(worst.frame)")
        #expect(worst.big < 0.004, "share of strongly different pixels \(worst.big)")
        // Text glyphs are antialiased differently at 3× then downsampled (checked by eye: identical look).
        #expect(worstText.mean < 2, "bubble frames: worst mean diff \(worstText.mean) at frame \(worstText.frame)")
        #expect(worstText.big < 0.02, "bubble frames: strongly different pixels \(worstText.big)")
    }

    @Test func layersAndBitmapsAreReused() {
        let rig = LayerRig(metrics: m, palette: palette, rasterScale: 3)
        var maxWords = 0
        playScenario { pose, mirrored in
            let plan = ChilkRenderer.placements(pose: pose, metrics: m, mirrored: mirrored)
            maxWords = max(maxWords, plan.filter { $0.slot >= Slot.word }.count)
            rig.apply(plan)
        }
        #expect(rig.layerCount <= Slot.word + maxWords)
        let rasterised = rig.rasterisedCount
        #expect(rasterised < 150)                              // shapes, not frames
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 1))
        for _ in 0..<300 {                                     // 5 s of idle life: nothing new to rasterise
            sim.step(dt: 1.0 / 60, pointer: nil)
            rig.apply(ChilkRenderer.placements(pose: sim.pose, metrics: m, mirrored: false))
        }
        #expect(rig.rasterisedCount - rasterised <= 2)
    }

    @Test func hiddenSlotsDisappear() {
        let rig = LayerRig(metrics: m, palette: palette, rasterScale: 2)
        var pose = CharacterPose()
        pose.x = m.dockX
        pose.bubble = "Привет"
        pose.bubbleAge = 1
        pose.bubbleRemaining = 2
        rig.apply(ChilkRenderer.placements(pose: pose, metrics: m, mirrored: false))
        let withBubble = rig.root.sublayers!.filter { !$0.isHidden }.count
        pose.bubble = nil
        rig.apply(ChilkRenderer.placements(pose: pose, metrics: m, mirrored: false))
        let without = rig.root.sublayers!.filter { !$0.isHidden }.count
        #expect(withBubble - without == 4)                     // box, tail, stroke, one word
    }
}
