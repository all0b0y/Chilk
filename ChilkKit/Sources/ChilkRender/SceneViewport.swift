import ChilkCore
import CoreGraphics
import Foundation

/// The simulation's scene is a coordinate system, NOT a clipping rectangle.
/// Every surface must enclose the full render plan; only the physical screen may hide the character.
/// Bounds come from the same transformed part bitmaps used by the vector renderer and layer rig,
/// including the sticker border, shadows, sprout, ears, props and speech bubbles.
public struct SceneViewport: Equatable, Sendable {
    /// Canvas in the scene's canonical y-down coordinates. May extend beyond the nominal scene.
    public let rect: CGRect
    public let sceneSize: CGSize

    public init(metrics: Metrics, placements: [Placement]) {
        sceneSize = metrics.sceneSize
        let scene = CGRect(origin: .zero, size: sceneSize)
        let painted = placements.reduce(scene) { bounds, p in
            guard p.alpha > 0 else { return bounds }
            return bounds.union(p.part.bounds(metrics: metrics).applying(p.transform).insetBy(dx: -2, dy: -2))
        }
        // Grow in tiles, not by fractions of a point on every breathing frame. No pixel work or
        // constantly resizing windows while he rests. This is slack, not a hard-coded paint limit.
        let tile = 64.0
        let left = floor(min(0, painted.minX) / tile) * tile
        let top = floor(min(0, painted.minY) / tile) * tile
        let right = scene.width + ceil(max(0, painted.maxX - scene.width) / tile) * tile
        let bottom = scene.height + ceil(max(0, painted.maxY - scene.height) / tile) * tile
        rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Real window frame (AppKit y-up), preserving the logical scene origin and every screen pixel.
    public func panelFrame(sceneOrigin: CGPoint) -> CGRect {
        CGRect(x: sceneOrigin.x + rect.minX,
               y: sceneOrigin.y + sceneSize.height - rect.maxY,
               width: rect.width, height: rect.height)
    }

    /// Canonical scene → expanded bitmap (both y-down).
    public var drawingOffset: CGPoint { CGPoint(x: -rect.minX, y: -rect.minY) }

    /// Canonical rig root → expanded window layer (both y-up).
    public var layerOffset: CGPoint { CGPoint(x: -rect.minX, y: rect.maxY - sceneSize.height) }

    /// Pointer in physical screen coordinates → simulation / button-plan coordinates.
    public func scenePoint(screenPoint: CGPoint, sceneOrigin: CGPoint) -> CGPoint {
        CGPoint(x: screenPoint.x - sceneOrigin.x,
                y: sceneOrigin.y + sceneSize.height - screenPoint.y)
    }
}
