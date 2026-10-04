import ChilkCore
import CoreGraphics
import Foundation

/// Outlines that never change shape (only the CTM moves them) are stroked ONCE into fillable shapes.
/// Stroking — especially the 12 pt sticker border with round joins — was the most expensive CoreGraphics
/// operation of every frame; filling a cached ring under a transform gives identical pixels.
final class ShapeCache: @unchecked Sendable {
    static let shared = ShapeCache()

    struct Body {
        let blob: CGPath
        let border: CGPath      // white die-cut ring, 12 pt
        let outline: CGPath     // dark outline ring
    }

    struct Leaf {
        let fill: CGPath
        let outline: CGPath
        let vein: CGPath
    }

    private let lock = NSLock()
    private var bodies: [String: Body] = [:]
    private var leaves: [String: [Leaf]] = [:]
    private var stems: [String: CGPath] = [:]

    func body(_ m: Metrics, lineScale lw: Double) -> Body {
        let key = "\(m.radiusX)|\(m.radiusY)|\(lw)"
        lock.lock(); defer { lock.unlock() }
        if let b = bodies[key] { return b }
        let blob = Self.blobPath(m)
        let b = Body(blob: blob,
                     border: blob.copy(strokingWithWidth: 12, lineCap: .butt, lineJoin: .round, miterLimit: 10),
                     outline: blob.copy(strokingWithWidth: 3.6 * lw, lineCap: .butt, lineJoin: .round, miterLimit: 10))
        bodies[key] = b
        return b
    }

    /// The two leaves in leaf-local space (rotation/scale come from the CTM).
    func leaves(lineScale lw: Double) -> [Leaf] {
        let key = "\(lw)"
        lock.lock(); defer { lock.unlock() }
        if let l = leaves[key] { return l }
        let l = [(L: 20.0, w: 9.5), (L: 17.0, w: 8.5)].map { spec -> Leaf in
            let shape = Self.leafPath(length: spec.L, width: spec.w)
            let vein = CGMutablePath()
            vein.move(to: CGPoint(x: 0, y: -2))
            vein.addLine(to: CGPoint(x: 0, y: -spec.L * 0.7))
            return Leaf(fill: shape,
                        outline: shape.copy(strokingWithWidth: 2.6 * lw, lineCap: .round, lineJoin: .round, miterLimit: 10),
                        vein: vein.copy(strokingWithWidth: 1.2 * lw, lineCap: .round, lineJoin: .round, miterLimit: 10))
        }
        leaves[key] = l
        return l
    }

    /// Stem for a (quantised) fatigue level.
    func stem(fatigue f: Double, tip: CGPoint, length len: Double, lineScale lw: Double) -> CGPath {
        let key = "\(f)|\(lw)"
        lock.lock(); defer { lock.unlock() }
        if let s = stems[key] { return s }
        let stem = CGMutablePath()
        stem.move(to: CGPoint(x: 0, y: 2))
        stem.addQuadCurve(to: tip, control: CGPoint(x: 4 + f * 12, y: -len * (0.5 + f * 0.55)))
        let ring = stem.copy(strokingWithWidth: 3.2 * lw, lineCap: .round, lineJoin: .round, miterLimit: 10)
        if stems.count > 300 { stems.removeAll() }
        stems[key] = ring
        return ring
    }

    static func blobPath(_ m: Metrics) -> CGPath {
        let path = CGMutablePath()
        let n = 2.25
        for i in 0...80 {
            let a = Double(i) / 80 * .pi * 2
            let c = cos(a), s = sin(a)
            let signC: Double = c < 0 ? -1 : 1
            let signS: Double = s < 0 ? -1 : 1
            let bean: Double = 1 + 0.07 * max(0, s) - 0.05 * max(0, -s)   // fuller bottom, narrower top
            let px: Double = m.radiusX * signC * pow(abs(c), 2 / n) * bean
            let py: Double = m.radiusY * signS * pow(abs(s), 2 / n)
            if i == 0 { path.move(to: CGPoint(x: px, y: py)) } else { path.addLine(to: CGPoint(x: px, y: py)) }
        }
        path.closeSubpath()
        return path
    }

    static func leafPath(length L: Double, width w: Double) -> CGPath {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addQuadCurve(to: CGPoint(x: 0, y: -L), control: CGPoint(x: w, y: -L * 0.5))
        path.addQuadCurve(to: .zero, control: CGPoint(x: -w, y: -L * 0.5))
        path.closeSubpath()
        return path
    }
}
