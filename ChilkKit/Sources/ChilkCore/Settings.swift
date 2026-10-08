import Foundation

// Slice 5c (SPEC «Срез 5», decisions 19–20): the main window's Settings and «договор с собой» on everything that
// softens care. Pure values; the app stores them in `settings.json` and feeds `CareSettings` into the engine.

/// One threshold range in minutes of sitting («каждые 40–70 мин»).
public struct MinuteRange: Codable, Equatable, Sendable {
    public var low: Int
    public var high: Int

    public init(_ low: Int, _ high: Int) {
        self.low = low
        self.high = high
    }
}

/// What a care control may be set to.
public struct CareLimits: Equatable, Sendable {
    public var min: Int
    public var max: Int
    public var step: Int
}

/// Care (decision 19): which needs Chilk looks after, how often, and the day's budget.
public struct CareSettings: Codable, Equatable, Sendable {
    /// Switched-off needs: no pressure, no requests.
    public var off: Set<Need> = []
    /// Threshold ranges of the body needs.
    public var ranges: [Need: MinuteRange] = CareSettings.defaultRanges
    public var weekdayHours = 8
    public var weekendHours = 4

    public static let defaultRanges: [Need: MinuteRange] = [
        .water: MinuteRange(40, 70), .stretch: MinuteRange(45, 75), .eyes: MinuteRange(30, 50), .walk: MinuteRange(120, 180),
    ]
    public static let budgetLimits = CareLimits(min: 1, max: 16, step: 1)

    public static func limits(_ n: Need) -> CareLimits {
        switch n {
        case .water: CareLimits(min: 15, max: 120, step: 5)
        case .stretch: CareLimits(min: 20, max: 150, step: 5)
        case .eyes: CareLimits(min: 15, max: 90, step: 5)
        case .walk: CareLimits(min: 60, max: 300, step: 15)
        case .endOfDay: CareLimits(min: 0, max: 0, step: 0)
        }
    }

    public init() {}

    public func isOn(_ n: Need) -> Bool { !off.contains(n) }

    public func range(_ n: Need) -> MinuteRange { ranges[n] ?? Self.defaultRanges[n] ?? MinuteRange(0, 0) }

    /// The engine's numbers. Everything else in `BalanceConfig` stays as it is.
    public func apply(to c: inout BalanceConfig) {
        c.needsOff = off
        func minutes(_ n: Need) -> ClosedRange<Double> {
            let r = range(n)
            return Double(r.low)...Double(max(r.low, r.high))
        }
        c.waterMinutes = minutes(.water)
        c.stretchMinutes = minutes(.stretch)
        c.eyesMinutes = minutes(.eyes)
        c.walkMinutes = minutes(.walk)
        c.weekdayBudget = Double(weekdayHours) * 3600
        c.weekendBudget = Double(weekendHours) * 3600
    }

    private enum CodingKeys: String, CodingKey { case off, ranges, weekdayHours, weekendHours }

    private struct NeedKey: CodingKey {
        let stringValue: String
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    /// Field by field (and range by range): a damaged value loses only itself, never the rest of the care.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        off = Set(((try? c.decodeIfPresent([String].self, forKey: .off)) ?? []).compactMap(Need.init(rawValue:)))
        if let saved = try? c.nestedContainer(keyedBy: NeedKey.self, forKey: .ranges) {
            for n in Need.body {
                guard let r = try? saved.decode(MinuteRange.self, forKey: NeedKey(n.rawValue)) else { continue }
                let l = Self.limits(n)
                let low = min(max(r.low, l.min), l.max)
                ranges[n] = MinuteRange(low, min(max(r.high, low), l.max))
            }
        }
        let b = Self.budgetLimits
        weekdayHours = min(max((try? c.decodeIfPresent(Int.self, forKey: .weekdayHours)) ?? 8, b.min), b.max)
        weekendHours = min(max((try? c.decodeIfPresent(Int.self, forKey: .weekendHours)) ?? 4, b.min), b.max)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(off.map(\.rawValue).sorted(), forKey: .off)
        try c.encode(ranges, forKey: .ranges)
        try c.encode(weekdayHours, forKey: .weekdayHours)
        try c.encode(weekendHours, forKey: .weekendHours)
    }
}

/// One click in «Забота».
public enum CareChange: Equatable, Sendable {
    case need(Need, on: Bool)
    case low(Need, Int)
    case high(Need, Int)
    case budget(weekend: Bool, hours: Int)
}

extension CareSettings {
    /// The settings after `change`, clamped to the limits (raising «от» above «до» lifts «до» too, and back).
    public func applying(_ change: CareChange) -> CareSettings {
        var s = self
        switch change {
        case .need(let n, let on):
            if on { s.off.remove(n) } else { s.off.insert(n) }
        case .low(let n, let value):
            guard Need.body.contains(n) else { return s }
            let l = Self.limits(n)
            var r = range(n)
            r.low = min(max(value, l.min), l.max)
            r.high = max(r.high, r.low)
            s.ranges[n] = r
        case .high(let n, let value):
            guard Need.body.contains(n) else { return s }
            let l = Self.limits(n)
            var r = range(n)
            r.high = min(max(value, l.min), l.max)
            r.low = min(r.low, r.high)
            s.ranges[n] = r
        case .budget(let weekend, let hours):
            let h = min(max(hours, Self.budgetLimits.min), Self.budgetLimits.max)
            if weekend { s.weekendHours = h } else { s.weekdayHours = h }
        }
        return s
    }

    /// «Договор с собой» (decision 20): less care = softer. A need off, any bound up, a bigger budget.
    public func isSofter(_ after: CareSettings) -> Bool {
        if !after.off.subtracting(off).isEmpty { return true }
        for n in Need.body where after.range(n).low > range(n).low || after.range(n).high > range(n).high { return true }
        return after.weekdayHours > weekdayHours || after.weekendHours > weekendHours
    }

    public func softens(_ change: CareChange) -> Bool { isSofter(applying(change)) }
}

// MARK: - App categories (decision 19, SPEC «Сигналы»)

extension AppCategory {
    /// How much care the category leaves: moving an app to a lower one softens (decision 20).
    public var strictness: Int {
        switch self {
        case .work: 2
        case .leisure: 1
        case .call, .untouchable: 0
        }
    }

    public static let choices: [AppCategory] = [.work, .leisure, .call, .untouchable]
}

/// The user's categories on top of the automatic work / leisure, and the apps recently in front (bundle ids only).
public struct AppRules: Codable, Equatable, Sendable {
    public private(set) var overrides: [String: AppCategory] = [:]
    /// Newest first, at most `recentLimit`; no times — only which apps to offer in Settings.
    public private(set) var recent: [String] = []
    public static let recentLimit = 30
    /// Slice 6f-2: apps marked «Музыка» (their sound counts as music for the disco). Not a category: nothing to soften.
    public private(set) var musicMarks: Set<String> = []

    public init() {}

    public func category(of id: String?, automatic: AppCategory) -> AppCategory {
        id.flatMap { overrides[$0] } ?? automatic
    }

    /// The app came to the front. Returns whether the list changed.
    @discardableResult
    public mutating func noteFront(_ id: String) -> Bool {
        guard recent.first != id else { return false }
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        return true
    }

    /// Apps to list in Settings: recent ones, then any other with an override.
    public var listed: [String] {
        recent + overrides.keys.filter { !recent.contains($0) }.sorted()
    }

    /// Softer = less care, and anything into «Созвон» (decision A, 2026-10-06): a call app takes the stage-4 pause down,
    /// «Не трогать» does not, so «Не трогать → Созвон» would be a way out. Out of «Созвон» is tightening: always allowed.
    public static func softens(from old: AppCategory, to new: AppCategory) -> Bool {
        new != old && (new == .call || new.strictness < old.strictness)
    }

    /// `category == nil` = back to automatic.
    public func softens(_ id: String, to category: AppCategory?, automatic: AppCategory) -> Bool {
        Self.softens(from: self.category(of: id, automatic: automatic), to: category ?? automatic)
    }

    public mutating func set(_ id: String, to category: AppCategory?, automatic: AppCategory,
                             locked: Bool) throws(BalanceRefusal) {
        if locked && softens(id, to: category, automatic: automatic) { throw .softeningDuringEscalation }
        overrides[id] = category
    }

    /// Slice 6f-2: mark / unmark an app as music.
    public mutating func setMusic(_ id: String, _ on: Bool) {
        if on { musicMarks.insert(id) } else { musicMarks.remove(id) }
    }

    private enum CodingKeys: String, CodingKey { case overrides, recent, music }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent([String: String].self, forKey: .overrides)) ?? [:]
        overrides = raw.compactMapValues(AppCategory.init(rawValue:))
        recent = Array(((try? c.decodeIfPresent([String].self, forKey: .recent)) ?? []).prefix(Self.recentLimit))
        musicMarks = Set((try? c.decodeIfPresent([String].self, forKey: .music)) ?? [])
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(overrides.mapValues(\.rawValue), forKey: .overrides)
        try c.encode(recent, forKey: .recent)
        try c.encode(musicMarks.sorted(), forKey: .music)
    }
}

// MARK: - Hotkey (decision 19)

/// The call hotkey: a Carbon key code + Carbon modifier mask, and how to show it («⌃⌥Space»).
public struct HotkeySpec: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var label: String

    // Carbon modifier bits (HIToolbox/Events.h).
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000

    public static let standard = HotkeySpec(keyCode: 49, modifiers: control | option, label: "⌃⌥Space")

    public init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    /// From a pressed key: `nil` when it cannot be a global hotkey (no ⌘/⌃/⌥, Esc, a bare modifier).
    public static func recorded(keyCode: UInt32, modifiers: UInt32, characters: String?) -> HotkeySpec? {
        let mods = modifiers & (command | shift | option | control)
        guard mods & (command | option | control) != 0, keyCode != 53,
              let key = keyName(keyCode: keyCode, characters: characters) else { return nil }
        return HotkeySpec(keyCode: keyCode, modifiers: mods, label: glyphs(mods) + key)
    }

    /// ⌃⌥⇧⌘ in the system order.
    public static func glyphs(_ mods: UInt32) -> String {
        (mods & control != 0 ? "⌃" : "") + (mods & option != 0 ? "⌥" : "") + (mods & shift != 0 ? "⇧" : "")
            + (mods & command != 0 ? "⌘" : "")
    }

    private static let named: [UInt32: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12",
    ]
    /// Modifier keys alone (⌘ ⇧ ⇪ ⌥ ⌃, right-hand ones, fn).
    private static let modifierKeys: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    static func keyName(keyCode: UInt32, characters: String?) -> String? {
        if modifierKeys.contains(keyCode) { return nil }
        if let n = named[keyCode] { return n }
        guard let c = characters?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), c.count == 1,
              c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return c
    }
}

// MARK: - Screen (decision 19)

/// Which monitor Chilk lives on: the one with the active window, or a pinned one (back to «active» while it is away).
public enum ScreenChoice: Codable, Equatable, Sendable {
    case follow
    case pinned(id: String, name: String)

    /// Index into `ids` (the connected screens, by display UUID) of the screen to use; `active` = the screen with the
    /// active window.
    public func pick(ids: [String], active: Int) -> Int {
        if case .pinned(let id, _) = self, let i = ids.firstIndex(of: id) { return i }
        return active
    }
}

// MARK: - Brain (slice 9f, decisions 36–38)

/// «Глубина ответа» instead of a temperature (Codex has none): only these three reach the picker — `xhigh` / `max` /
/// `ultra` take tens of seconds per voice answer (decision 36).
public enum AnswerDepth: String, Codable, CaseIterable, Sendable {
    case low, medium, high

    /// The depths of `supported` (a model's `supportedReasoningEfforts`) Chilk offers, in order.
    public static func offered(_ supported: [String]) -> [AnswerDepth] {
        allCases.filter { supported.contains($0.rawValue) }
    }
}

/// The Codex model and depth of a conversation (Settings → «Мозг»). Background turns (phrase batch, warm-ups) take the
/// same model, always at `low` (decision 38). A change counts from the next conversation.
public struct BrainChoice: Codable, Equatable, Sendable {
    public static let defaultModel = "gpt-6-luna"
    public static let defaultModelName = "GPT-6-Luna"
    /// The background depth (decision 38).
    public static let backgroundDepth = AnswerDepth.low

    /// `nil` = never chosen: GPT-6-Luna.
    public var model: String?
    /// The model's `displayName` when it was chosen — to name it while Codex (and so the list) is away.
    public var modelName: String?
    public var depth = AnswerDepth.low

    public init(model: String? = nil, modelName: String? = nil, depth: AnswerDepth = .low) {
        self.model = model
        self.modelName = modelName
        self.depth = depth
    }

    /// The model id sent to Codex.
    public var modelID: String { model ?? Self.defaultModel }
    /// How to name the model to the user.
    public var displayName: String {
        if let modelName, !modelName.isEmpty { return modelName }
        return model ?? Self.defaultModelName
    }

    /// The choice after picking `model` from the list: its depth stays when the model supports it, otherwise the first
    /// of the offered depths (`low` for every model Codex lists today).
    public func choosing(model id: String, name: String, supported: [String]) -> BrainChoice {
        var c = self
        c.model = id
        c.modelName = name
        let offered = AnswerDepth.offered(supported)
        if !offered.isEmpty, !offered.contains(depth) { c.depth = offered[0] }
        return c
    }

    /// Whether the chosen model is still offered: `nil` = the list is unknown (Codex away, or an empty list — the
    /// catalog not loaded yet), so nothing can be said. No silent substitution (decision 37): a missing model is a
    /// problem to show, never a reason to use another.
    public func isAvailable(in listed: [String]?) -> Bool? {
        guard let listed, !listed.isEmpty else { return nil }
        return listed.contains(modelID)
    }

    /// The depth a turn really goes at, given the model's `supportedReasoningEfforts` (`nil` = unknown): the chosen one
    /// when the model has it, otherwise the first offered — `low` for every model Codex lists (9f review). Unknown or
    /// nothing offered: the choice as is (Codex itself is then the check).
    public func effectiveDepth(supported: [String]?) -> AnswerDepth {
        guard let supported else { return depth }
        let offered = AnswerDepth.offered(supported)
        guard let first = offered.first, !offered.contains(depth) else { return depth }
        return first
    }

    private enum CodingKeys: String, CodingKey { case model, modelName, depth }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil
        model = id.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        modelName = (try? c.decodeIfPresent(String.self, forKey: .modelName)) ?? nil
        depth = (try? c.decodeIfPresent(AnswerDepth.self, forKey: .depth)) ?? .low
    }
}

/// When the conversation's threads follow a new «Мозг» choice (slice 9f, decision 36: «со следующего разговора»). A
/// thread keeps the model it started with, so a new model drops the live thread and re-warms the spare; the depth is
/// sent with every turn, so a depth-only change just updates the live thread. Nothing is swapped under a conversation
/// or a chat turn in flight (`busy`): it waits for its end. Pure, so the timing is tested without Codex.
public struct BrainThreadPolicy: Equatable, Sendable {
    /// What the live thread needs.
    public enum Live: Equatable, Sendable {
        case keep
        /// Its next turns go at this depth.
        case setDepth(AnswerDepth)
        /// Another model: it goes, the next conversation starts on a new spare.
        case drop
    }

    public struct Step: Equatable, Sendable {
        public var live: Live
        /// The warm spare was started on the old model: drop it and warm a new one (right away — it is not live).
        public var rewarmSpare: Bool

        public init(live: Live, rewarmSpare: Bool) {
            self.live = live
            self.rewarmSpare = rewarmSpare
        }
    }

    /// A change that waits for the conversation going on to end.
    public private(set) var pending = Live.keep

    public init() {}

    /// The choice went from `old` to `new`; `busy` = a conversation or a chat turn is going on.
    public mutating func choiceChanged(from old: BrainChoice, to new: BrainChoice, busy: Bool) -> Step {
        let modelChanged = old.modelID != new.modelID
        guard modelChanged || old.depth != new.depth else { return Step(live: .keep, rewarmSpare: false) }
        pending = Self.merge(pending, modelChanged ? .drop : .setDepth(new.depth))
        guard !busy else { return Step(live: .keep, rewarmSpare: modelChanged) }
        defer { pending = .keep }
        return Step(live: pending, rewarmSpare: modelChanged)
    }

    /// A conversation or a chat turn ended (`busy`: another one still goes on — wait for it too).
    public mutating func conversationEnded(busy: Bool) -> Live {
        guard !busy else { return .keep }
        defer { pending = .keep }
        return pending
    }

    /// A reconnect: no thread survives it anyway.
    public mutating func reset() { pending = .keep }

    /// A model change wins over any depth; a later depth over an earlier one.
    private static func merge(_ earlier: Live, _ later: Live) -> Live {
        if earlier == .drop || later == .drop { return .drop }
        return later == .keep ? earlier : later
    }
}

// MARK: - All settings (settings.json)

/// Everything of Settings that is not the engine's: care and the mode live in `balance.json` with the engine state.
public struct AppSettings: Codable, Equatable, Sendable {
    public var apps = AppRules()
    public var hotkey = HotkeySpec.standard
    public var screen = ScreenChoice.follow
    /// `nil` = never chosen: on by default (SPEC «Умолчания»).
    public var launchAtLogin: Bool?
    /// Slice 9f: the Codex model and depth.
    public var brain = BrainChoice()

    public init() {}

    private enum CodingKeys: String, CodingKey { case apps, hotkey, screen, launchAtLogin, brain }

    /// Field by field: an older or partly damaged file keeps what it can and defaults the rest.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apps = (try? c.decodeIfPresent(AppRules.self, forKey: .apps)) ?? AppRules()
        hotkey = (try? c.decodeIfPresent(HotkeySpec.self, forKey: .hotkey)) ?? .standard
        screen = (try? c.decodeIfPresent(ScreenChoice.self, forKey: .screen)) ?? .follow
        launchAtLogin = try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)
        brain = (try? c.decodeIfPresent(BrainChoice.self, forKey: .brain)) ?? BrainChoice()
    }

    /// `brain` only once chosen: a file from before slice 9f re-encodes unchanged, so it is not copied aside as lossy.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(apps, forKey: .apps)
        try c.encode(hotkey, forKey: .hotkey)
        try c.encode(screen, forKey: .screen)
        try c.encodeIfPresent(launchAtLogin, forKey: .launchAtLogin)
        if brain != BrainChoice() { try c.encode(brain, forKey: .brain) }
    }
}
