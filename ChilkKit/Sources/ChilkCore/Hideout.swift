import Foundation

/// Slice 6d (decisions 17–19): Chilk hidden behind the screen edge. Kept in the state folder (`hideout.json`).
public struct Hideout: Codable, Equatable, Sendable {
    /// He lives behind the edge: «home» is out of sight.
    public var hidden: Bool
    /// Seconds of work left until he peeks out (decision 18).
    public var peekIn: Double

    /// A peek every 20–40 minutes of work.
    public static let peekEvery: ClosedRange<Double> = 1200...2400
    /// The chance he stays out when a request starts or climbs, by stage (decision 19); «лежит» counts as 4.
    public static let stayChances = [0.05, 0.25, 0.5, 0.8, 0.99]

    public init(hidden: Bool = false, peekIn: Double = 1800) {
        self.hidden = hidden
        self.peekIn = peekIn
    }

    public mutating func hide(rng: inout some RandomSource) {
        hidden = true
        peekIn = rng.uniform(Self.peekEvery.lowerBound, Self.peekEvery.upperBound)
    }

    public mutating func show() { hidden = false }

    /// `seconds` of signals: the clock runs only while the user works; a due peek waits out a call, full screen or a
    /// video (`quiet`). `true` = peek now (the next one is already scheduled).
    public mutating func tick(seconds: Double, working: Bool, quiet: Bool, rng: inout some RandomSource) -> Bool {
        guard hidden, working else { return false }
        peekIn = max(0, peekIn - seconds)
        guard peekIn <= 0, !quiet else { return false }
        peekIn = rng.uniform(Self.peekEvery.lowerBound, Self.peekEvery.upperBound)
        return true
    }

    /// Chilk was busy when the peek came due: try again after `seconds` of work.
    public mutating func postpone(_ seconds: Double) { peekIn = seconds }

    public static func chance(stage: Int) -> Double { stayChances[min(max(stage, 0), stayChances.count - 1)] }

    /// `roll` in [0, 1): he stays out (comes out for good) when it falls under the stage's chance.
    public static func stays(stage: Int, roll: Double) -> Bool { roll < chance(stage: stage) }
}

extension Hideout {
    private enum CodingKeys: String, CodingKey { case hidden, peekIn }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        hidden = (try? c.decodeIfPresent(Bool.self, forKey: .hidden)) ?? false
        if let p = try? c.decodeIfPresent(Double.self, forKey: .peekIn), p.isFinite, p >= 0 { peekIn = p }
    }
}
