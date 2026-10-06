import ChilkCore
import CoreGraphics

/// The still sticker portrait of Чилк for the main window («Сегодня», slice 5c): his sprout mirrors the user's
/// fatigue like the one at the screen edge. Drawn once per sprout state, never animated.
@MainActor
public enum Portrait {
    public static func pose(fatigue: Double) -> CharacterPose {
        let sim = CharacterSim(metrics: .standard, rng: SeededRandom(seed: 42))
        sim.fatigue = fatigue
        for _ in 0..<120 { sim.step(dt: 1.0 / 60, pointer: CGPoint(x: 120, y: 200)) }
        var p = sim.pose
        p.eyeOpen = 1
        p.scaleX = 1
        p.scaleY = 1
        return p
    }

    /// A square image of `side` points at `scale`, transparent around him.
    public static func image(fatigue: Double, side: CGFloat, scale: CGFloat = 2) -> CGImage? {
        let px = Int(side * scale)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(px))
        ctx.scaleBy(x: scale, y: -scale)
        ChilkRenderer.drawPortrait(in: ctx, rect: CGRect(x: 0, y: 0, width: side, height: side), pose: pose(fatigue: fatigue),
                                   metrics: .standard, palette: .peach)
        return ctx.makeImage()
    }
}
