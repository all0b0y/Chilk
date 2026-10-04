import ChilkCore
import CoreGraphics
import Foundation

/// Draws Чилк. The scene is a list of `Placement`s (which part, where, how faded) computed from the pose;
/// both renderers consume the same list:
/// - `drawScene` — vector CoreGraphics (AppIcon, previews, reference for tests);
/// - `LayerRig` — one CALayer per part with a pre-rasterised bitmap, moved only by transforms (the app).
/// All CoreGraphics entry points expect a **y-down** context, like the HTML prototype canvas.
public enum ChilkRenderer {

    // MARK: Scene plan

    /// - Parameter mirrored: `true` when docked to the LEFT edge (the simulation always thinks "right").
    public static func placements(pose p: CharacterPose, metrics m: Metrics, mirrored: Bool) -> [Placement] {
        var out: [Placement] = []
        out.reserveCapacity(24)
        let mirror: CGAffineTransform = mirrored ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: m.width, ty: 0) : .identity

        // Contact shadow: shrinks and fades while he is in the air.
        let lift = clamp(-p.hop / 70)
        out.append(Placement(slot: Slot.contactShadow, part: .contactShadow,
                             transform: mirror.translatedBy(x: p.x, y: m.ground + 3).scaledBy(x: p.scaleX * (1 - lift * 0.35), y: 1 - lift * 0.35),
                             alpha: 1 - lift * 0.6))

        let figure = mirror.translatedBy(x: p.x, y: m.ground + p.hop).rotated(by: p.tilt)
            .scaledBy(x: p.scaleX, y: p.scaleY).translatedBy(x: 0, y: -m.radiusY)
        figurePlacements(into: &out, pose: p, metrics: m, lineScale: 1, base: figure)

        if p.sleep > 0.3 { zPlacements(into: &out, pose: p, metrics: m, mirror: mirror, mirrored: mirrored) }
        if let text = p.bubble, !text.isEmpty { bubblePlacements(into: &out, pose: p, metrics: m, mirrored: mirrored, text: text) }
        return out
    }

    /// Body, sprout and face. `base` maps figure space (body centre = origin) to the target space.
    static func figurePlacements(into out: inout [Placement], pose p: CharacterPose, metrics m: Metrics,
                                 lineScale lw: Double, base: CGAffineTransform) {
        let ox = p.lookX * m.radiusX * 0.14
        let oy = p.lookY * m.radiusY * 0.12
        out.append(Placement(slot: Slot.body, part: .body(lw: lw), transform: base, alpha: 1))

        // Sprout: stem on the head, two leaves at its tip (follow-through comes from leafAngle).
        let fp = Int((p.fatigue * 100).rounded())
        let f = Double(fp) / 100
        let root = base.translatedBy(x: ox * 0.35, y: -m.radiusY * 0.94).rotated(by: p.leafAngle)
        out.append(Placement(slot: Slot.stem, part: .stem(f: fp, lw: lw), transform: root, alpha: 1))
        let len = 22 + f * 2
        let tip = CGPoint(x: f * 16, y: -len * (1 - f * 0.62))
        let flutter = sin(p.time * 3.1 + p.phase) * 0.06
        for (i, side) in [-1.0, 1.0].enumerated() {
            let angle = side * 0.85 * (1 - f) + f * (2.55 + side * 0.3) + flutter * (i == 1 ? -1 : 1) * (1 - f * 0.7)
            let t = root.translatedBy(x: tip.x, y: tip.y).rotated(by: angle).scaledBy(x: 1 - f * 0.3, y: 1 - f * 0.12)
            out.append(Placement(slot: Slot.leaf + i, part: .leaf(index: i, f: fp, lw: lw), transform: t, alpha: 1))
        }

        // Blush moves less than the eyes → parallax depth.
        for (i, s) in [-1.0, 1.0].enumerated() {
            out.append(Placement(slot: Slot.blush + i, part: .blush,
                                 transform: base.translatedBy(x: s * m.radiusX * 0.55 + ox * 0.55, y: m.radiusY * 0.14 + oy * 0.4), alpha: 1))
        }

        let mood = p.mood
        let ex = m.radiusX * 0.33, ey = -m.radiusY * 0.06
        for (i, s) in [-1.0, 1.0].enumerated() {
            let eye = base.translatedBy(x: s * ex + ox, y: ey + oy)
            let part: Part
            var t = eye
            if mood.dizzy {
                part = .eyeDizzy(lw: lw)
                t = eye.rotated(by: p.time * 7 * s)
            } else if mood.annoyed {
                part = .eyeAnnoyed(side: Int(s), lw: lw)
            } else if p.sleep > 0.5 {
                part = .eyeSleep(lw: lw)
            } else if p.eyeOpen < 0.14 || (mood.called && p.calledAge < 0.5) {
                part = .eyeHappy(lw: lw)
            } else {
                part = .eyeOpen
                t = eye.scaledBy(x: 1 - abs(p.lookX) * 0.2, y: p.eyeOpen).scaledBy(x: p.eyeScale, y: p.eyeScale)
            }
            out.append(Placement(slot: Slot.eye + i, part: part, transform: t, alpha: 1))
        }

        let mouth = base.translatedBy(x: ox * 0.8, y: m.radiusY * 0.2 + oy * 0.6)
        var mouthT = mouth
        let mouthPart: Part
        if mood.dizzy {
            let cycle = (p.time * 10 / (2 * .pi)).truncatingRemainder(dividingBy: 1)
            mouthPart = .mouthWave(phase: Int(cycle * Double(Part.waveFrames)) % Part.waveFrames, lw: lw)
        } else if p.sleep > 0.5 || mood.carried {
            // little "o": snoring softly / "whoa!" when picked up
            let r = mood.carried ? 4.2 : 2.6 + sin(p.time * .pi * 2 / 5.2 + p.phase) * 0.6
            mouthT = mouth.translatedBy(x: 0, y: 1).scaledBy(x: r / 4.2, y: r / 4.2).translatedBy(x: 0, y: -1)
            mouthPart = .mouthO
        } else if mood.called || mood.yawning {
            mouthPart = .mouthOpen(yawn: mood.yawning)
        } else if mood.annoyed {
            mouthPart = .mouthFrown(lw: lw)
        } else {
            let tired = clamp((p.fatigue - 0.45) / 0.55)
            mouthPart = .mouthSmile(tired: Int((tired * 100).rounded()), lw: lw)
        }
        out.append(Placement(slot: Slot.mouth, part: mouthPart, transform: mouthT, alpha: 1))
    }

    /// "z z z" drifting up from the sprout: offset + delay + fade (Zajno), each z a little bigger.
    static func zPlacements(into out: inout [Placement], pose p: CharacterPose, metrics m: Metrics,
                            mirror: CGAffineTransform, mirrored: Bool) {
        let fadeIn = clamp((p.sleep - 0.3) / 0.5)
        for i in 0..<3 {
            let k = (p.time * 0.32 + Double(i) / 3).truncatingRemainder(dividingBy: 1)   // 0 → 1 over ~3 s
            let alpha = fadeIn * min(1, k * 5) * (1 - k)
            guard alpha > 0.002 else { continue }
            let size = 0.7 + k * 0.6
            let x = p.x - 18 - k * 34 + sin(k * 7 + Double(i)) * 4
            let y = m.ground + p.hop - m.radiusY * 2 - 18 - k * 58
            var t = mirror.translatedBy(x: x, y: y)
            if mirrored { t = t.scaledBy(x: -1, y: 1) }   // letters must never read backwards
            t = t.scaledBy(x: size, y: size).rotated(by: -0.25)
            out.append(Placement(slot: Slot.z + i, part: .z, transform: t, alpha: alpha))
        }
    }

    /// Bubble pops out of him (scale from the tail, easeOutBack); words arrive one by one (offset & delay).
    static func bubblePlacements(into out: inout [Placement], pose p: CharacterPose, metrics m: Metrics,
                                 mirrored: Bool, text: String) {
        let appear = clamp((p.bubbleAge - 0.3) / 0.35)
        let vanish = clamp(p.bubbleRemaining / 0.3)
        let scale = min(easeOutBack(appear), 1.08) * vanish
        guard scale > 0 else { return }

        let layout = BubbleLayout.of(text, maxTextWidth: m.width - 20 - 28)
        let bw = layout.width, bh = layout.height
        let top = m.ground + p.hop - m.radiusY * 2
        var bx = min(max(p.x - bw - 14, 10), m.width - bw - 10)
        let by = min(max(top - 28 - bh, 10), m.height)
        var tailX = min(p.x - 22, bx + bw - 18)
        var dir = 1.0
        if mirrored { bx = m.width - bx - bw; tailX = m.width - tailX; dir = -1 }
        let tailY = by + bh

        let pop = CGAffineTransform(translationX: tailX, y: tailY).scaledBy(x: scale, y: scale).translatedBy(x: -tailX, y: -tailY)
        let a = clamp(scale)
        out.append(Placement(slot: Slot.bubbleBox, part: .bubbleBox(width: bw, height: bh), transform: pop.translatedBy(x: bx, y: by), alpha: a))
        out.append(Placement(slot: Slot.bubbleTail, part: .bubbleTail, transform: pop.translatedBy(x: tailX, y: tailY).scaledBy(x: dir, y: 1), alpha: a))
        out.append(Placement(slot: Slot.bubbleStroke, part: .bubbleStroke(width: bw, height: bh), transform: pop.translatedBy(x: bx, y: by), alpha: a))
        for (index, word) in layout.words.enumerated() {
            let wa = clamp((p.bubbleAge - 0.45 - Double(index) * 0.08) / 0.2)
            guard wa * a > 0.002 else { continue }
            let t = pop.translatedBy(x: bx + 14 + word.x, y: by + 24 + Double(word.row) * BubbleLayout.rowHeight + (1 - wa) * 6)
            out.append(Placement(slot: Slot.word + index, part: .word(word.text), transform: t, alpha: wa * a))
        }
    }

    // MARK: Vector rendering

    public static func drawScene(in ctx: CGContext, pose: CharacterPose, metrics m: Metrics, palette: Palette,
                                 mirrored: Bool = false) {
        draw(placements(pose: pose, metrics: m, mirrored: mirrored), in: ctx, metrics: m, palette: palette)
    }

    public static func draw(_ placements: [Placement], in ctx: CGContext, metrics m: Metrics, palette: Palette) {
        for p in placements where p.alpha > 0 {
            ctx.saveGState()
            ctx.concatenate(p.transform)
            if p.alpha < 1 { ctx.setAlpha(p.alpha) }
            p.part.draw(in: ctx, metrics: m, palette: palette)
            ctx.restoreGState()
        }
    }

    /// Draws a macOS-style icon tile filling `rect` with Чилк inside. Outlines are thickened at tiny sizes.
    public static func drawIcon(in ctx: CGContext, rect: CGRect, pose: CharacterPose, metrics m: Metrics, palette: Palette) {
        let size = Double(rect.width)
        let tile = CGPath(roundedRect: rect, cornerWidth: size * 0.225, cornerHeight: size * 0.225, transform: nil)
        ctx.saveGState()
        ctx.addPath(tile)
        ctx.clip()
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [palette.iconTop.cgColor, palette.iconBottom.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        }
        let s = size / 150
        let base = CGAffineTransform(translationX: rect.midX, y: rect.minY + size * 0.6).scaledBy(x: s * pose.scaleX, y: s * pose.scaleY)
        var parts: [Placement] = []
        figurePlacements(into: &parts, pose: pose, metrics: m, lineScale: (max(1, 1.5 / (3.6 * s)) * 100).rounded() / 100, base: base)
        draw(parts, in: ctx, metrics: m, palette: palette)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(tile)
        ctx.setStrokeColor(RGBA(0, 0, 0, 0.1).cgColor)
        ctx.setLineWidth(max(0.8, size / 160))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Helpers

    static func fillEllipse(_ ctx: CGContext, center: CGPoint, rx: Double, ry: Double, rotation: Double, color: RGBA) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
        ctx.restoreGState()
    }

    static func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, x)) }

    static func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
}
