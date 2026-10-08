import Foundation

/// Slice 6f-1 (SPEC 22): has the built-in display's brightness settled at a new place? A shift of at least one key step
/// (~6 %) from the last place, then 1.5 s without change; any source (keys, auto-brightness, Control Centre).
public struct BrightnessWatch: Equatable, Sendable {
    public static let step = 0.06
    public static let still = 1.5
    public static let jitter = 0.003

    /// The last place (nil before the first reading — which is only the place, no roll).
    public private(set) var place: Double?
    private var last: Double?
    private var stillSince = 0.0

    public init() {}

    /// Feed a reading (0…1) at `now` seconds; returns the new place once it has settled, else nil.
    public mutating func feed(_ level: Double, now: Double) -> Double? {
        guard let p = place else { place = level; last = level; stillSince = now; return nil }
        if let l = last, abs(level - l) > Self.jitter { stillSince = now }
        last = level
        guard now - stillSince >= Self.still - 1e-9, abs(level - p) >= Self.step - 1e-9 else { return nil }
        place = level
        return level
    }
}

/// Slice 6f-1 (SPEC 22–23): what he puts on for the light around him. One at a time.
public enum Ambience: String, Codable, Sendable, CaseIterable {
    /// Dark: puts on the nightcap, yawns, falls asleep (a click, a call, his own request or brightness > 50 % wake him).
    case nightcap
    /// Dark: a little lamp with a warm circle of light, while brightness < 50 %.
    case lamp
    /// Bright: sunglasses, while brightness > 50 % and the eyes need is under 50 % (the bags matter more).
    case sunglasses

    /// The chance of a look when the brightness settles (slice 9, decision 6; was: 0.1 % · 100^d towards the ends, at
    /// most 10 % — read as «it never works»): very dark (≤ 20 %) or very bright (≥ 85 %) — always; nothing around the
    /// middle (40–60 %); a quarter in between.
    public static func chance(level: Double) -> Double {
        if level <= 0.20 + 1e-9 || level >= 0.85 - 1e-9 { return 1 }
        if level > 0.40 + 1e-9 && level < 0.60 - 1e-9 { return 0 }
        return 0.25
    }

    /// `roll`, `coin` in [0, 1): the look for this settled brightness, or nil.
    public static func pick(level: Double, roll: Double, coin: Double, eyesPressure: Double) -> Ambience? {
        guard roll < chance(level: level) else { return nil }
        if level < 0.5 { return coin < 0.5 ? .nightcap : .lamp }
        return eyesPressure >= 0.5 ? nil : .sunglasses
    }

    /// Whether the look stays at this brightness.
    public func keeps(level: Double, eyesPressure: Double) -> Bool {
        switch self {
        case .nightcap, .lamp: level < 0.5
        case .sunglasses: level > 0.5 && eyesPressure < 0.5
        }
    }
}

/// Slice 9, decision 6: a light scene at most once in 10 minutes (wall clock), so playing with the brightness does
/// not dress him up every second. Only a scene that was put on starts the pause; a missed roll does not.
public struct AmbienceCooldown: Equatable, Sendable {
    public static let pause: TimeInterval = 600
    private var last: TimeInterval?

    public init() {}

    public func ready(now: TimeInterval) -> Bool {
        guard let last else { return true }
        return now - last >= Self.pause - 1e-9
    }

    public mutating func played(now: TimeInterval) { last = now }
}
