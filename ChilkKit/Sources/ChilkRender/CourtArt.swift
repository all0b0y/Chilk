import ChilkCore
import CoreGraphics
import Foundation

/// Slice 7b: the basketball game's drawings — the ball (in his hands and in flight), the hoop with its backboard and
/// net, the firework sparks. One look for the character's rig, the app's windows and the headless previews.
public enum CourtArt {
    public static let ballRadius = 11.0
    static let ballOrange = RGBA.hex(0xF08A3C)
    static let seam = RGBA.hex(0x7A3A16)
    static let rimOrange = RGBA.hex(0xE8662A)
    static let netWhite = RGBA(1, 1, 1, 0.95)
    public static let sparkColors: [RGBA] = [.hex(0xFFD45C), .hex(0xFF7A8A), .hex(0x7FD8FF), .hex(0xB28CFF), .hex(0x8CF0A0)]

    /// The ball centred at the origin (y down); `spin` turns the seams.
    public static func ball(_ ctx: CGContext, radius r: Double = ballRadius, spin: Double = 0, outline: CGColor, lw: Double) {
        let circle = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
        ctx.addPath(circle)
        ctx.setStrokeColor(RGBA.white.cgColor)
        ctx.setLineWidth(7)
        ctx.strokePath()
        ctx.addPath(circle)
        ctx.setFillColor(ballOrange.cgColor)
        ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(circle)
        ctx.clip()
        ctx.rotate(by: spin)
        ctx.setStrokeColor(seam.cgColor)
        ctx.setLineWidth(1.3 * lw)
        ctx.move(to: CGPoint(x: -r, y: 0)); ctx.addLine(to: CGPoint(x: r, y: 0))
        ctx.move(to: CGPoint(x: 0, y: -r)); ctx.addLine(to: CGPoint(x: 0, y: r))
        ctx.strokePath()
        for s in [-1.0, 1.0] {                                           // the two curved seams
            ctx.addArc(center: CGPoint(x: s * r * 1.35, y: 0), radius: r * 0.95, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            ctx.strokePath()
        }
        ctx.restoreGState()
        ctx.setFillColor(RGBA(1, 1, 1, 0.45).cgColor)                    // a shine
        ctx.fillEllipse(in: CGRect(x: -r * 0.55, y: -r * 0.65, width: r * 0.42, height: r * 0.3))
        ctx.addPath(circle)
        ctx.setStrokeColor(outline)
        ctx.setLineWidth(2.2 * lw)
        ctx.strokePath()
    }

    /// The hoop's size: the backboard above, the rim sticking out towards him, the net below.
    public static let boardSize = CGSize(width: 96, height: 66)
    public static let rimRadius = 22.0
    /// The rim's centre relative to the backboard's bottom centre (y down); `facing` = −1: he is to the left.
    public static func rimOffset(facing: Double) -> CGPoint { CGPoint(x: facing * 18, y: 8) }

    /// The backboard, the rim and the net with its sway (`swing` 0…1 after a basket). Origin = the backboard's bottom
    /// centre, y down; `facing` −1 when he stands to the left of the hoop.
    public static func hoop(_ ctx: CGContext, facing: Double, swing: Double, outline: CGColor) {
        let w = Double(boardSize.width), h = Double(boardSize.height)
        // The pole's bracket and the backboard.
        let board = CGPath(roundedRect: CGRect(x: -w / 2, y: -h, width: w, height: h), cornerWidth: 7, cornerHeight: 7, transform: nil)
        ctx.addPath(board)
        ctx.setFillColor(RGBA(1, 1, 1, 0.96).cgColor)
        ctx.fillPath()
        ctx.addPath(board)
        ctx.setStrokeColor(outline)
        ctx.setLineWidth(2.6)
        ctx.strokePath()
        ctx.setStrokeColor(rimOrange.cgColor)                            // the small square over the rim
        ctx.setLineWidth(2.4)
        ctx.stroke(CGRect(x: -16, y: -30, width: 32, height: 22))
        // The net: from the rim down, narrowing; sways after a basket.
        let rim = rimOffset(facing: facing), r = rimRadius
        let sway = sin(swing * .pi * 4) * (1 - swing) * 6
        let depth = 30.0
        func netPath() {
        for i in 0...5 {
            let u = Double(i) / 5
            let top = CGPoint(x: Double(rim.x) - r + 2 * r * u, y: Double(rim.y))
            let bottom = CGPoint(x: Double(rim.x) - r * 0.55 + 1.1 * r * u + sway, y: Double(rim.y) + depth)
            ctx.move(to: top); ctx.addLine(to: bottom)
        }
        for j in 1...2 {
            let v = Double(j) / 3, half = r * (1 - 0.45 * v)
            ctx.move(to: CGPoint(x: Double(rim.x) - half + sway * v, y: Double(rim.y) + depth * v))
            ctx.addLine(to: CGPoint(x: Double(rim.x) + half + sway * v, y: Double(rim.y) + depth * v))
        }
        }
        netPath()                                                        // dark under white: seen on any wallpaper
        ctx.setStrokeColor(outline)
        ctx.setLineWidth(3.4)
        ctx.strokePath()
        netPath()
        ctx.setStrokeColor(netWhite.cgColor)
        ctx.setLineWidth(1.6)
        ctx.strokePath()
        // The rim: an orange ring seen from the side, with a dark outline.
        let ring = CGRect(x: Double(rim.x) - r, y: Double(rim.y) - 4.5, width: 2 * r, height: 9)
        ctx.setStrokeColor(outline)
        ctx.setLineWidth(6.2)
        ctx.strokeEllipse(in: ring)
        ctx.setStrokeColor(rimOrange.cgColor)
        ctx.setLineWidth(3.6)
        ctx.strokeEllipse(in: ring)
    }

    /// The sparks of a firework show at `t`, in a y-down space whose height is `height` (the shows are y-up).
    public static func sparks(_ ctx: CGContext, _ show: Fireworks, at t: Double, origin: CGPoint, height: Double) {
        func local(_ p: CGPoint) -> CGPoint {
            CGPoint(x: Double(p.x) - Double(origin.x), y: height - (Double(p.y) - Double(origin.y)))
        }
        ctx.setLineCap(.round)
        for s in show.sparks {
            guard let now = show.point(s, at: t) else { continue }
            let tail = show.point(s, at: max(s.start, t - 0.09)) ?? now
            let a = show.alpha(s, at: t), c = sparkColors[s.color % sparkColors.count]
            let p = local(now), q = local(tail)
            ctx.setStrokeColor(RGBA(c.r, c.g, c.b, a * 0.85).cgColor)    // a short trail behind each spark
            ctx.setLineWidth(3.2)
            ctx.move(to: q); ctx.addLine(to: p)
            ctx.strokePath()
            ctx.setFillColor(RGBA(c.r, c.g, c.b, a).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 3.2, y: p.y - 3.2, width: 6.4, height: 6.4))
            ctx.setFillColor(RGBA(1, 1, 1, a * 0.85).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 1.3, y: p.y - 1.3, width: 2.6, height: 2.6))
        }
    }
}
