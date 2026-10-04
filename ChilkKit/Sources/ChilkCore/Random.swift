/// Source of uniform random numbers in `[0, 1)`. Injected so the character's
/// "по настроению" behaviour is reproducible in tests.
public protocol RandomSource {
    mutating func next() -> Double
}

extension RandomSource {
    public mutating func uniform(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * next()
    }

    public mutating func index(_ count: Int) -> Int {
        min(count - 1, Int(next() * Double(count)))
    }
}

public struct SystemRandom: RandomSource {
    public init() {}
    public mutating func next() -> Double { Double.random(in: 0..<1) }
}

/// SplitMix64 — tiny, deterministic, good enough for animation timing.
public struct SeededRandom: RandomSource {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
