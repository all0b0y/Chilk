import Foundation

/// Slice 9d (SPEC «Срез 9», decisions 30–31): Chilk and the macOS desktops (Spaces).
///
/// His window belongs to one desktop, so a swipe takes him away with the old one (no blink). The app reports what it
/// sees ten times a second — whether his window and his home desktop are on the active desktop, whether he is on an
/// errand, whether a shared overlay holds him on every desktop — and does what the keeper answers.
/// - «Ходит за тобой» (default): on another desktop he arrives from behind the edge.
/// - «Жить на одном столе»: he stays on his home desktop; an errand brings him to the active one, and once it is over
///   he dives behind the edge and goes home.
public struct DeskKeeper: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case follow, oneDesk }

    public enum Command: Equatable, Sendable {
        case stay
        /// On every desktop, as before slice 9: stages 3–4, a guided break, the shade, the eye-gymnastics flight.
        case allDesks
        /// Back to one desktop — the active one, where he is now.
        case oneDeskAgain
        /// Come to the active desktop already behind the edge, then peek out.
        case arrive
        /// The errand is over: dive behind the edge (then `sendHome`).
        case leave
        /// A business came up while he was diving: come back out here.
        case stopLeaving
        /// Move to the home desktop (unseen: he is behind the edge, or not on the active desktop).
        case sendHome
    }

    /// What the app sees right now.
    public struct Situation: Equatable, Sendable {
        public var mode: Mode
        /// His window is on the active desktop.
        public var onActive: Bool
        /// One desk: the home desktop is the active one.
        public var homeActive: Bool
        /// He has something for the user (see `onErrand`).
        public var errand: Bool
        /// A shared overlay holds him on every desktop.
        public var everywhere: Bool
        /// He may change desktops now (not dragged, not in a leap or a flight).
        public var canMove: Bool
        /// Seconds (any monotonic clock).
        public var now: Double

        public init(mode: Mode, onActive: Bool, homeActive: Bool = true, errand: Bool = false, everywhere: Bool = false,
                    canMove: Bool = true, now: Double) {
            self.mode = mode
            self.onActive = onActive
            self.homeActive = homeActive
            self.errand = errand
            self.everywhere = everywhere
            self.canMove = canMove
            self.now = now
        }
    }

    /// Free this long on a visited desktop before he goes home (the next errand often follows at once: a conversation
    /// ends and the waiting request shows).
    public static let linger = 1.5
    /// The dive behind the edge before the move home.
    public static let dive = 0.45

    /// On every desktop now (the old way).
    public private(set) var everywhere = false
    /// One desk: he is on another desktop on an errand.
    public private(set) var visiting = false
    private var freeSince: Double?
    private var leavingSince: Double?

    public init() {}

    /// He is diving behind the edge on his way home.
    public var isLeaving: Bool { leavingSince != nil }

    /// The watchdog (fix of review 9d): his display link may stop while his window sits on a desktop nobody sees, so the
    /// app also steps the keeper from a timer this often — while he is not on the active desktop, or one desk is on
    /// (home is elsewhere) — and re-reads the desktops this long after a switch (the system's answer may still be stale
    /// when the notification arrives).
    public static let watchdogInterval = 1.0 / 3
    public static let rereadsAfterSwitch = [0.15, 0.4, 0.8]
    public static func needsWatchdog(onActive: Bool, oneDesk: Bool) -> Bool { !onActive || oneDesk }

    /// The one place that says «he has business with the user» — something that waits for the user (review 9d: a short
    /// line, a «спасибо», a clock line or `cheer()` is not worth a trip to another desktop or monitor):
    /// - a bubble that waits: with buttons, or with no end (a request, a due timer or reminder — it stays until seen);
    /// - a request's pantomime (the ladder's hint, the intro before its bubble);
    /// - he has stepped out for it: a conversation, a card, a call (`.out`), stage 3–4 (`.center`).
    /// A `.peek` alone (a thank-you, a cheer, a notice line) is not; the popover and the notebook take him behind the
    /// edge (`.away`) — not an errand at the edge.
    public static func onErrand(standOut: StandOut, bubbleWaits: Bool, act: Act? = nil) -> Bool {
        if bubbleWaits { return true }
        switch act {
        case .drink, .stretches, .lookAway, .wave, .pack, .hops: return true
        default: break
        }
        switch standOut {
        case .out, .center: return true
        case .docked, .peek, .away, .lurk: return false
        }
    }

    public mutating func step(_ s: Situation) -> Command {
        if s.everywhere {
            freeSince = nil
            leavingSince = nil
            guard !everywhere else { return .stay }
            everywhere = true
            return .allDesks
        }
        if everywhere {
            // The overlay is gone: he stays on the desktop the user is on, and (one desk) goes home from there later.
            everywhere = false
            visiting = s.mode == .oneDesk && !s.homeActive
            return .oneDeskAgain
        }
        switch s.mode {
        case .follow:
            visiting = false
            freeSince = nil
            if leavingSince != nil {
                leavingSince = nil
                return .stopLeaving
            }
            return s.onActive || !s.canMove ? .stay : .arrive
        case .oneDesk:
            return s.onActive ? onActiveDesk(s) : elsewhere(s)
        }
    }

    /// One desk, his window is on the active desktop.
    private mutating func onActiveDesk(_ s: Situation) -> Command {
        if s.homeActive {
            visiting = false
            freeSince = nil
            if leavingSince != nil {
                leavingSince = nil
                return .stopLeaving
            }
            return .stay
        }
        visiting = true
        if s.errand || !s.canMove {
            // Busy here, or held (dragged, in a leap, the popover): the way home waits, and the dive starts over after it
            // (otherwise the popover gives him back at the edge and the move home would snatch him from view).
            freeSince = nil
            if leavingSince != nil {
                leavingSince = nil
                return .stopLeaving
            }
            return .stay
        }
        if let since = leavingSince {
            guard s.now - since >= Self.dive - 1e-9 else { return .stay }
            leavingSince = nil
            visiting = false
            return .sendHome
        }
        let since = freeSince ?? s.now
        freeSince = since
        guard s.now - since >= Self.linger - 1e-9 else { return .stay }
        freeSince = nil
        leavingSince = s.now
        return .leave
    }

    /// One desk, his window is not on the active desktop.
    private mutating func elsewhere(_ s: Situation) -> Command {
        freeSince = nil
        let wasLeaving = leavingSince != nil
        leavingSince = nil
        guard s.canMove else {
            if wasLeaving { leavingSince = s.now }            // try again once he may move
            return .stay
        }
        if s.errand || s.homeActive {
            // An errand follows the user; and at home he is always there (peeks out if he was left elsewhere).
            visiting = !s.homeActive
            return .arrive
        }
        if visiting || wasLeaving {
            // The user left the visited desktop: home unseen.
            visiting = false
            return .sendHome
        }
        return .stay
    }
}
