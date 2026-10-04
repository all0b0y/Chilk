import Foundation

/// When a due timer bubble appears and when it counts as seen (SPEC «Режиссёр вмешательств», 2026-10-04).
/// It stays while the user is away; the first mouse/keyboard input after it is on screen starts a 4.4 s
/// countdown, then it goes and the timer is acknowledged. Input on the lock screen does not count.
/// Times are monotonic seconds; `idle` = seconds since the last input.
public struct NoticeDisplay: Equatable, Sendable {
    public static let seenAfterInput: TimeInterval = 4.4
    public enum Action: Equatable, Sendable { case none, show(String), dismiss(String) }

    public private(set) var showing: String?
    /// Input at or before this moment does not count: the bubble was not on screen yet, or the screen was locked.
    private var notBefore: TimeInterval = 0
    private var seenFrom: TimeInterval?

    public init() {}

    public mutating func step(now: TimeInterval, idle: TimeInterval, locked: Bool, canPresent: Bool,
                              next: String?) -> Action {
        guard let id = showing else {
            guard canPresent, !locked, let next else { return .none }
            showing = next
            notBefore = now
            seenFrom = nil
            return .show(next)
        }
        if locked {
            notBefore = now
            seenFrom = nil
            return .none
        }
        let lastInput = now - idle
        if seenFrom == nil, lastInput > notBefore { seenFrom = lastInput }
        if let seenFrom, now - seenFrom >= Self.seenAfterInput {
            showing = nil
            self.seenFrom = nil
            return .dismiss(id)
        }
        return .none
    }

    /// A click on Chilk while the bubble is up: seen, closed at once.
    public mutating func clicked() -> Action {
        guard let id = showing else { return .none }
        showing = nil
        seenFrom = nil
        return .dismiss(id)
    }

    /// A conversation took the stage first: not acknowledged, shown again when the stage is free.
    public mutating func interrupted() {
        showing = nil
        seenFrom = nil
    }
}
