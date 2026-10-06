import CoreGraphics

/// Scene geometry in points. The scene is the transparent panel Чилк lives in.
/// It is always modelled as docked to the RIGHT screen edge; the app mirrors it for the left edge.
/// Coordinates are y-down (like the prototype canvas): (0,0) is the top-left of the panel.
public struct Metrics: Sendable, Equatable {
    public var sceneSize: CGSize
    /// Body half-width / half-height.
    public var radiusX: Double
    public var radiusY: Double
    /// Distance from the bottom of the scene to the "floor" Чилк stands on.
    public var floorInset: Double

    public static let standard = Metrics(sceneSize: CGSize(width: 300, height: 300), radiusX: 54, radiusY: 48, floorInset: 44)

    public init(sceneSize: CGSize, radiusX: Double, radiusY: Double, floorInset: Double) {
        self.sceneSize = sceneSize
        self.radiusX = radiusX
        self.radiusY = radiusY
        self.floorInset = floorInset
    }

    public var width: Double { Double(sceneSize.width) }
    public var height: Double { Double(sceneSize.height) }
    public var ground: Double { height - floorInset }
    /// Resting position: mostly behind the screen edge, peeking.
    public var dockX: Double { width - 26 }
    /// Cursor on him: hops fully out — the whole body incl. sticker border and drop shadow is on screen.
    public var peekX: Double { width - radiusX * 1.07 - 24 }
    /// Called: hops out towards the middle of the panel.
    public var outX: Double { width * 0.56 }
    /// Carried around the screen: centred, so the panel edge (invisible away from the screen edge)
    /// never cuts him. Docked, the cut is hidden by the screen edge itself.
    public var carryX: Double { width / 2 }
    /// The tray popover is open (slice 5a): he has gone entirely behind the screen edge, sticker border,
    /// shadow and sprout included, to come out in the popover.
    public var awayX: Double { width + radiusX * 1.5 + 40 }
    /// Hidden behind the edge, peeking out (slice 6d): just behind the edge — leaning in shows the eyes and the sprout.
    public var lurkX: Double { width + 6 }

    /// How far to move the panel (screen points, + = right) when his position inside the panel changes
    /// from `oldX` to `newX`, so that on screen he does not move at all.
    public func panelShiftKeepingPlace(fromX oldX: Double, toX newX: Double, mirrored: Bool) -> Double {
        // screen x = panel.minX + (mirrored ? width − x : x)
        mirrored ? newX - oldX : oldX - newX
    }
}
