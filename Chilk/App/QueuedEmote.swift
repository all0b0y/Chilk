import ChilkCore

/// A Codex emotion that waits for the answer's words (slice 6c, revised at acceptance 2026-10-06).
struct QueuedEmote {
    let emotion: Emotion
    let strong: Bool
    /// The scene's length: the words' bubble stays at least this long after it starts.
    let seconds: Double
}
