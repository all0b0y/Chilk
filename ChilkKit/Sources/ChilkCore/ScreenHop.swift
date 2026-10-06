import CoreGraphics
import Foundation

/// Slice 6e (SPEC 20–21): the monitor Chilk lives on. He follows the active one — a whole second there, then one leap;
/// busy, he waits and leaps right after; hidden, he just moves over; a pinned monitor holds him while it is plugged in.
public struct ScreenHop: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case stay
        /// Leap there along an arc (the panel flies).
        case hop(to: String)
        /// Be there at once, no flight (first frame, his monitor unplugged, hidden).
        case move(to: String)
    }

    /// The monitor's id he lives on (`nil` before the first step).
    public private(set) var home: String?
    private var candidate: String?
    private var since = 0.0

    /// How long the other monitor must stay active before he leaps.
    public static let dwell = 1.0

    public init(home: String? = nil) { self.home = home }

    /// `active`: the monitor with the active window; `pinned`: Settings → screen (nil = follow); `now`: seconds.
    public mutating func step(active: String?, connected: [String], now: Double, busy: Bool, hidden: Bool,
                              pinned: String?) -> Step {
        let target = pinned.flatMap { connected.contains($0) ? $0 : nil } ?? active ?? home
        guard let target else { return .stay }
        guard let current = home, connected.contains(current) else {
            home = target
            candidate = nil
            return .move(to: target)
        }
        guard target != current else { candidate = nil; return .stay }
        if candidate != target { candidate = target; since = now }
        guard now - since >= Self.dwell - 1e-9, !busy else { return .stay }
        home = target
        candidate = nil
        return hidden ? .move(to: target) : .hop(to: target)
    }
}

/// The leap's path between two panel origins (AppKit, y-up): a crouch, an arc over the higher end, a landing.
public struct HopArc: Equatable, Sendable {
    public static let crouch = 0.15
    public static let land = 0.25

    public let from: CGPoint
    public let to: CGPoint
    /// Seconds in the air: 0.8…1.4, growing with the distance.
    public let flight: Double
    /// How far the top of the arc is above the higher end.
    public let lift: Double

    public init(from: CGPoint, to: CGPoint) {
        self.from = from
        self.to = to
        let d = Double(hypot(to.x - from.x, to.y - from.y))
        flight = 0.8 + 0.6 * min(1, d / 2400)
        lift = 90 + min(260, d * 0.12)
    }

    public var total: Double { Self.crouch + flight + Self.land }

    /// Where the panel is `t` seconds after the leap started.
    public func point(at t: Double) -> CGPoint {
        let u = min(1, max(0, (t - Self.crouch) / flight))
        if u <= 0 { return from }
        if u >= 1 { return to }
        let e = u * u * (3 - 2 * u)                                       // eased along the way
        let base = Double(from.y) + Double(to.y - from.y) * e
        let higher = Double(max(from.y, to.y))
        // A parabola whose top is `lift` above the higher end.
        let bump = 4 * u * (1 - u) * (higher + lift - (Double(from.y) + Double(to.y)) / 2)
        return CGPoint(x: Double(from.x) + Double(to.x - from.x) * e, y: base + bump)
    }
}
