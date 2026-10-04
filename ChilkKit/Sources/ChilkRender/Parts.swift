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
    case body(lw: Double)
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

    public static let waveFrames = 24

    /// Parts that exist only for one speech bubble (bounded cache eviction).
    public var isTransient: Bool {
        switch self {
        case .bubbleBox, .bubbleStroke, .word: true
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
    public static let body = 1
    public static let stem = 2
    public static let leaf = 3          // +0, +1
    public static let blush = 5         // +0, +1
    public static let eye = 7           // +0, +1
    public static let mouth = 9
    public static let z = 10            // +0…+2
    public static let bubbleBox = 13
    public static let bubbleTail = 14
    public static let bubbleStroke = 15
    public static let word = 16         // +index
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
        case .body(let lw):
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

        case .body(let lw):
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
            ChilkRenderer.fillEllipse(ctx, center: CGPoint(x: -m.radiusX * 0.42, y: -m.radiusY * 0.5), rx: 9, ry: 5, rotation: -0.6, color: RGBA(1, 1, 1, 0.75))

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
        }
    }
}

// MARK: - Text

enum TextKit {
    nonisolated(unsafe) static let bubbleFont = CTFontCreateUIFontForLanguage(.emphasizedSystem, 14, nil)!
    nonisolated(unsafe) static let zFont = CTFontCreateUIFontForLanguage(.emphasizedSystem, 15, nil)!

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

/// Word-wrapped speech bubble, measured once per text.
struct BubbleLayout: Sendable {
    struct Word: Sendable { let text: String; let x: Double; let row: Int }
    let words: [Word]
    let width: Double
    let height: Double

    static let rowHeight = 19.0
    private static let cache = Mutex<[String: BubbleLayout]>([:])

    static func of(_ text: String, maxTextWidth: Double) -> BubbleLayout {
        let key = "\(maxTextWidth)|\(text)"
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
        let layout = BubbleLayout(words: words, width: textWidth + 28, height: 38 + Double(rows.count - 1) * rowHeight)
        cache.withLock { c in
            if c.count > 64 { c.removeAll() }
            c[key] = layout
        }
        return layout
    }
}
