import CoreGraphics

public enum Edge: String, Codable, Sendable {
    case left, right
}

/// Where Чилк lives: which screen edge and how high (0 = bottom, 1 = top of the visible frame).
/// All frames are AppKit screen coordinates (y-up).
public struct EdgePlacement: Codable, Equatable, Sendable {
    public var edge: Edge
    public var verticalFraction: Double

    public static let `default` = EdgePlacement(edge: .right, verticalFraction: 0.18)

    public init(edge: Edge, verticalFraction: Double) {
        self.edge = edge
        self.verticalFraction = min(1, max(0, verticalFraction))
    }

    public func panelOrigin(panelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        let x = edge == .right ? visibleFrame.maxX - panelSize.width : visibleFrame.minX
        let span = max(0, visibleFrame.height - panelSize.height)
        return CGPoint(x: x, y: visibleFrame.minY + span * verticalFraction)
    }

    /// After a drag: snap to the nearer edge, keep the height (clamped to the screen).
    public static func dropped(panelOrigin: CGPoint, panelSize: CGSize, visibleFrame: CGRect) -> EdgePlacement {
        let centerX = panelOrigin.x + panelSize.width / 2
        let edge: Edge = centerX < visibleFrame.midX ? .left : .right
        let span = visibleFrame.height - panelSize.height
        let fraction = span > 0 ? Double((panelOrigin.y - visibleFrame.minY) / span) : 0
        return EdgePlacement(edge: edge, verticalFraction: fraction)
    }
}
