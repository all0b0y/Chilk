/// Damped spring integrated with semi-implicit Euler.
/// The same model drives every moving part of Чилк (position, squash, gaze, leaf…),
/// tuned per part with `stiffness` (snappiness) and `damping` (how much it wobbles).
public struct Spring: Sendable, Equatable {
    public var value: Double
    public var velocity: Double = 0
    public var target: Double
    public var stiffness: Double
    public var damping: Double

    public init(_ value: Double, stiffness: Double = 170, damping: Double = 14) {
        self.value = value
        self.target = value
        self.stiffness = stiffness
        self.damping = damping
    }

    public mutating func step(_ dt: Double) {
        let acceleration = -stiffness * (value - target) - damping * velocity
        velocity += acceleration * dt
        value += velocity * dt
    }

    public mutating func impulse(_ deltaVelocity: Double) {
        velocity += deltaVelocity
    }
}
