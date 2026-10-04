import ChilkCore
import CoreGraphics
import QuartzCore

/// Чилк as a rig of CALayers: one layer per slot, each showing a part bitmap rasterised once.
/// Per frame only transforms, opacity and (rarely) which bitmap a layer shows change, so the window
/// server composites on the GPU and the app does no pixel work at all.
@MainActor
public final class LayerRig {
    public let root = CALayer()
    public let metrics: Metrics
    public let palette: Palette
    /// Pixels per point of the part bitmaps. Above the screen scale so parts stay crisp when scaled up
    /// (eyes on hover ×1.28, squash ×1.17).
    public private(set) var rasterScale: CGFloat

    private final class PartLayer: CALayer {
        var part: Part?
        var slot = 0
        var lastTransform: CGAffineTransform?
        var localRect = CGRect.zero
    }

    private var layers: [Int: PartLayer] = [:]
    private var images: [Part: (image: CGImage, rect: CGRect)] = [:]
    public private(set) var rasterisedCount = 0
    public var cachedImageCount: Int { images.count }
    public var layerCount: Int { layers.count }

    public init(metrics: Metrics, palette: Palette, rasterScale: CGFloat) {
        self.metrics = metrics
        self.palette = palette
        self.rasterScale = rasterScale
        root.frame = CGRect(origin: .zero, size: metrics.sceneSize)
        root.isGeometryFlipped = false
        root.masksToBounds = false
    }

    public func setRasterScale(_ scale: CGFloat) {
        guard scale != rasterScale else { return }
        rasterScale = scale
        images.removeAll()
        for layer in layers.values {
            layer.part = nil              // re-rasterise on next apply
            layer.contentsScale = scale
        }
    }

    /// Shows one frame. Slots missing from `placements` are hidden.
    public func apply(_ placements: [Placement]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var used = Set<Int>(minimumCapacity: placements.count)
        for p in placements {
            let layer = self.layer(for: p.slot)
            if layer.part != p.part {
                let entry = image(for: p.part)
                layer.contents = entry.image
                layer.bounds = CGRect(origin: .zero, size: entry.rect.size)
                layer.localRect = entry.rect
                layer.part = p.part
                layer.lastTransform = nil
            }
            // Settled parts (a bubble that stays, the body at rest) are not touched: fewer CA property commits.
            let t = Self.layerTransform(p.transform, local: layer.localRect, sceneHeight: metrics.height)
            if layer.lastTransform != t {
                layer.setAffineTransform(t)
                layer.lastTransform = t
            }
            let opacity = Float(p.alpha)
            if layer.opacity != opacity { layer.opacity = opacity }
            if layer.isHidden { layer.isHidden = false }
            used.insert(p.slot)
        }
        for (slot, layer) in layers where !used.contains(slot) && !layer.isHidden {
            layer.isHidden = true
        }
        CATransaction.commit()
    }

    /// Part-local (y-down, origin = part origin) → layer-local (y-up, origin = bitmap corner) → scene (y-down)
    /// → root (y-up). With anchorPoint = position = .zero the layer's affine transform is exactly this map.
    static func layerTransform(_ a: CGAffineTransform, local r: CGRect, sceneHeight: Double) -> CGAffineTransform {
        let layerToBitmap = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: r.height)
        let bitmapToPart = CGAffineTransform(translationX: r.minX, y: r.minY)
        let sceneToRoot = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: sceneHeight)
        return layerToBitmap.concatenating(bitmapToPart).concatenating(a).concatenating(sceneToRoot)
    }

    private func layer(for slot: Int) -> PartLayer {
        if let l = layers[slot] { return l }
        let l = PartLayer()
        l.anchorPoint = .zero
        l.position = .zero
        l.contentsGravity = .resize
        l.contentsScale = rasterScale
        l.isOpaque = false
        l.allowsEdgeAntialiasing = false
        l.zPosition = CGFloat(slot)
        l.slot = slot
        // Sublayer order = slot order too: `render(in:)` (tests, snapshots) ignores zPosition.
        let index = (root.sublayers ?? []).firstIndex { ($0 as? PartLayer).map { $0.slot > slot } ?? false }
        if let index { root.insertSublayer(l, at: UInt32(index)) } else { root.addSublayer(l) }
        layers[slot] = l
        return l
    }

    private func image(for part: Part) -> (image: CGImage, rect: CGRect) {
        if let hit = images[part] { return hit }
        let rect = part.bounds(metrics: metrics)
        let w = max(1, Int((rect.width * rasterScale).rounded(.up)))
        let h = max(1, Int((rect.height * rasterScale).rounded(.up)))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: rasterScale, y: -rasterScale)          // y-down, points
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        part.draw(in: ctx, metrics: metrics, palette: palette)
        let entry = (image: ctx.makeImage()!, rect: rect)
        if images.count > 300 {                                // bubbles and words come and go
            images = images.filter { !$0.key.isTransient }
        }
        images[part] = entry
        rasterisedCount += 1
        return entry
    }
}
