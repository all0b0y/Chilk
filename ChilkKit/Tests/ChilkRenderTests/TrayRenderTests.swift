import ChilkCore
import ChilkRender
import CoreGraphics
import Foundation
import Testing

/// Slice 5a: the tray icon images and the hand-off into the popover (SPEC «Срез 5», decisions 3, 4, 7).
@Suite("Slice 5a rendering")
@MainActor
struct TrayRenderTests {
    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    @Test func everyStateIsADistinctTemplateThatFitsTheMenuBar() throws {
        var seen: [[UInt8]] = []
        for leaf in TrayLeaf.allCases {
            for dot in [false, true] {
                let image = try #require(TrayIconRenderer.image(TrayIconState(leaf: leaf, dot: dot), scale: 2))
                #expect(image.width == 40 && image.height == 36)
                let px = pixels(image)
                var opaque = 0
                for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 0 {
                    opaque += 1
                    // Template: colour is black everywhere, only alpha carries the shape.
                    #expect(px[i] == 0 && px[i + 1] == 0 && px[i + 2] == 0)
                }
                #expect(opaque > 200)
                // A pixel of margin all round: nothing is cut by the image edge.
                for y in 0..<image.height {
                    for x in 0..<image.width where x == 0 || y == 0 || x == image.width - 1 || y == image.height - 1 {
                        #expect(px[(y * image.width + x) * 4 + 3] == 0, "edge pixel \(x),\(y) for \(leaf) dot=\(dot)")
                    }
                }
                #expect(!seen.contains(px))
                seen.append(px)
            }
        }
    }

    @Test func theDotSitsTopRight() throws {
        let plain = pixels(try #require(TrayIconRenderer.image(TrayIconState(leaf: .fresh, dot: false), scale: 2)))
        let dotted = pixels(try #require(TrayIconRenderer.image(TrayIconState(leaf: .fresh, dot: true), scale: 2)))
        // Bitmap rows start at the top: the dot's centre is ~3 pt from the top-right corner.
        let i = ((3 * 2) * 40 + (40 - 3 * 2)) * 4 + 3
        #expect(plain[i] == 0 && dotted[i] == 255)
    }

    /// Decision 7 with the visibility contract: away, nothing of him is left on the screen side of the edge,
    /// and the expanded canvas still encloses every part (no invisible clipping on the way out and back).
    @Test func awayIsEntirelyBehindTheRealScreenEdge() {
        let m = Metrics.standard
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 3))
        sim.wear(.hat)
        sim.wear(.backpack)
        var worstLeft = Double.infinity
        sim.standOut = .away
        for frame in 0..<240 {
            sim.step(dt: 1.0 / 60, pointer: nil)
            let plan = ChilkRenderer.placements(pose: sim.pose, metrics: m, mirrored: false)
            let viewport = SceneViewport(metrics: m, placements: plan)
            for p in plan where p.alpha > 0 {
                let paint = p.part.bounds(metrics: m).applying(p.transform)
                #expect(viewport.rect.contains(paint))
                if frame >= 120 { worstLeft = min(worstLeft, Double(paint.minX)) }
            }
        }
        #expect(worstLeft > m.width, "still visible: paint starts at \(worstLeft), screen edge at \(m.width)")
        sim.standOut = .docked
        for _ in 0..<240 {
            sim.step(dt: 1.0 / 60, pointer: nil)
            let plan = ChilkRenderer.placements(pose: sim.pose, metrics: m, mirrored: true)
            let viewport = SceneViewport(metrics: m, placements: plan)
            for p in plan where p.alpha > 0 { #expect(viewport.rect.contains(p.part.bounds(metrics: m).applying(p.transform))) }
        }
    }
}
