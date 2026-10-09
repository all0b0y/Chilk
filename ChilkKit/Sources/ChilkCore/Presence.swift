import Foundation

/// Notices when the user steps away from the Mac and when they come back,
/// from the system-wide "seconds since last input" (no permissions needed).
///
/// Slice 10 (SPEC «Срез 10», decisions 15–17): he dozes off only when neither the user's input nor his own deed has
/// happened for `awayAfter` — the three minutes count from the end of what he was doing, not from the last mouse move.
/// While he leads, talks or asks, the user has not «gone»: no «С возвращением» after a warm-up. An answer he waits for
/// without a time limit (a card, a timed message) keeps him awake for `waitAwake`, then he dozes beside it.
public struct PresenceTracker: Sendable {
    public enum Event: Equatable, Sendable {
        case wentAway
        case returned(after: TimeInterval)
        /// His own deed began while the user is still away (a timed message, a dance): he wakes up, no greeting.
        case roused
        /// The deed is over and it has been quiet long enough again: back to sleep (the user is still away).
        case dozedOff
    }

    /// What he is doing right now — the app reads it from whoever holds him.
    public enum Deed: Equatable, Sendable {
        case none
        /// A conversation: the user is talking to him — that is being here, like input.
        case talking
        /// He leads something (an exercise, a game, a dance) or a question of his waits for an answer.
        case busy
        /// An answer he waits for without a time limit (a confirmation card, a timed message).
        case waiting
    }

    /// No keyboard/mouse for this long → away (he dozes off).
    public var awayAfter: TimeInterval
    /// Input within this many seconds → back.
    public var backWithin: TimeInterval
    /// Slice 10 (decision 17): a wait without a time limit keeps him awake this long without input, voice or a deed.
    public var waitAwake: TimeInterval
    public private(set) var isAway = false
    /// Asleep as far as presence goes (away and nothing of his own woke him meanwhile).
    public private(set) var isDozing = false
    private var awaySince: Date?
    /// The last moment a deed of his (talking, busy) was seen.
    private var lastDeed: Date?
    /// When the current wait without a time limit began (nil — none).
    private var waitingSince: Date?

    public init(awayAfter: TimeInterval = 180, backWithin: TimeInterval = 2, waitAwake: TimeInterval = 600) {
        self.awayAfter = awayAfter
        self.backWithin = backWithin
        self.waitAwake = waitAwake
    }

    public mutating func update(idleSeconds: TimeInterval, now: Date, deed: Deed = .none) -> Event? {
        if deed == .waiting {
            if waitingSince == nil { waitingSince = now }
        } else {
            waitingSince = nil
        }
        if deed == .talking || deed == .busy { lastDeed = now }
        let sinceDeed = lastDeed.map { max(0, now.timeIntervalSince($0)) } ?? .infinity
        // Quiet = neither the user's input nor his deed: the three minutes count from the later of the two.
        let quietSinceUser = min(idleSeconds, sinceDeed)
        var quiet = quietSinceUser
        var limit = awayAfter
        if let since = waitingSince {
            quiet = min(quiet, max(0, now.timeIntervalSince(since)))
            limit = max(awayAfter, waitAwake)
        }
        let sleepy = quiet >= limit

        guard isAway else {
            guard sleepy else { return nil }
            isAway = true
            isDozing = true
            awaySince = now.addingTimeInterval(-quietSinceUser)   // the absence started at the last input or deed
            return .wentAway
        }
        if idleSeconds < backWithin || deed == .talking {
            isAway = false
            isDozing = false
            let since = awaySince ?? now
            awaySince = nil
            return .returned(after: now.timeIntervalSince(since))
        }
        if isDozing, !sleepy {
            isDozing = false
            return .roused
        }
        if !isDozing, sleepy {
            isDozing = true
            return .dozedOff
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
