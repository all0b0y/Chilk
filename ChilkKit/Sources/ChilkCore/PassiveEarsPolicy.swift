/// Permission to reopen the passive microphone is separate from model readiness and dictation state.
/// Finishing model loading must not unpause a conversation; finishing a conversation must not retry a
/// failed audio device behind the user's back. Only an explicit ears-off/ears-on retries a failure.
public struct PassiveEarsPolicy: Sendable {
    private var paused = false
    private var failed = false
    public var allowed: Bool { !paused && !failed }

    public init() {}
    public mutating func pause() { paused = true }
    public mutating func conversationEnded() { paused = false }
    public mutating func fail() { failed = true }
    public mutating func retry() { failed = false }
}
