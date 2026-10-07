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
///   speech» only above half — a few words before «Чилк» or a first failed call are not a TV. Right after the ears
///   are re-armed the share is taken over the history there is (at least 3 s).
/// - `early` (decision 17): a fresh phrase is checked early — at a short pause or after 1.5 s of it, whichever
///   comes first; a second early look at the next short pause («Так, | Чилк, | …»: the name is often after the
///   first pause). Rejected, the phrase goes on being collected and is checked whole, as before.
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
    private var earlyChecks = 0, earlyTimerUsed = false, speechSinceEarly = 0, wholeRequested = false
    /// Voice flags, one per `append` call, with the sample count at its end (the last 16 s).
    private var flags: [(end: Int, count: Int, speech: Bool)] = []
    private var flagsHead = 0
    /// The last clip continued speech without a pause (background, or the user talking straight on).
    public private(set) var lastClipContinuedSpeech = false
    /// Share of the 10 s before the last clip in which a voice was heard (0…1).
    public private(set) var lastClipSpeechShare = 0.0
    /// The last clip was this phrase's early check.
    public private(set) var lastClipWasEarly = false
    /// …cut by the 1.5 s timer, not at a pause: its last word may be cut in two.
    public private(set) var lastClipEarlyByTimer = false

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
            if speech { speechSinceClip = true; speechInPhrase += samples.count; speechSinceEarly += samples.count }
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
            earlyChecks = 0
            earlyTimerUsed = false
            speechSinceEarly = 0
            wholeRequested = false
            phase = .collecting
        case .collecting: break
        }
        if speech { speechInPhrase += samples.count; speechSinceEarly += samples.count }
        if silence >= pauseSamples || written - onset >= maxPhraseSamples {
            if earlyChecks > 0, speechSinceEarly == 0, !wholeRequested {
                // Nothing was said since the last early look: the whole phrase IS that clip, already rejected.
                phase = silence >= pauseSamples ? .armed : .waitingForSilence
                return nil
            }
            return emit(early: false, byTimer: false)
        }
        guard early, !continuing, earlyChecks < 2, speechInPhrase >= earlyMinSpeechSamples,
              speechSinceEarly >= earlyMinSpeechSamples else { return nil }
        if silence >= earlyPauseSamples { return emit(early: true, byTimer: false) }
        if !earlyTimerUsed, written - onset >= earlyAfterSamples {
            earlyTimerUsed = true
            return emit(early: true, byTimer: true)
        }
        return nil
    }

    private mutating func emit(early: Bool, byTimer: Bool) -> [Float]? {
        guard let clip = snapshot(from: start) else {
            // The ring no longer holds the phrase's start (a very slow check): skip it rather than stay «checking».
            phase = .waitingForSilence
            return nil
        }
        phase = .checking
        clipEnd = written
        speechSinceClip = false
        lastClipContinuedSpeech = continuing
        lastClipWasEarly = early
        lastClipEarlyByTimer = byTimer
        if early { earlyChecks += 1; speechSinceEarly = 0 }
        lastClipSpeechShare = speechShare(before: start)
        return clip
    }

    /// Includes speech arriving DURING recognition / dictation preparation. nil = inference was so slow
    /// the beginning was overwritten: never execute a request with its first words silently missing.
    public func replay() -> [Float]? { snapshot(from: start) }

    /// Only what arrived after the checked clip (its text is already known from the check). `overlap` samples of
    /// the clip's end are repeated when the clip may have cut a word in two (the early check's 1.5 s timer).
    public func replayAfterClip(overlap: Int = 0) -> [Float]? { snapshot(from: max(start, clipEnd - overlap)) }

    public mutating func reject() {
        if lastClipWasEarly {
            // The early look found no name: the same phrase goes on and is checked whole (from its start) — unless
            // it is already over and nothing was said since: then the whole phrase IS the clip just rejected.
            lastClipWasEarly = false
            if !speechSinceClip, silence >= pauseSamples {
                phase = .armed
            } else {
                start = max(start, written - ring.count / 2)
                phase = .collecting
            }
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
        earlyChecks = 2                                   // no more early looks: the next clip is the whole phrase
        wholeRequested = true
        start = max(start, written - ring.count / 2)
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
        earlyChecks = 0
        earlyTimerUsed = false
        speechSinceEarly = 0
        wholeRequested = false
        lastClipEarlyByTimer = false
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

    /// Voice share of the 10 s before `end` — or of the history there is since the ears were armed, at least 3 s.
    private func speechShare(before end: Int) -> Double {
        let window = min(10 * rate, max(3 * rate, end))
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
