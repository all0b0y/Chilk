import ChilkCore
import CoreGraphics
import CoreText
import Foundation
import Synchronization

/// One drawable piece of Чилк. Its shape never changes per frame — where it goes, how it is rotated,
/// scaled and faded comes from a `Placement`. Shapes that change slowly (stem bend and leaf colour with
/// fatigue, the smile) are quantised to percent steps; the dizzy mouth wave is a 24-frame flipbook.
public enum Part: Hashable, Sendable {
    case contactShadow
    case body(lw: Double, shine: Bool = true)
    case stem(f: Int, lw: Double)                 // f = fatigue, percent
    case leaf(index: Int, f: Int, lw: Double)
    case blush
    case eyeOpen
    case eyeHappy(lw: Double)
    case eyeSleep(lw: Double)
    case eyeAnnoyed(side: Int, lw: Double)
    case eyeDizzy(lw: Double)
    case mouthSmile(tired: Int, lw: Double)        // tired, percent
    case mouthOpen(yawn: Bool)
    case mouthFrown(lw: Double)
    case mouthWave(phase: Int, lw: Double)         // 0..<waveFrames
    case mouthO
    case z
    case bubbleBox(width: Double, height: Double)
    case bubbleStroke(width: Double, height: Double)
    case bubbleTail
    case word(String)
    case backpack(lw: Double)
    case strap(lw: Double)
    case hat(lw: Double)
    case mug(lw: Double)
    case button(title: String, hovered: Bool)
    case ear(lw: Double)

    public static let waveFrames = 24

    /// Parts that exist only for one speech bubble (bounded cache eviction).
    public var isTransient: Bool {
        switch self {
        case .bubbleBox, .bubbleStroke, .word, .button: true
        default: false
        }
    }
}

/// Where a part goes this frame. `transform` maps part-local to scene coordinates (both y-down),
/// built with the same calls the CoreGraphics renderer makes on its CTM.
public struct Placement: Equatable, @unchecked Sendable {
    /// Stable identity of the visual element and its z-order (higher = on top).
    public var slot: Int
    public var part: Part
    public var transform: CGAffineTransform
    public var alpha: Double
}

/// Slot numbers = drawing order.
public enum Slot {
    public static let contactShadow = 0
    public static let ear = 1           // +0, +1 — behind the head
    public static let backpack = 3      // behind him
    public static let body = 4
    public static let strap = 5
    public static let hat = 6           // the sprout grows through it
    public static let stem = 7
    public static let leaf = 8          // +0, +1
    public static let blush = 10        // +0, +1
    public static let eye = 12          // +0, +1
    public static let mouth = 14
    public static let mug = 15
    public static let z = 16            // +0…+2
    public static let bubbleBox = 19
    public static let bubbleTail = 20
    public static let bubbleStroke = 21
    public static let button = 22       // +index
    public static let word = 34         // +index
}

// MARK: - Geometry and drawing of single parts (part-local, y-down)

extension Part {
    /// Conservative local bounds in whole points. Everything `draw` paints is inside
    /// (checked by `partsStayInsideTheirBitmaps`).
    public func bounds(metrics m: Metrics) -> CGRect {
        func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double, margin: Double) -> CGRect {
            CGRect(x: x - margin, y: y - margin, width: w + margin * 2, height: h + margin * 2).integral
        }
        switch self {
        case .contactShadow:
            return box(-m.radiusX * 0.92, -7, m.radiusX * 1.84, 14, margin: 2)
        case .body(let lw, _):
            let edge = max(7, 3.6 * lw / 2 + 1.5)
            return box(-m.radiusX * 1.07, -m.radiusY, m.radiusX * 2.14 + 5, m.radiusY * 2 + 6, margin: edge)
        case .stem(let fp, let lw):
            let f = Double(fp) / 100, len = 22 + f * 2
            let tip = CGPoint(x: f * 16, y: -len * (1 - f * 0.62))
            let ctrl = CGPoint(x: 4 + f * 12, y: -len * (0.5 + f * 0.55))
            let xs = [0, Double(tip.x), Double(ctrl.x)], ys = [2, Double(tip.y), Double(ctrl.y)]
            return box(xs.min()!, ys.min()!, xs.max()! - xs.min()!, ys.max()! - ys.min()!, margin: 3.2 * lw / 2 + 1.5)
        case .leaf(let i, _, let lw):
            let (L, w) = i == 0 ? (20.0, 9.5) : (17.0, 8.5)
            return box(-w, -L, w * 2, L, margin: 2.6 * lw / 2 + 1.5)
        case .blush:
            return box(-9, -5.5, 18, 11, margin: 1.5)
        case .eyeOpen:
            let r = 7.2
            return box(-r * 0.8, -r * 1.25, r * 1.6, r * 2.5, margin: 1.5)
        case .eyeHappy(let lw), .eyeSleep(let lw), .eyeAnnoyed(_, let lw):
            return box(-8, -8, 16, 16, margin: 3.4 * lw / 2 + 1.5)
        case .eyeDizzy(let lw):
            let r = Double.pi * 5 * 1.25
            return box(-r, -r, r * 2, r * 2, margin: 2.4 * lw / 2 + 1.5)
        case .mouthSmile(_, let lw), .mouthFrown(let lw):
            return box(-7, -4, 14, 8, margin: 2.6 * lw / 2 + 1.5)
        case .mouthWave(_, let lw):
            return box(-8, -2, 16, 4, margin: 2.6 * lw / 2 + 1.5)
        case .mouthOpen(let yawn):
            let h = yawn ? 9.0 : 6.5
            return box(-7, -1, 14, h * 0.8 + 1, margin: 1.5)
        case .mouthO:
            let r = 4.2
            return box(-r * 0.85, 1 - r, r * 1.7, r * 2, margin: 1.5)
        case .z:
            let (w, ascent, descent) = TextKit.metrics("z", font: TextKit.zFont)
            return box(0, -ascent, w, ascent + descent, margin: 1.5)
        case .bubbleBox(let w, let h):
            return box(0, 0, w, h, margin: 1)
        case .bubbleStroke(let w, let h):
            return box(0, 0, w, h, margin: 2.5)
        case .bubbleTail:
            return box(-9, -1, 15, 11, margin: 1.5)
        case .word(let s):
            let (w, ascent, descent) = TextKit.metrics(s, font: TextKit.bubbleFont)
            return box(0, -ascent, w, ascent + descent, margin: 1.5)
        case .backpack(let lw):
            return box(Props.bag.minX, Props.bag.minY, Props.bag.width, Props.bag.height, margin: max(5.5, 3.2 * lw / 2 + 1.5))
        case .strap(let lw):
            let r = Props.strapPath(m).boundingBoxOfPath
            return box(r.minX, r.minY, r.width, r.height, margin: (Props.strapWidth + 3.2 * lw) / 2 + 1.5)
        case .hat(let lw):
            return box(-33, -21, 66, 33, margin: max(5.5, 3 * lw / 2 + 1.5))
        case .mug:
            return box(-16.5, -10, 25, 20, margin: 5.5)
        case .button(let title, _):
            return box(0, 0, Props.buttonWidth(title), Props.buttonHeight, margin: 1.5)
        case .ear(let lw):
            return box(-9, -30, 18, 30, margin: max(5.5, 3.2 * lw / 2 + 1.5))
        }
    }

    /// Draws the part around its local origin into a y-down context.
    public func draw(in ctx: CGContext, metrics m: Metrics, palette p: Palette) {
        let outline = p.outline.cgColor
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        func stroke(_ width: Double, _ build: () -> Void) {
            build()
            ctx.setStrokeColor(outline)
            ctx.setLineWidth(width)
            ctx.strokePath()
        }
        switch self {
        case .contactShadow:
            ctx.setFillColor(RGBA(0, 0, 0, 0.16).cgColor)
            ctx.fillEllipse(in: CGRect(x: -m.radiusX * 0.92, y: -7, width: m.radiusX * 1.84, height: 14))

        case .body(let lw, let shine):
            let shapes = ShapeCache.shared.body(m, lineScale: lw)
            ctx.saveGState()
            ctx.translateBy(x: 5, y: 6)
            ctx.addPath(shapes.blob)
            ctx.setFillColor(RGBA.rgb255(43, 41, 56, 0.16).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(shapes.border)                      // sticker die-cut border
            ctx.setFillColor(RGBA.white.cgColor)
            ctx.fillPath()
            ctx.addPath(shapes.blob)
            ctx.setFillColor(p.body.cgColor)
            ctx.fillPath()
            ctx.addPath(shapes.outline)
            ctx.setFillColor(outline)
            ctx.fillPath()
            if shine {                                      // the volume highlight hides under a hat
                ChilkRenderer.fillEllipse(ctx, center: CGPoint(x: -m.radiusX * 0.42, y: -m.radiusY * 0.5), rx: 9, ry: 5, rotation: -0.6, color: RGBA(1, 1, 1, 0.75))
            }

        case .stem(let fp, let lw):
            let f = Double(fp) / 100, len = 22 + f * 2
            let tip = CGPoint(x: f * 16, y: -len * (1 - f * 0.62))
            ctx.addPath(ShapeCache.shared.stem(fatigue: f, tip: tip, length: len, lineScale: lw))
            ctx.setFillColor(outline)
            ctx.fillPath()

        case .leaf(let i, let fp, let lw):
            let shapes = ShapeCache.shared.leaves(lineScale: lw)[i]
            ctx.addPath(shapes.fill)
            ctx.setFillColor(p.leaf.mixed(with: p.leafTired, Double(fp) / 100).cgColor)
            ctx.fillPath()
            ctx.setFillColor(outline)
            ctx.addPath(shapes.outline)
            ctx.fillPath()
            ctx.addPath(shapes.vein)
            ctx.fillPath()

        case .blush:
            ctx.setFillColor(p.blush.cgColor)
            ctx.fillEllipse(in: CGRect(x: -9, y: -5.5, width: 18, height: 11))

        case .eyeOpen:
            let r = 7.2
            ctx.setFillColor(outline)
            ctx.fillEllipse(in: CGRect(x: -r * 0.8, y: -r * 1.25, width: r * 1.6, height: r * 2.5))
            ctx.setFillColor(RGBA.white.cgColor)
            let hr = r * 0.32
            ctx.fillEllipse(in: CGRect(x: -r * 0.26 - hr, y: -r * 0.45 - hr, width: hr * 2, height: hr * 2))

        case .eyeHappy(let lw):                             // closed / happy ^ ^
            stroke(3.4 * lw) {
                var a = Double.pi * 1.1
                ctx.move(to: CGPoint(x: cos(a) * 7, y: 2 + sin(a) * 7))
                while a < .pi * 1.9 { a += 0.05; ctx.addLine(to: CGPoint(x: cos(a) * 7, y: 2 + sin(a) * 7)) }
            }

        case .eyeSleep(let lw):                             // relaxed lids ‿
            stroke(3.4 * lw) {
                var a = Double.pi * 0.12
                ctx.move(to: CGPoint(x: cos(a) * 6.5, y: -3 + sin(a) * 6.5))
                while a < .pi * 0.88 { a += 0.05; ctx.addLine(to: CGPoint(x: cos(a) * 6.5, y: -3 + sin(a) * 6.5)) }
            }

        case .eyeAnnoyed(let side, let lw):                 // > <
            let s = Double(side)
            stroke(3.4 * lw) {
                ctx.move(to: CGPoint(x: -s * 6, y: -6))
                ctx.addLine(to: CGPoint(x: s * 4, y: 0))
                ctx.addLine(to: CGPoint(x: -s * 6, y: 6))
            }

        case .eyeDizzy(let lw):                             // spiral; rotation comes from the placement
            stroke(2.4 * lw) {
                var a = 0.0
                ctx.move(to: .zero)
                while a < .pi * 5 { let r = a * 1.25; ctx.addLine(to: CGPoint(x: cos(a) * r, y: sin(a) * r)); a += 0.2 }
            }

        case .mouthSmile(let tp, let lw):
            let smile = 4.5 * (1 - Double(tp) / 100 * 1.1)
            stroke(2.6 * lw) {
                ctx.move(to: CGPoint(x: -6, y: 0))
                ctx.addQuadCurve(to: CGPoint(x: 6, y: 0), control: CGPoint(x: 0, y: smile))
            }

        case .mouthFrown(let lw):
            stroke(2.6 * lw) {
                ctx.move(to: CGPoint(x: -5, y: 2))
                ctx.addQuadCurve(to: CGPoint(x: 5, y: 2), control: CGPoint(x: 0, y: -1.5))
            }

        case .mouthWave(let k, let lw):
            let phase = Double(k) / Double(Part.waveFrames) * 2 * .pi
            stroke(2.6 * lw) {
                ctx.move(to: CGPoint(x: -8, y: sin(-8 * 0.9 + phase) * 1.8))
                for i in -7...8 { ctx.addLine(to: CGPoint(x: Double(i), y: sin(Double(i) * 0.9 + phase) * 1.8)) }
            }

        case .mouthOpen(let yawn):
            let h = yawn ? 9.0 : 6.5
            let mouth = CGMutablePath()
            mouth.move(to: CGPoint(x: -7, y: -1))
            mouth.addQuadCurve(to: CGPoint(x: 7, y: -1), control: CGPoint(x: 0, y: h * 1.6))
            mouth.closeSubpath()
            ctx.saveGState()
            ctx.addPath(mouth)
            ctx.setFillColor(outline)
            ctx.fillPath()
            ctx.addPath(mouth)
            ctx.clip()
            ctx.setFillColor(RGBA.hex(0xFF8E9A).cgColor)
            ctx.fillEllipse(in: CGRect(x: -4.5, y: h - 3, width: 9, height: 6))
            ctx.restoreGState()

        case .mouthO:
            let r = 4.2
            ctx.setFillColor(outline)
            ctx.fillEllipse(in: CGRect(x: -r * 0.85, y: 1 - r, width: r * 1.7, height: r * 2))

        case .z:
            TextKit.draw("z", font: TextKit.zFont, color: outline, in: ctx)

        case .bubbleBox(let w, let h):
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: 14, cornerHeight: 14, transform: nil))
            ctx.setFillColor(RGBA.white.cgColor)
            ctx.fillPath()

        case .bubbleStroke(let w, let h):
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: 14, cornerHeight: 14, transform: nil))
            ctx.setStrokeColor(outline)
            ctx.setLineWidth(2.4)
            ctx.setLineJoin(.miter)
            ctx.strokePath()

        case .bubbleTail:
            ctx.move(to: CGPoint(x: -9, y: -1))
            ctx.addLine(to: CGPoint(x: 6, y: 10))
            ctx.addLine(to: CGPoint(x: 4, y: -1))
            ctx.closePath()
            ctx.setFillColor(RGBA.white.cgColor)
            ctx.fillPath()

        case .word(let s):
            TextKit.draw(s, font: TextKit.bubbleFont, color: RGBA.hex(0x1D1D1F).cgColor, in: ctx)

        case .backpack(let lw):                             // on his back: behind the body
            let bag = CGPath(roundedRect: Props.bag, cornerWidth: 9, cornerHeight: 9, transform: nil)
            Props.sticker(ctx, bag, fill: Props.bagBlue, outline: outline, lw: 3.2 * lw)
            let pocket = CGRect(x: Props.bag.minX + 5, y: Props.bag.midY + 2, width: Props.bag.width - 10, height: Props.bag.height / 2 - 8)
            ctx.addPath(CGPath(roundedRect: pocket, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.setFillColor(Props.bagLight)
            ctx.fillPath()
            ctx.addPath(CGPath(roundedRect: pocket, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.setStrokeColor(outline)
            ctx.setLineWidth(2 * lw)
            ctx.strokePath()

        case .strap(let lw):                                // the backpack strap over his shoulder
            let path = Props.strapPath(m)
            ctx.addPath(path)
            ctx.setStrokeColor(outline)
            ctx.setLineWidth(Props.strapWidth + 3.2 * lw)
            ctx.strokePath()
            ctx.addPath(path)
            ctx.setStrokeColor(Props.strapBlue)
            ctx.setLineWidth(Props.strapWidth)
            ctx.strokePath()

        case .hat(let lw):                                  // knitted beanie; the sprout pokes through
            let dome = CGMutablePath()
            dome.move(to: CGPoint(x: -29, y: 4))
            dome.addCurve(to: CGPoint(x: 0, y: -21), control1: CGPoint(x: -29, y: -12), control2: CGPoint(x: -17, y: -21))
            dome.addCurve(to: CGPoint(x: 29, y: 4), control1: CGPoint(x: 17, y: -21), control2: CGPoint(x: 29, y: -12))
            dome.closeSubpath()
            let band = CGPath(roundedRect: CGRect(x: -33, y: 0, width: 66, height: 12), cornerWidth: 6, cornerHeight: 6, transform: nil)
            let whole = CGMutablePath()
            whole.addPath(dome)
            whole.addPath(band)
            ctx.addPath(whole)
            ctx.setStrokeColor(RGBA.white.cgColor)
            ctx.setLineWidth(9)
            ctx.strokePath()                                // sticker die-cut border
            Props.sticker(ctx, dome, fill: Props.hatYellow, outline: outline, lw: 3 * lw, border: false)
            Props.sticker(ctx, band, fill: Props.hatBand, outline: outline, lw: 3 * lw, border: false)
            ctx.setStrokeColor(outline)
            ctx.setLineWidth(1.4 * lw)
            for x in stride(from: -24.0, through: 24, by: 8) {
                ctx.move(to: CGPoint(x: x, y: 3.5))
                ctx.addLine(to: CGPoint(x: x, y: 8.5))
            }
            ctx.strokePath()

        case .mug(let lw):                                  // a mint mug, handle towards the viewer's left
            let body = CGPath(roundedRect: CGRect(x: -8, y: -9, width: 16, height: 18), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
            let handle = CGMutablePath()
            handle.addArc(center: CGPoint(x: -8, y: 0), radius: 5, startAngle: .pi / 2, endAngle: .pi * 1.5, clockwise: false)
            ctx.addPath(handle)
            ctx.setStrokeColor(RGBA.white.cgColor)
            ctx.setLineWidth(10)
            ctx.strokePath()
            ctx.addPath(body)
            ctx.setStrokeColor(RGBA.white.cgColor)
            ctx.setLineWidth(9)
            ctx.strokePath()
            ctx.addPath(handle)
            ctx.setStrokeColor(outline)
            ctx.setLineWidth(3.6)
            ctx.strokePath()
            Props.sticker(ctx, body, fill: Props.mugMint, outline: outline, lw: 2.6 * lw, border: false)
            ctx.setFillColor(RGBA(1, 1, 1, 0.85).cgColor)
            ctx.fill(CGRect(x: -6, y: -2, width: 12, height: 3.5))

        case .ear(let lw):                                  // little rounded ear, base at the origin
            let ear = CGPath(ellipseIn: CGRect(x: -9, y: -30, width: 18, height: 30), transform: nil)
            Props.sticker(ctx, ear, fill: p.body.cgColor, outline: outline, lw: 3.2 * lw)
            ctx.setFillColor(p.blush.cgColor)
            ctx.fillEllipse(in: CGRect(x: -4.5, y: -24, width: 9, height: 17))

        case .button(let title, let hovered):
            let rect = CGRect(x: 0, y: 0, width: Props.buttonWidth(title), height: Props.buttonHeight)
            let pill = CGPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 11, cornerHeight: 11, transform: nil)
            ctx.addPath(pill)
            ctx.setFillColor(hovered ? outline : Props.buttonFill)
            ctx.fillPath()
            ctx.addPath(pill)
            ctx.setStrokeColor(outline)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
            ctx.saveGState()
            ctx.translateBy(x: Props.buttonPadding, y: 16.5)
            TextKit.draw(title, font: TextKit.buttonFont, color: hovered ? RGBA.white.cgColor : RGBA.hex(0x1D1D1F).cgColor, in: ctx)
            ctx.restoreGState()
        }
    }
}

/// Geometry and colours of the props and bubble buttons (figure space: body centre = origin, y-down).
enum Props {
    static let bag = CGRect(x: 36, y: -26, width: 31, height: 44)   // peeks out from behind his back
    static let strapWidth = 5.0
    static let buttonHeight = 24.0
    static let buttonPadding = 10.0
    static let bagBlue = RGBA.hex(0x6FA8DC).cgColor
    static let bagLight = RGBA.hex(0x9CC6EC).cgColor
    static let strapBlue = RGBA.hex(0x4C83BF).cgColor
    static let hatYellow = RGBA.hex(0xF4B942).cgColor
    static let hatBand = RGBA.hex(0xE3953A).cgColor
    static let mugMint = RGBA.hex(0x8FD6C4).cgColor
    static let buttonFill = RGBA.hex(0xF3EEE6).cgColor

    static func strapPath(_ m: Metrics) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: m.radiusX * 0.52, y: -m.radiusY * 0.76))
        p.addQuadCurve(to: CGPoint(x: m.radiusX * 0.88, y: m.radiusY * 0.18), control: CGPoint(x: m.radiusX * 0.76, y: -m.radiusY * 0.38))
        return p
    }

    /// Measured once per title: hit testing asks for it every frame while a bubble shows.
    static func buttonWidth(_ title: String) -> Double {
        if let w = widths.withLock({ $0[title] }) { return w }
        let w = (TextKit.width(title, font: TextKit.buttonFont) + buttonPadding * 2).rounded(.up)
        widths.withLock { c in
            if c.count > 200 { c.removeAll() }
            c[title] = w
        }
        return w
    }

    private static let widths = Mutex<[String: Double]>([:])

    /// Fill + outline, optionally with the white die-cut border of the sticker look.
    static func sticker(_ ctx: CGContext, _ path: CGPath, fill: CGColor, outline: CGColor, lw: Double, border: Bool = true) {
        if border {
            ctx.addPath(path)
            ctx.setStrokeColor(RGBA.white.cgColor)
            ctx.setLineWidth(9)
            ctx.strokePath()
        }
        ctx.addPath(path)
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(outline)
        ctx.setLineWidth(lw)
        ctx.strokePath()
    }
}

// MARK: - Text

enum TextKit {
    nonisolated(unsafe) static let bubbleFont = CTFontCreateUIFontForLanguage(.emphasizedSystem, 14, nil)!
    nonisolated(unsafe) static let zFont = CTFontCreateUIFontForLanguage(.emphasizedSystem, 15, nil)!
    nonisolated(unsafe) static let buttonFont = CTFontCreateUIFontForLanguage(.emphasizedSystem, 12, nil)!

    static func line(_ s: String, font: CTFont, color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]))
    }

    static func width(_ s: String, font: CTFont) -> Double {
        CTLineGetTypographicBounds(line(s, font: font, color: RGBA.white.cgColor), nil, nil, nil)
    }

    /// (advance width, ascent, descent)
    static func metrics(_ s: String, font: CTFont) -> (Double, Double, Double) {
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let w = CTLineGetTypographicBounds(line(s, font: font, color: RGBA.white.cgColor), &ascent, &descent, nil)
        return (w, Double(ascent), Double(descent))
    }

    /// Baseline at the local origin, glyphs upright in a y-down context.
    static func draw(_ s: String, font: CTFont, color: CGColor, in ctx: CGContext) {
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line(s, font: font, color: color), ctx)
        ctx.restoreGState()
    }
}

/// Word-wrapped speech bubble with optional buttons, measured once per text.
struct BubbleLayout: Sendable {
    struct Word: Sendable { let text: String; let x: Double; let row: Int }
    struct Button: Sendable { let title: String; let x: Double; let y: Double; let width: Double }
    let words: [Word]
    let buttons: [Button]
    let width: Double
    let height: Double

    static let rowHeight = 19.0
    static let buttonRow = Props.buttonHeight + 6
    private static let cache = Mutex<[String: BubbleLayout]>([:])

    static func of(_ text: String, buttons titles: [String] = [], maxTextWidth: Double) -> BubbleLayout {
        let key = "\(maxTextWidth)|\(text)|\(titles.joined(separator: "\u{1}"))"
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let font = TextKit.bubbleFont
        var rows: [[String]] = [[]]
        for word in text.split(separator: " ").map(String.init) {
            let candidate = (rows[rows.count - 1] + [word]).joined(separator: " ")
            if !rows[rows.count - 1].isEmpty && TextKit.width(candidate, font: font) > maxTextWidth {
                rows.append([word])
            } else {
                rows[rows.count - 1].append(word)
            }
        }
        var words: [Word] = []
        for (r, row) in rows.enumerated() {
            var x = 0.0
            for w in row {
                words.append(Word(text: w, x: x, row: r))
                x += TextKit.width(w + " ", font: font)
            }
        }
        let textWidth = rows.map { TextKit.width($0.joined(separator: " "), font: font) }.max() ?? 0
        var height = 38 + Double(rows.count - 1) * rowHeight

        // Buttons: pills under the text, wrapped like words.
        var buttons: [Button] = []
        var rowWidth = 0.0, widest = 0.0, buttonRows = 0
        let top = 34 + Double(rows.count - 1) * rowHeight
        for title in titles {
            let w = Props.buttonWidth(title)
            if rowWidth > 0 && rowWidth + 6 + w > maxTextWidth { buttonRows += 1; rowWidth = 0 }
            let x = rowWidth == 0 ? 0 : rowWidth + 6
            buttons.append(Button(title: title, x: x, y: top + Double(buttonRows) * buttonRow, width: w))
            rowWidth = x + w
            widest = max(widest, rowWidth)
        }
        if !titles.isEmpty { height = top + Double(buttonRows + 1) * buttonRow + 4 }

        let layout = BubbleLayout(words: words, buttons: buttons, width: max(textWidth, widest) + 28, height: height)
        cache.withLock { c in
            if c.count > 64 { c.removeAll() }
            c[key] = layout
        }
        return layout
    }
}
