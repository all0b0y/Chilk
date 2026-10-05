import Foundation

/// First meeting (SPEC «Срез 5», decisions 22–23): Chilk introduces himself in bubbles while the name is unknown,
/// then asks for it with a field in the last bubble. Lines wait while the user is away (the timer-notice rule) and
/// each goes after its reading time once the user is back; a click on Chilk moves on. The question stays.
public struct GreetingFlow: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case none, say(Int), ask }

    /// Same reading speed as answers (`Dialogue`).
    public static let charactersPerSecond = 14.0

    public static func dwell(characters: Int) -> TimeInterval {
        max(NoticeDisplay.seenAfterInput, Double(characters) / charactersPerSecond)
    }

    /// Characters of each line; the last one is the question.
    private let lengths: [Int]
    private var next = 0
    private var display = NoticeDisplay()
    public private(set) var isAsking = false

    public init(lengths: [Int]) {
        precondition(!lengths.isEmpty, "the greeting needs at least the question")
        self.lengths = lengths
    }

    /// The line on screen now (`nil` while waiting or asking).
    public var current: Int? { display.showing.flatMap { Int($0) } }

    public mutating func step(now: TimeInterval, idle: TimeInterval, locked: Bool, canPresent: Bool) -> Action {
        guard !isAsking else { return .none }
        guard display.showing != nil else {
            guard canPresent, !locked, next < lengths.count else { return .none }
            if next == lengths.count - 1 {
                isAsking = true
                return .ask
            }
            display.seenAfter = Self.dwell(characters: lengths[next])
            _ = display.step(now: now, idle: idle, locked: locked, canPresent: true, next: String(next))
            return .say(next)
        }
        guard case .dismiss = display.step(now: now, idle: idle, locked: locked, canPresent: canPresent, next: nil) else {
            return .none
        }
        next += 1
        return step(now: now, idle: idle, locked: locked, canPresent: canPresent)
    }

    /// A click on Chilk: this line is read, the next one comes on the next step.
    public mutating func clicked() {
        guard display.showing != nil else { return }
        _ = display.clicked()
        next += 1
    }

    /// A conversation took the stage: the same line (or the question) comes back afterwards.
    public mutating func interrupted() {
        display.interrupted()
        isAsking = false
    }
}

/// Who the user is, as far as Chilk knows: only the name they gave him (sent to Codex for addressing them).
public struct UserProfile: Codable, Equatable, Sendable {
    public static let maxNameLength = 40

    public var name: String?
    /// «Позже» in the greeting: never asked again, the name can be set in Settings.
    public var greetingDone = false

    public init() {}

    public var needsGreeting: Bool { name == nil && !greetingDone }

    /// Trimmed, single-spaced, at most 40 characters; nothing that could break out of the `[контекст: …]` line.
    public static func cleanName(_ raw: String) -> String? {
        let name = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !name.isEmpty, name.count <= maxNameLength,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !name.contains(where: { "[]{}<>".contains($0) }) else { return nil }
        return name
    }

    private enum CodingKeys: String, CodingKey { case name, greetingDone }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try c.decodeIfPresent(String.self, forKey: .name)).flatMap(Self.cleanName)
        greetingDone = try c.decodeIfPresent(Bool.self, forKey: .greetingDone) ?? false
    }
}
