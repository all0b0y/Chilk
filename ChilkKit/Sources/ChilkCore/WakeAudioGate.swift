import Foundation

/// Bounded in-memory audio only. Check the first phrase after a pause; keep everything spoken while the
/// recognizer runs so Apple dictation can replay it, then join the live microphone without a gap.
public struct WakeAudioGate: Sendable {
    private enum Phase: Sendable { case armed, collecting, checking, waitingForSilence }
    private var phase: Phase = .armed
    private let rate: Int, preRollSamples: Int, pauseSamples: Int, maxPhraseSamples: Int
    private var ring: [Float]
    private var written = 0
    private var start = 0, onset = 0, silence = 0

    public init(sampleRate: Int = 16_000, preRoll: Double = 0.7, pause: Double = 0.6,
                maxPhrase: Double = 5, capacity: Double = 12) {
        precondition(sampleRate > 0 && capacity > preRoll + maxPhrase)
        rate = sampleRate
        preRollSamples = Int(preRoll * Double(sampleRate))
        pauseSamples = Int(pause * Double(sampleRate))
        maxPhraseSamples = Int(maxPhrase * Double(sampleRate))
        ring = Array(repeating: 0, count: Int(capacity * Double(sampleRate)))
    }

    public var isChecking: Bool { phase == .checking }
    public var bufferedSampleCount: Int { min(written, ring.count) }

    /// Feed fixed VAD frames, in chronological order. A non-nil return requests ONE recognition.
    public mutating func append(_ samples: [Float], speech: Bool) -> [Float]? {
        let before = written
        for sample in samples { ring[written % ring.count] = sample; written += 1 }
        silence = speech ? 0 : silence + samples.count
        switch phase {
        case .checking: return nil
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
            return snapshot(from: start)
        }
        return nil
    }

    /// Includes speech arriving DURING recognition / dictation preparation. nil = inference was so slow
    /// the beginning was overwritten: never execute a request with its first words silently missing.
    public func replay() -> [Float]? { snapshot(from: start) }

    public mutating func reject() {
        phase = silence >= pauseSamples ? .armed : .waitingForSilence
    }

    public mutating func reset() {
        phase = .armed
        written = 0
        start = 0
        onset = 0
        silence = 0
    }

    private func snapshot(from first: Int) -> [Float]? {
        guard written - first <= ring.count else { return nil }
        return (first..<written).map { ring[$0 % ring.count] }
    }
}
