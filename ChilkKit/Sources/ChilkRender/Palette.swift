import CoreGraphics

/// sRGB colour stored as plain numbers (Sendable), turned into `CGColor` at draw time.
public struct RGBA: Sendable, Equatable {
    public var r, g, b, a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public static func hex(_ v: UInt32, alpha: Double = 1) -> RGBA {
        RGBA(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255, alpha)
    }

    public static func rgb255(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> RGBA {
        RGBA(r / 255, g / 255, b / 255, a)
    }

    public func mixed(with other: RGBA, _ t: Double) -> RGBA {
        RGBA(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t, a + (other.a - a) * t)
    }

    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    public static let white = RGBA(1, 1, 1)
}

/// Approved look (В31/В32): sticker with a dark outline, peach body, green sprout.
public struct Palette: Sendable, Equatable {
    public var body: RGBA
    public var blush: RGBA
    public var leaf: RGBA
    public var leafTired: RGBA
    public var outline: RGBA
    public var iconTop: RGBA
    public var iconBottom: RGBA

    public static let peach = Palette(
        body: .hex(0xFFB49A),
        blush: .rgb255(255, 86, 110, 0.42),
        leaf: .hex(0x8FD86A),
        leafTired: .hex(0xE4C47C),
        outline: .hex(0x2B2938),
        iconTop: .hex(0xEAF5FF),
        iconBottom: .hex(0xCFE4FA)
    )
}
