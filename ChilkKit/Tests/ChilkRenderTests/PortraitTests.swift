import ChilkCore
import CoreGraphics
import Testing
@testable import ChilkRender

/// Slice 5c: the still portrait in «Сегодня» — the whole sticker fits, nothing is cut by the image edge.
@Suite("Slice 5c: portrait")
@MainActor
struct PortraitTests {
    @Test func theWholeStickerFitsWithAClearMarginInEverySproutState() throws {
        for fatigue in [0.0, 0.55, 1.0] {
            let image = try #require(Portrait.image(fatigue: fatigue, side: 120, scale: 1))
            let w = image.width, h = image.height
            let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let px = try #require(ctx.data?.assumingMemoryBound(to: UInt8.self))
            var opaque = 0, onBorder = 0
            for y in 0..<h {
                for x in 0..<w where px[(y * w + x) * 4 + 3] > 8 {
                    opaque += 1
                    if x < 2 || y < 2 || x >= w - 2 || y >= h - 2 { onBorder += 1 }
                }
            }
            #expect(onBorder == 0, "fatigue \(fatigue): \(onBorder) opaque pixels on the image edge")
            #expect(opaque > w * h / 4, "fatigue \(fatigue): the sticker is too small (\(opaque) px)")
        }
    }
}
