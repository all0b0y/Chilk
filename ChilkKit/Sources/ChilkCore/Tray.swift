import Foundation

// Slice 5a (SPEC «Срез 5 — трей, чат, главное окно»): what the menu-bar icon and the popover show.

/// The sprout on the tray icon, the same mirror as the sprout on his head (decision 3).
public enum TrayLeaf: Int, CaseIterable, Sendable {
    case fresh, drooping, wilted
}

public struct TrayIconState: Hashable, Sendable {
    public var leaf: TrayLeaf
    /// A request insists (stage 2+) or a due timer waits to be seen (decision 4).
    public var dot: Bool

    public init(leaf: TrayLeaf, dot: Bool) {
        self.leaf = leaf
        self.dot = dot
    }
}

public enum TrayIcon {
    /// `leafFatigue` is `BalanceEngine.leafFatigue` (0 fresh … 1 wilted). Wilted ≈ a need is due; the image is swapped
    /// only when this state changes, never animated continuously (the live Dock icon cost CPU — 2026-10-04).
    public static func state(leafFatigue: Double, shownStage: Int?, noticeWaiting: Bool) -> TrayIconState {
        let leaf: TrayLeaf = leafFatigue < 0.35 ? .fresh : (leafFatigue < 0.75 ? .drooping : .wilted)
        return TrayIconState(leaf: leaf, dot: noticeWaiting || (shownStage ?? 0) >= 2)
    }
}

/// One stat bar of the hero card: the user's need seen as Chilk's stat (decision 6).
public struct HeroStat: Equatable, Sendable {
    public enum Tone: Sendable { case fresh, tired, wilted }
    public var need: Need
    /// 1 = just rested, 0 = due (or the day's budget is spent).
    public var fill: Double
    public var tone: Tone
    /// Switched off in Settings (slice 5c): shown as «выкл».
    public var off = false
}

/// The RPG hero card in the popover: stats = needs, potions = emergency exits, difficulty = mode. No levelling.
public struct HeroCard: Equatable, Sendable {
    /// Вода, Бодрость, Глаза, Прогулка, Запас дня.
    public static let order: [Need] = [.water, .stretch, .eyes, .walk, .endOfDay]

    public var stats: [HeroStat]
    public var potions: Int
    public var potionsMax: Int
    public var mode: BalanceMode

    public static func make(pressure: (Need) -> Double, exitsLeft: Int, exitsMax: Int, mode: BalanceMode,
                            off: Set<Need> = []) -> HeroCard {
        let stats = order.map { n -> HeroStat in
            let fill = min(1, max(0, 1 - pressure(n)))
            let tone: HeroStat.Tone = fill >= 0.5 ? .fresh : (fill > 0 ? .tired : .wilted)
            return HeroStat(need: n, fill: fill, tone: tone, off: off.contains(n))
        }
        return HeroCard(stats: stats, potions: max(0, min(exitsLeft, exitsMax)), potionsMax: exitsMax, mode: mode)
    }
}

/// What Chilk can do and the user can switch off in the tray → Tools (decision 9). The ears have their own switch.
public enum ChilkAbility: String, CaseIterable, Codable, Sendable {
    case webSearch, timers, reminders, files, obsidian, phrases
    /// Slice 8d: timers in Apple's Clock app (`timers` = Chilk's own scheduled messages).
    case clock
    /// Slice 8e: events in Chilk's own «Чилк» calendar (Apple Calendar).
    case calendar
    /// Slice 8f: notes in Chilk's own «Чилк» folder (Apple Notes).
    case notes
}

/// Everything is on until the user switches it off. Unknown or missing entries in an older file mean «on».
public struct ToolSwitches: Codable, Equatable, Sendable {
    public private(set) var off: Set<ChilkAbility> = []

    public init() {}

    public func isOn(_ a: ChilkAbility) -> Bool { !off.contains(a) }

    public mutating func set(_ a: ChilkAbility, on: Bool) {
        if on { off.remove(a) } else { off.insert(a) }
    }

    private enum CodingKeys: String, CodingKey { case off, version }
    /// 2 = slice 8d: Clock timers have their own switch.
    private static let version = 2

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String].self, forKey: .off) ?? []
        off = Set(raw.compactMap(ChilkAbility.init(rawValue:)))
        // Before 8d one switch «Таймеры и „скажи в 17:00“» governed timers too: switched off, it keeps them off.
        if (try c.decodeIfPresent(Int.self, forKey: .version) ?? 1) < 2, off.contains(.timers) { off.insert(.clock) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(off.map(\.rawValue).sorted(), forKey: .off)
        try c.encode(Self.version, forKey: .version)
    }
}
