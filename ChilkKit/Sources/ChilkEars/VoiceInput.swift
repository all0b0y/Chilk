import CFvad
import ChilkCore
import Foundation

/// Main-actor audio router. The microphone has ONE owner; wake recognition runs off-actor, while this
/// router keeps recording in a bounded RAM buffer. Attaching dictation replays that buffer atomically.
@MainActor
public final class VoiceInput {
    public typealias Recognize = @Sendable ([Float]) async throws -> String
    public enum Mode: Sendable { case suspended, wake, preparing, dictating }
    public enum InputError: Error { case bufferOverrun }
    public private(set) var mode: Mode = .suspended
    public var isChecking: Bool { mode == .wake && gate.isChecking }
    public var onError: (Error) -> Void = { _ in }
    /// Debug harness only. The app never logs the transcript of ambient speech.
    public var onCheck: (_ text: String, _ hit: Bool, _ seconds: Double) -> Void = { _, _, _ in }

    private let recognize: Recognize
    private let vad = WebRTCVAD()
    private var gate: WakeAudioGate
    private var task: Task<Void, Never>?
    private var generation = 0
    private var onWake: () -> Void = {}
    private var sink: (([Float]) -> Void)?
    private var pending: [Float] = []
    private var overrun = false
    private var dictationCutoff: TimeInterval?
    private var frame: [Float] = []
    private let pendingLimit = 16_000 * 12

    public init(recognize: @escaping Recognize, gate: WakeAudioGate = WakeAudioGate()) {
        self.recognize = recognize
        self.gate = gate
    }

    public func arm(onWake: @escaping () -> Void) {
        suspend()
        self.onWake = onWake
        mode = .wake
    }

    public func suspend() {
        generation += 1
        task?.cancel()
        task = nil
        mode = .suspended
        sink = nil
        onWake = {}
        pending.removeAll(keepingCapacity: false)
        frame.removeAll(keepingCapacity: false)
        overrun = false
        dictationCutoff = nil
        gate.reset()
        vad.reset()
    }

    public func prepareDictation(replayWake: Bool, at: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        let audio = replayWake ? gate.replay() : []
        guard let audio else { throw InputError.bufferOverrun }
        generation += 1             // invalidates any wake check still in flight
        task?.cancel()
        mode = .preparing
        dictationCutoff = replayWake ? nil : at
        pending = replayWake ? audio + frame : [] // a hotkey must not replay ANY ambient audio
        frame.removeAll(keepingCapacity: true)
        overrun = false
        sink = nil
    }

    public func attach(_ feed: @escaping ([Float]) -> Void) throws {
        guard mode == .preparing, !overrun else { throw InputError.bufferOverrun }
        feed(pending)
        pending.removeAll(keepingCapacity: false)
        sink = feed
        mode = .dictating
    }

    /// 16 kHz mono Float32. A speech override allows deterministic tests; real audio always uses WebRTC.
    public func feed(_ samples: [Float], speech: Bool? = nil, capturedAt: TimeInterval? = nil) {
        var accepted = samples
        // A packet may have waited in the main-actor queue before the hotkey. Use capture time, not
        // delivery time; retain only its portion after the explicit call. Confirmed wakes keep pre-roll.
        if mode == .preparing || mode == .dictating,
           let capturedAt, let cutoff = dictationCutoff, cutoff > capturedAt {
            let skip = Int(ceil((cutoff - capturedAt) * 16_000))
            guard skip < accepted.count else { return }
            accepted.removeFirst(skip)
        }
        switch mode {
        case .suspended: return
        case .dictating: sink?(accepted)
        case .preparing:
            if pending.count + accepted.count <= pendingLimit { pending += accepted }
            else { pending.removeAll(); overrun = true }
        case .wake:
            frame += accepted
            var consumed = 0
            while frame.count - consumed >= 320 {
                let chunk = Array(frame[consumed..<(consumed + 320)])
                consumed += 320
                if let clip = gate.append(chunk, speech: speech ?? vad.isSpeech(chunk)) { check(clip) }
            }
            frame.removeFirst(consumed)
        }
    }

    private func check(_ clip: [Float]) {
        let id = generation
        let recognize = self.recognize
        task = Task { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            do {
                // The gate already supplies 0.7 s of pre-roll. Extra leading silence makes Whisper
                // drop quiet opening qualifiers («Короче, Чилк…»), creating false direct addresses.
                let padding = Array(repeating: Float(0), count: 8_000)
                let text = try await recognize(clip + padding)
                guard let self, self.generation == id, self.mode == .wake, !Task.isCancelled else { return }
                let hit = WakePhrase.matches(text)
                self.onCheck(text, hit, ProcessInfo.processInfo.systemUptime - start)
                if hit { self.onWake() }
                else { self.gate.reject() }
            } catch {
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.suspend()
                self.onError(error)
            }
        }
    }
}

/// WebRTC VAD, mode 3, 20 ms at 16 kHz (same detector used by spike 003).
private final class WebRTCVAD {
    private let instance: OpaquePointer
    init() {
        guard let instance = fvad_new() else { fatalError("cannot allocate VAD") }
        self.instance = instance
        configure()
    }
    deinit { fvad_free(instance) }
    func reset() { fvad_reset(instance); configure() }
    private func configure() { fvad_set_mode(instance, 3); fvad_set_sample_rate(instance, 16_000) }
    func isSpeech(_ frame: [Float]) -> Bool {
        let pcm = frame.map { Int16(max(-32_768, min(32_767, $0 * 32_768))) }
        return pcm.withUnsafeBufferPointer { fvad_process(instance, $0.baseAddress, $0.count) == 1 }
    }
}
