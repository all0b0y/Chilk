import AppKit
import ChilkCore
import ChilkRender
import QuartzCore

/// Layer-hosting view for the edge panel. By default Чилк is a `LayerRig` (one CALayer per part, moved by
/// transforms, composited on the GPU). `vector: true` (env `CHILK_CG_RENDER=1`) keeps the old CPU path —
/// a CALayer redrawn with CoreGraphics every frame — only for A/B measurements.
final class CharacterView: NSView {
    private let metrics = Metrics.standard
    private let palette = Palette.peach
    private let rig: LayerRig?
    private let vectorLayer: VectorSceneLayer?
    var isVector: Bool { vectorLayer != nil }

    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?

    init(frame: NSRect, vector: Bool) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        if vector {
            let l = VectorSceneLayer()
            l.contentsScale = scale
            vectorLayer = l
            rig = nil
        } else {
            rig = LayerRig(metrics: .standard, palette: .peach, rasterScale: Self.rasterScale(for: scale))
            vectorLayer = nil
        }
        super.init(frame: frame)
        let host: CALayer = rig?.root ?? vectorLayer!
        host.frame = CGRect(origin: .zero, size: frame.size)
        layer = host                              // set before wantsLayer → layer-hosting
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Part bitmaps at 1.5× the screen scale: crisp while scaled up (hover eyes ×1.28, squash ×1.17).
    private static func rasterScale(for screenScale: CGFloat) -> CGFloat { screenScale * 1.5 }

    @MainActor
    func show(pose: CharacterPose, mirrored: Bool) {
        if let rig {
            rig.apply(ChilkRenderer.placements(pose: pose, metrics: metrics, mirrored: mirrored))
        } else if let v = vectorLayer {
            v.pose = pose
            v.mirrored = mirrored
            v.setNeedsDisplay()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        MainActor.assumeIsolated { () -> Void in rig?.setRasterScale(Self.rasterScale(for: scale)) }
        if let v = vectorLayer, v.contentsScale != scale {
            v.contentsScale = scale
            v.setNeedsDisplay()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(event) }
}

/// Old CPU path, kept for A/B measurements: the whole scene redrawn with CoreGraphics each frame.
final class VectorSceneLayer: CALayer {
    var pose = CharacterPose()
    var mirrored = false

    override init() {
        super.init()
        isOpaque = false
        contentsFormat = .RGBA8Uint
        actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "contentsScale": NSNull()]
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(in ctx: CGContext) {
        ctx.saveGState()
        if ctx.ctm.d > 0 {                        // y-up context → the renderer's y-down space
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.clear(ctx.boundingBoxOfClipPath)
        ChilkRenderer.drawScene(in: ctx, pose: pose, metrics: .standard, palette: .peach, mirrored: mirrored)
        ctx.restoreGState()
    }
}
