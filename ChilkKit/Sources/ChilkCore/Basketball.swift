import Foundation

// MARK: - Basketball «Попадёт — не попадёт» (slice 7b, SPEC decisions 27–28)

/// The rules of the screen game: the hoop at the other side of the screen, the chance only from the distance, a guess
/// per throw. Screen coordinates here are AppKit's (y up), in points.
public enum Basketball {
    /// At the nearest allowed distance (a third of the screen width) he scores ~85 %, across the whole width ~15 %.
    public static let nearChance = 0.85
    public static let farChance = 0.15

    /// The hoop never comes closer to him than a third of the screen width (decision 27).
    public static func minDistance(screenWidth: Double) -> Double { screenWidth / 3 }

    /// The chance of a basket — from the distance only, linear between a third and the whole screen width.
    public static func chance(distance: Double, screenWidth: Double) -> Double {
        let near = minDistance(screenWidth: screenWidth), far = max(near + 1, screenWidth)
        let u = min(1, max(0, (distance - near) / (far - near)))
        return nearChance * (1 - u) + farChance * u
    }

    public static func scores<R: RandomSource>(chance: Double, rng: inout R) -> Bool { rng.next() < chance }

    /// Where the hoop may stand: its centre inside `frame` (inset by `margin`) and at least `minDistance` from `from`
    /// (the ball in his hands). Too close, it stops at that distance; against a screen side, it slides away from him.
    public static func clampHoop(_ p: CGPoint, from: CGPoint, in frame: CGRect, margin: CGFloat) -> CGPoint {
        let box = frame.insetBy(dx: margin, dy: margin)
        func inside(_ q: CGPoint) -> CGPoint {
            CGPoint(x: min(box.maxX, max(box.minX, q.x)), y: min(box.maxY, max(box.minY, q.y)))
        }
        let near = CGFloat(minDistance(screenWidth: Double(frame.width)))
        var q = inside(p)
        let dx = q.x - from.x, dy = q.y - from.y
        let d = hypot(dx, dy)
        guard d < near else { return q }
        // Away from him, along the line from him; straight into the screen when it sits right on him.
        let into: CGFloat = from.x > frame.midX ? -1 : 1
        let ux = d > 0.5 ? dx / d : into, uy = d > 0.5 ? dy / d : 0
        q = inside(CGPoint(x: from.x + ux * near, y: from.y + uy * near))
        if hypot(q.x - from.x, q.y - from.y) < near - 0.5 {       // pinned against the top or the bottom: slide sideways
            let h = abs(q.y - from.y)
            let w = sqrt(max(0, near * near - h * h))
            q = inside(CGPoint(x: from.x + into * w, y: q.y))
        }
        return q
    }

    /// The default place: across the screen from him, a little higher than his hands.
    public static func defaultHoop(from: CGPoint, in frame: CGRect, margin: CGFloat) -> CGPoint {
        let x = from.x > frame.midX ? frame.minX + margin + 60 : frame.maxX - margin - 60
        return clampHoop(CGPoint(x: x, y: from.y + frame.height * 0.22), from: from, in: frame, margin: margin)
    }
}

/// The user's guess before a throw.
public enum ShotGuess: String, Codable, Sendable { case hit, miss }

/// One throw: the guess, whether it went in, and what follows (decisions 27–28).
public struct ShotRound: Equatable, Sendable {
    public let guess: ShotGuess
    public let scored: Bool

    public init(guess: ShotGuess, scored: Bool) {
        self.guess = guess
        self.scored = scored
    }

    /// Guessed — a point to you, otherwise to Chilk (a throw is never a draw).
    public var result: GameResult { (guess == .hit) == scored ? .you : .chilk }
    /// A small firework when you guessed.
    public var firework: Bool { result == .you }
    /// His own throw: in — «ликует», out — «обиделся».
    public var reaction: GameReaction { scored ? .cheer : .offended }
}

/// The end of a basketball match (decision 28): you won — a big firework and he claps; he won — «ликует»; a draw —
/// «пять!».
public enum CourtFinale: String, Sendable {
    case fireworksAndClap, cheer, highFive

    public init(_ r: GameResult) {
        switch r {
        case .you: self = .fireworksAndClap
        case .chilk: self = .cheer
        case .draw: self = .highFive
        }
    }
}

// MARK: - The flight of the ball

/// The ball from his hands to the hoop along an arc; in: through the rim and down through the net; out: off the front
/// or the back of the rim and down. y up; `point(at:)` for t in 0…`duration`.
public struct ShotFlight: Equatable, Sendable {
    public enum Miss: String, Sendable { case front, back }

    public let from: CGPoint
    /// The rim's centre.
    public let rim: CGPoint
    public let rimRadius: Double
    public let scored: Bool
    public let miss: Miss
    /// When the ball reaches the rim.
    public let contact: Double
    public let duration: Double
    private let apex: Double
    private let target: CGPoint
    private let bounceVX: Double
    private let bounceVY: Double
    private static let gravity = 1500.0

    /// `screenWidth` sets the time in the air (a longer throw flies longer).
    public init(from: CGPoint, rim: CGPoint, rimRadius: Double, scored: Bool, miss: Miss, screenWidth: Double) {
        self.from = from
        self.rim = rim
        self.rimRadius = rimRadius
        self.scored = scored
        self.miss = miss
        let dist = hypot(Double(rim.x - from.x), Double(rim.y - from.y))
        contact = 0.75 + 0.45 * min(1, dist / max(1, screenWidth))
        // He throws towards the hoop; out — it lands on the near (front) or far (back) part of the rim.
        let toward: Double = rim.x >= from.x ? 1 : -1
        let off = scored ? 0 : (miss == .front ? -1.0 : 1.0) * rimRadius * 0.95 * toward
        target = CGPoint(x: Double(rim.x) + off, y: Double(rim.y) + (scored ? 4 : 2))
        apex = max(Double(from.y), Double(rim.y)) + 110 + dist * 0.18
        if scored {
            bounceVX = 0
            bounceVY = -260
            duration = contact + 0.55
        } else {
            // Off the rim: back towards him from the front, on and away from the back; up a little, then down.
            bounceVX = (miss == .front ? -1 : 1) * toward * 170
            bounceVY = 240
            duration = contact + 1.1
        }
    }

    /// The ball's centre at `t` (seconds since it left his hands).
    public func point(at t: Double) -> CGPoint {
        if t <= contact {
            let u = max(0, t) / contact
            let x = Double(from.x) + (Double(target.x) - Double(from.x)) * u
            // A parabola through from, the apex height and the target (a quadratic Bézier in y).
            let c = 2 * apex - (Double(from.y) + Double(target.y)) / 2
            let y = (1 - u) * (1 - u) * Double(from.y) + 2 * (1 - u) * u * c + u * u * Double(target.y)
            return CGPoint(x: x, y: y)
        }
        let s = t - contact
        if scored {                                            // straight down through the net, a little slower at first
            return CGPoint(x: Double(target.x), y: Double(target.y) + bounceVY * s - 0.5 * Self.gravity * 0.6 * s * s)
        }
        return CGPoint(x: Double(target.x) + bounceVX * s,
                       y: Double(target.y) + bounceVY * s - 0.5 * Self.gravity * s * s)
    }

    /// Fades over the last 0.3 s.
    public func alpha(at t: Double) -> Double { min(1, max(0, (duration - t) / 0.3)) }
}

// MARK: - Fireworks

/// Sparks of one or more bursts with gravity and drag; positions are a pure function of time (y up).
public struct Fireworks: Equatable, Sendable {
    public struct Spark: Equatable, Sendable {
        public let origin: CGPoint
        public let vx: Double
        public let vy: Double
        /// When its burst goes off (seconds after the show starts).
        public let start: Double
        public let life: Double
        /// Index into the renderer's palette.
        public let color: Int
    }

    public let sparks: [Spark]
    public var duration: Double { sparks.map { $0.start + $0.life }.max() ?? 0 }
    public static let colors = 5
    private static let gravity = 260.0

    /// A small one over the hoop (you guessed), ~1 s.
    public static func small<R: RandomSource>(at c: CGPoint, rng: inout R) -> Fireworks {
        Fireworks(sparks: burst(at: c, start: 0, count: 18, speed: 150, life: 1.0, rng: &rng))
    }

    /// The big one (you won the match): bursts in turn across the upper part of `frame`, ~2.8 s.
    public static func big<R: RandomSource>(over frame: CGRect, rng: inout R) -> Fireworks {
        var all: [Spark] = []
        for i in 0..<6 {
            let x = Double(frame.minX) + Double(frame.width) * (0.15 + 0.7 * (Double(i) + rng.next() * 0.6) / 6)
            let y = Double(frame.minY) + Double(frame.height) * rng.uniform(0.55, 0.8)
            all += burst(at: CGPoint(x: x, y: y), start: Double(i) * 0.3, count: 28, speed: 230, life: 1.3, rng: &rng)
        }
        return Fireworks(sparks: all)
    }

    private static func burst<R: RandomSource>(at c: CGPoint, start: Double, count: Int, speed: Double, life: Double,
                                               rng: inout R) -> [Spark] {
        let color = Int(rng.next() * Double(colors)) % colors
        return (0..<count).map { i in
            let a = Double(i) / Double(count) * 2 * .pi + rng.uniform(-0.12, 0.12)
            let v = speed * rng.uniform(0.75, 1.1)
            return Spark(origin: c, vx: cos(a) * v, vy: sin(a) * v, start: start, life: life * rng.uniform(0.85, 1.1),
                         color: (color + (i % 3 == 0 ? 1 : 0)) % colors)
        }
    }

    /// Every spark alive at `t`: its point and opacity.
    public func visible(at t: Double) -> [(point: CGPoint, alpha: Double, color: Int)] {
        sparks.compactMap { s in point(s, at: t).map { ($0, alpha(s, at: t), s.color) } }
    }

    /// Where a spark is at `t`; `nil` before its burst and after its life.
    public func point(_ s: Spark, at t: Double) -> CGPoint? {
        let k = t - s.start
        guard k >= 0, k < s.life else { return nil }
        let drag = (1 - exp(-2.2 * k)) / 2.2                     // slows down like a real spark
        return CGPoint(x: Double(s.origin.x) + s.vx * drag, y: Double(s.origin.y) + s.vy * drag - 0.5 * Self.gravity * k * k)
    }

    public func alpha(_ s: Spark, at t: Double) -> Double { min(1, max(0, (s.life - (t - s.start)) / (s.life * 0.45))) }
}
