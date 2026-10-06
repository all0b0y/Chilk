import CoreGraphics
import Foundation

/// Slice 6f-2 (SPEC 25): the disco ball on its thread above Chilk, with glints and coloured light spots.
/// One drawing for the app's ball window and the previews. Canvas y-down; the thread hangs from y = 0 at the centre.
public enum DiscoBall {
    public static let radius = 25.0
    /// How wide a canvas the light spots need around the ball.
    public static let width = 220.0

    /// `drop`: the ball centre's distance from the top; `time` turns the facets and moves the lights.
    public static func draw(in ctx: CGContext, width: Double, drop: Double, time: Double) {
        let r = radius, cx = width / 2, cy = max(r, drop)
        let outline = RGBA.hex(0x2B2935).cgColor
        // Coloured light spots dancing around under the ball.
        let colors = [0xFF8FB1, 0x7FD8F0, 0xFFE07A, 0xB49BFF, 0x8FE3B8, 0xFFB27A, 0x9FB8FF]
        for (i, hex) in colors.enumerated() {
            let a = time * 0.9 + Double(i) * 2 * .pi / Double(colors.count)
            let d = 46 + 14 * sin(time * 1.3 + Double(i))
            let p = CGPoint(x: cx + cos(a) * d * 1.5, y: cy + 34 + sin(a) * d * 0.55)
            ctx.setFillColor(RGBA.hex(UInt32(hex), alpha: 0.7 + 0.25 * sin(time * 3 + Double(i))).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 6.5, y: p.y - 6.5, width: 13, height: 13))
        }
        // The thread.
        ctx.setStrokeColor(RGBA(0.25, 0.25, 0.3, 0.85).cgColor)
        ctx.setLineWidth(1.6)
        ctx.move(to: CGPoint(x: cx, y: 0))
        ctx.addLine(to: CGPoint(x: cx, y: cy - r))
        ctx.strokePath()
        // The ball: a mirror-tile grid sliding sideways as it turns, a shine, a die-cut border.
        let ball = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
        ctx.setFillColor(RGBA.white.cgColor)
        ctx.fillEllipse(in: ball.insetBy(dx: -3.5, dy: -3.5))
        ctx.saveGState()
        ctx.addEllipse(in: ball)
        ctx.clip()
        ctx.setFillColor(RGBA.hex(0xB9C0CC).cgColor)
        ctx.fill(ball)
        let tile = 6.0, shift = (time * 9).truncatingRemainder(dividingBy: tile)
        let grays: [UInt32] = [0xE9EDF3, 0x9AA3B2, 0xD3D8E1, 0xFFFFFF, 0x7E8797]
        for row in 0..<10 {
            for col in -1..<10 {
                let x = ball.minX + Double(col) * tile + shift, y = ball.minY + Double(row) * tile - 1
                let k = (row * 3 + col + Int(time * 9 / tile)) % grays.count
                ctx.setFillColor(RGBA.hex(grays[(k + grays.count) % grays.count]).cgColor)
                ctx.fill(CGRect(x: x + 0.6, y: y + 0.6, width: tile - 1.2, height: tile - 1.2))
            }
        }
        ctx.setFillColor(RGBA(1, 1, 1, 0.55).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - r * 0.6, y: cy - r * 0.7, width: r * 0.6, height: r * 0.4))
        ctx.restoreGState()
        ctx.setStrokeColor(outline)
        ctx.setLineWidth(2.6)
        ctx.strokeEllipse(in: ball)
        // Two four-point glints blinking on the tiles (inside the rim, so the outline stays whole).
        for (i, ang) in [-0.8, -2.5].enumerated() {
            let s = max(0, sin(time * 4 + Double(i) * 2.2)) * 7
            guard s > 0.5 else { continue }
            let p = CGPoint(x: cx + cos(ang) * r * 0.5, y: cy + sin(ang) * r * 0.5)
            ctx.setFillColor(RGBA.white.cgColor)
            let star = CGMutablePath()
            star.move(to: CGPoint(x: p.x, y: p.y - s))
            star.addLine(to: CGPoint(x: p.x + s * 0.25, y: p.y - s * 0.25))
            star.addLine(to: CGPoint(x: p.x + s, y: p.y))
            star.addLine(to: CGPoint(x: p.x + s * 0.25, y: p.y + s * 0.25))
            star.addLine(to: CGPoint(x: p.x, y: p.y + s))
            star.addLine(to: CGPoint(x: p.x - s * 0.25, y: p.y + s * 0.25))
            star.addLine(to: CGPoint(x: p.x - s, y: p.y))
            star.addLine(to: CGPoint(x: p.x - s * 0.25, y: p.y - s * 0.25))
            star.closeSubpath()
            ctx.addPath(star)
            ctx.fillPath()
        }
    }
}
