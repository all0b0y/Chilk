import Foundation

/// Notices when the user steps away from the Mac and when they come back,
/// from the system-wide "seconds since last input" (no permissions needed).
public struct PresenceTracker: Sendable {
    public enum Event: Equatable, Sendable {
        case wentAway
        case returned(after: TimeInterval)
    }

    /// No keyboard/mouse for this long → away (he dozes off).
    public var awayAfter: TimeInterval
    /// Input within this many seconds → back.
    public var backWithin: TimeInterval
    public private(set) var isAway = false
    private var awaySince: Date?

    public init(awayAfter: TimeInterval = 180, backWithin: TimeInterval = 2) {
        self.awayAfter = awayAfter
        self.backWithin = backWithin
    }

    public mutating func update(idleSeconds: TimeInterval, now: Date) -> Event? {
        if !isAway, idleSeconds >= awayAfter {
            isAway = true
            awaySince = now.addingTimeInterval(-idleSeconds)   // the absence started at the last input
            return .wentAway
        }
        if isAway, idleSeconds < backWithin {
            isAway = false
            let since = awaySince ?? now
            awaySince = nil
            return .returned(after: now.timeIntervalSince(since))
        }
        return nil
    }
}

/// What he says when the user comes back.
public enum Greeting: Equatable, Sendable {
    case goodMorning, welcomeBack

    /// `nil` for short absences — he just wakes up quietly.
    public static func after(absence: TimeInterval, hour: Int) -> Greeting? {
        if absence >= 3 * 3600, (5..<12).contains(hour) { return .goodMorning }
        if absence >= 10 * 60 { return .welcomeBack }
        return nil
    }
}
