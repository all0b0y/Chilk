import Foundation

/// Bounded in-memory audio only. Check the first phrase after a pause; keep everything spoken while the
/// recognizer runs so Apple dictation can replay it, then join the live microphone without a gap.
///
/// `continuous` (bench 3c, chosen 2026-10-05): speech that arrives while a check is running is checked next,
/// overlapping the previous clip by the pre-roll, instead of waiting for a ≥ pause silence. Without it a TV
/// that never pauses leaves only the first phrase checked.
/// A wake's request is never replayed from the clip start, which may be someone else's speech before the name
/// (`replayAfterClip()`).
///
/// Slice 8b:
/// - `lastClipSpeechShare` (decision 2): how much of the 10 s before the checked clip was voice. A call is «amid
///   speech» only above half — a few words before «Чилк» or a first failed call are not a TV.
/// - `early` (decision 17): a fresh phrase is checked once early — at its first short pause or after 1.5 s of it,
///   whichever comes first. Rejected, the phrase goes on being collected and is checked whole, as before.
public struct WakeAudioGate: Sendable {
    private enum Phase: Sendable { case armed, collecting, checking, waitingForSilence }
    private var phase: Phase = .armed
    private let rate: Int, preRollSamples: Int, pauseSamples: Int, maxPhraseSamples: Int
    public let continuous: Bool
    public let early: Bool
    private let earlyPauseSamples: Int, earlyAfterSamples: Int, earlyMinSpeechSamples: Int
    private var ring: [Float]
    private var written = 0
    private var start = 0, onset = 0, silence = 0
    private var clipEnd = 0
    private var speechSinceClip = false
    private var continuing = false
    private var speechInPhrase = 0
    private var earlyDone = false
    /// Voice flags, one per `append` call, with the sample count at its end (the last 16 s).
    private var flags: [(end: Int, count: Int, speech: Bool)] = []
    private var flagsHead = 0
    /// The last clip continued speech without a pause (background, or the user talking straight on).
    public private(set) var lastClipContinuedSpeech = false
    /// Share of the 10 s before the last clip in which a voice was heard (0…1).
    public private(set) var lastClipSpeechShare = 0.0
    /// The last clip was this phrase's early check.
    public private(set) var lastClipWasEarly = false

    public init(sampleRate: Int = 16_000, preRoll: Double = 0.7, pause: Double = 0.6,
                maxPhrase: Double = 5, capacity: Double = 12, continuous: Bool = false, early: Bool = false,
                earlyPause: Double = 0.2, earlyAfter: Double = 1.5, earlyMinSpeech: Double = 0.3) {
        precondition(sampleRate > 0 && capacity > preRoll + maxPhrase)
        rate = sampleRate
        preRollSamples = Int(preRoll * Double(sampleRate))
        pauseSamples = Int(pause * Double(sampleRate))
        maxPhraseSamples = Int(maxPhrase * Double(sampleRate))
        ring = Array(repeating: 0, count: Int(capacity * Double(sampleRate)))
        self.continuous = continuous
        self.early = early
        earlyPauseSamples = Int(earlyPause * Double(sampleRate))
        earlyAfterSamples = Int(earlyAfter * Double(sampleRate))
        earlyMinSpeechSamples = Int(earlyMinSpeech * Double(sampleRate))
    }

    public var isChecking: Bool { phase == .checking }
    public var bufferedSampleCount: Int { min(written, ring.count) }

    /// Feed fixed VAD frames, in chronological order. A non-nil return requests ONE recognition.
    public mutating func append(_ samples: [Float], speech: Bool) -> [Float]? {
        let before = written
        for sample in samples { ring[written % ring.count] = sample; written += 1 }
        remember(samples.count, speech: speech)
        silence = speech ? 0 : silence + samples.count
        switch phase {
        case .checking:
            if speech { speechSinceClip = true; speechInPhrase += samples.count }
            return nil
        case .waitingForSilence:
            if silence >= pauseSamples { phase = .armed }
            return nil
        case .armed:
            guard speech else { return nil }
            start = max(0, before - preRollSamples)
            onset = before
            continuing = false
            speechInPhrase = 0
            earlyDone = false
            phase = .collecting
        case .collecting: break
        }
        if speech { speechInPhrase += samples.count }
        if silence >= pauseSamples || written - onset >= maxPhraseSamples {
            return emit(early: false)
        }
        if early, !continuing, !earlyDone, speechInPhrase >= earlyMinSpeechSamples,
           silence >= earlyPauseSamples || written - onset >= earlyAfterSamples {
            earlyDone = true
            return emit(early: true)
        }
        return nil
    }

    private mutating func emit(early: Bool) -> [Float]? {
        phase = .checking
        clipEnd = written
        speechSinceClip = false
        lastClipContinuedSpeech = continuing
        lastClipWasEarly = early
        lastClipSpeechShare = speechShare(before: start, seconds: 10)
        return snapshot(from: start)
    }

    /// Includes speech arriving DURING recognition / dictation preparation. nil = inference was so slow
    /// the beginning was overwritten: never execute a request with its first words silently missing.
    public func replay() -> [Float]? { snapshot(from: start) }

    /// Only what arrived after the checked clip (its text is already known from the check).
    public func replayAfterClip() -> [Float]? { snapshot(from: clipEnd) }

    public mutating func reject() {
        if lastClipWasEarly {
            // The early look found no name: the same phrase goes on and is checked whole (from its start).
            lastClipWasEarly = false
            phase = .collecting
        } else if continuous, speechSinceClip {
            // Never reach back further than half the ring: a very slow check must not make the next clip unreadable.
            start = max(clipEnd - preRollSamples, written - ring.count / 2, 0)
            onset = clipEnd
            continuing = true
            phase = .collecting
        } else {
            phase = silence >= pauseSamples ? .armed : .waitingForSilence
        }
        speechSinceClip = false
    }

    /// An early wake amid other speech (decision 17): the request is taken from the whole phrase, so the phrase
    /// goes on being collected and the next clip is it, whole.
    public mutating func collectWholePhrase() {
        guard lastClipWasEarly else { return }
        lastClipWasEarly = false
        phase = .collecting
    }

    public mutating func reset() {
        phase = .armed
        written = 0
        start = 0
        onset = 0
        silence = 0
        clipEnd = 0
        speechSinceClip = false
        continuing = false
        speechInPhrase = 0
        earlyDone = false
        flags.removeAll(keepingCapacity: true)
        flagsHead = 0
        lastClipContinuedSpeech = false
        lastClipSpeechShare = 0
        lastClipWasEarly = false
    }

    private mutating func remember(_ count: Int, speech: Bool) {
        flags.append((written, count, speech))
        let keep = 16 * rate
        while flagsHead < flags.count, flags[flagsHead].end <= written - keep { flagsHead += 1 }
        if flagsHead > 1_024 { flags.removeFirst(flagsHead); flagsHead = 0 }
    }

    /// Voice share of `[end - seconds, end)`; time before the first sample counts as silence.
    private func speechShare(before end: Int, seconds: Double) -> Double {
        let window = Int(seconds * Double(rate))
        let from = end - window
        var voiced = 0
        for i in flagsHead..<flags.count {
            let f = flags[i]
            guard f.speech else { continue }
            let lo = max(f.end - f.count, from), hi = min(f.end, end)
            if hi > lo { voiced += hi - lo }
        }
        return Double(voiced) / Double(window)
    }

    private func snapshot(from first: Int) -> [Float]? {
        guard written - first <= ring.count else { return nil }
        return (first..<written).map { ring[$0 % ring.count] }
    }
}
