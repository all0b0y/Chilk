import ChilkCore
import CoreGraphics
import Foundation

/// The menu-bar icon (slice 5a, decision 3): Chilk's silhouette — the bob with its sprout — as a template image
/// (black on transparent; macOS tints it for light/dark menu bars). The sprout mirrors the user like the one on his
/// head; a dot marks an insisting request or a waiting timer. Drawn once per state, never animated continuously.
public enum TrayIconRenderer {
    /// Point size of the status-item image (menu-bar icons are ~18 pt).
    public static let size = CGSize(width: 20, height: 18)

    /// A bitmap of `size × scale` pixels, premultiplied RGBA, y-up like AppKit.
    public static func image(_ state: TrayIconState, scale: CGFloat) -> CGImage? {
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        draw(state, in: ctx)
        return ctx.makeImage()
    }

    /// Draws in a y-up context sized `size` points.
    public static func draw(_ state: TrayIconState, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))

        // Body: a soft bob sitting on the baseline, a little left of centre to leave room for the dot.
        let body = CGRect(x: 2.5, y: 1.5, width: 14, height: 10)
        ctx.fillEllipse(in: body)

        // Sprout: a stem from the top of the head and one leaf whose angle is the user's state.
        let top = CGPoint(x: body.midX, y: body.maxY - 0.6)
        let (stemTip, leafAngle): (CGPoint, CGFloat) = switch state.leaf {
        case .fresh: (CGPoint(x: top.x + 0.6, y: top.y + 2.6), 0.75)          // up and to the right
        case .drooping: (CGPoint(x: top.x + 1.2, y: top.y + 2.3), -0.1)       // sideways
        case .wilted: (CGPoint(x: top.x + 2.2, y: top.y + 3.0), -1.2)         // hanging down beside the head
        }
        ctx.setLineWidth(1.3)
        ctx.setLineCap(.round)
        ctx.move(to: top)
        ctx.addQuadCurve(to: stemTip, control: CGPoint(x: top.x - 0.4, y: (top.y + stemTip.y) / 2 + 0.6))
        ctx.strokePath()
        ctx.saveGState()
        ctx.translateBy(x: stemTip.x, y: stemTip.y)
        ctx.rotate(by: leafAngle)
        let leaf = CGMutablePath()
        leaf.move(to: .zero)
        leaf.addQuadCurve(to: CGPoint(x: 4.2, y: 0), control: CGPoint(x: 2.1, y: 2.2))
        leaf.addQuadCurve(to: .zero, control: CGPoint(x: 2.1, y: -1.4))
        // A clear halo (like the sticker's cut-out border) keeps a hanging leaf from melting into the head.
        ctx.setBlendMode(.clear)
        ctx.setLineWidth(1.6)
        ctx.addPath(leaf)
        ctx.strokePath()
        ctx.setBlendMode(.normal)
        ctx.addPath(leaf)
        ctx.fillPath()
        ctx.restoreGState()

        // Eyes: two holes punched through the body, so the silhouette still reads as him.
        ctx.setBlendMode(.clear)
        let eyeY = body.minY + body.height * 0.5
        for x in [body.minX + body.width * 0.4, body.minX + body.width * 0.66] {
            ctx.fillEllipse(in: CGRect(x: x - 0.9, y: eyeY - 1.2, width: 1.8, height: 2.4))
        }
        ctx.setBlendMode(.normal)

        if state.dot {
            // A ring of clear space keeps the dot readable next to the sprout.
            let dot = CGRect(x: size.width - 5.6, y: size.height - 5.6, width: 5, height: 5)
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: dot.insetBy(dx: -1.2, dy: -1.2))
            ctx.setBlendMode(.normal)
            ctx.fillEllipse(in: dot)
        }
        ctx.restoreGState()
    }
}
