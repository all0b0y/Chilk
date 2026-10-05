import Foundation

/// Bounded in-memory audio only. Check the first phrase after a pause; keep everything spoken while the
/// recognizer runs so Apple dictation can replay it, then join the live microphone without a gap.
///
/// `continuous` (bench candidate, 2026-10-04): speech that arrives while a check is running is checked next,
/// overlapping the previous clip by the pre-roll, instead of waiting for a ≥ pause silence. Without it a TV
/// that never pauses leaves only the first phrase checked.
public struct WakeAudioGate: Sendable {
    private enum Phase: Sendable { case armed, collecting, checking, waitingForSilence }
    private var phase: Phase = .armed
    private let rate: Int, preRollSamples: Int, pauseSamples: Int, maxPhraseSamples: Int
    public let continuous: Bool
    private var ring: [Float]
    private var written = 0
    private var start = 0, onset = 0, silence = 0
    private var clipEnd = 0
    private var speechSinceClip = false

    public init(sampleRate: Int = 16_000, preRoll: Double = 0.7, pause: Double = 0.6,
                maxPhrase: Double = 5, capacity: Double = 12, continuous: Bool = false) {
        precondition(sampleRate > 0 && capacity > preRoll + maxPhrase)
        rate = sampleRate
        preRollSamples = Int(preRoll * Double(sampleRate))
        pauseSamples = Int(pause * Double(sampleRate))
        maxPhraseSamples = Int(maxPhrase * Double(sampleRate))
        ring = Array(repeating: 0, count: Int(capacity * Double(sampleRate)))
        self.continuous = continuous
    }

    public var isChecking: Bool { phase == .checking }
    public var bufferedSampleCount: Int { min(written, ring.count) }

    /// Feed fixed VAD frames, in chronological order. A non-nil return requests ONE recognition.
    public mutating func append(_ samples: [Float], speech: Bool) -> [Float]? {
        let before = written
        for sample in samples { ring[written % ring.count] = sample; written += 1 }
        silence = speech ? 0 : silence + samples.count
        switch phase {
        case .checking:
            if speech { speechSinceClip = true }
            return nil
        case .waitingForSilence:
            if silence >= pauseSamples { phase = .armed }
            return nil
        case .armed:
            guard speech else { return nil }
            start = max(0, before - preRollSamples)
            onset = before
            phase = .collecting
        case .collecting: break
        }
        if silence >= pauseSamples || written - onset >= maxPhraseSamples {
            phase = .checking
            clipEnd = written
            speechSinceClip = false
            return snapshot(from: start)
        }
        return nil
    }

    /// Includes speech arriving DURING recognition / dictation preparation. nil = inference was so slow
    /// the beginning was overwritten: never execute a request with its first words silently missing.
    public func replay() -> [Float]? { snapshot(from: start) }

    public mutating func reject() {
        if continuous, speechSinceClip {
            // Never reach back further than half the ring: a very slow check must not make the next clip unreadable.
            start = max(clipEnd - preRollSamples, written - ring.count / 2, 0)
            onset = clipEnd
            phase = .collecting
        } else {
            phase = silence >= pauseSamples ? .armed : .waitingForSilence
        }
        speechSinceClip = false
    }

    public mutating func reset() {
        phase = .armed
        written = 0
        start = 0
        onset = 0
        silence = 0
        clipEnd = 0
        speechSinceClip = false
    }

    private func snapshot(from first: Int) -> [Float]? {
        guard written - first <= ring.count else { return nil }
        return (first..<written).map { ring[$0 % ring.count] }
    }
}
