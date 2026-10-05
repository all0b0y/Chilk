/// What the passive ears do after a failure (decision 2026-10-05). Before, one failure left Chilk deaf until the
/// user turned the ears off and on, and from the outside it looked like «он не слышит имя». Now: quiet restarts
/// after 2, 10 and 60 s; the 4th failure in a row gives up and tells the user. A microphone that ran for
/// `healthyAfter` seconds since its last start makes a fresh incident. Denied access is the app's case (no retries).
public struct EarsRecovery: Sendable, Equatable {
    public enum Step: Sendable, Equatable { case retry(after: Double), giveUp }

    public static let delays: [Double] = [2, 10, 60]
    public static let healthyAfter: Double = 30

    public private(set) var attempts = 0
    private var runningSince: Double?

    public init() {}

    /// The microphone really started at `time` (seconds, any monotonic clock).
    public mutating func started(at time: Double) { runningSince = time }

    public mutating func failed(at time: Double) -> Step {
        if let since = runningSince, time - since >= Self.healthyAfter { attempts = 0 }
        runningSince = nil
        guard attempts < Self.delays.count else { return .giveUp }
        defer { attempts += 1 }
        return .retry(after: Self.delays[attempts])
    }

    /// The user turned the ears off or on: start over.
    public mutating func reset() {
        attempts = 0
        runningSince = nil
    }
}
