import CFvad
import ChilkCore
import Foundation

/// What the wake check already heard (decision 2026-10-05, MVP).
public struct WakeHeard: Sendable, Equatable {
    /// Whisper's text after the name; empty = he was only called.
    public let request: String
    /// Someone else was talking around the call (a TV, a podcast): a follow-up window would hear them too.
    /// Slice 8b (decision 2): a voice in more than half of the 10 s before the call.
    public let amidSpeech: Bool
    /// Slice 8b (decision 17): an early wake amid other speech — the request comes from the whole phrase
    /// (`VoiceInput.wholePhrase()`), not from the early clip and not from Apple's dictation.
    public let wholePending: Bool
    public init(request: String, amidSpeech: Bool, wholePending: Bool = false) {
        self.request = request
        self.amidSpeech = amidSpeech
        self.wholePending = wholePending
    }
}

/// Main-actor audio router. The microphone has ONE owner; wake recognition runs off-actor, while this
/// router keeps recording in a bounded RAM buffer. Attaching dictation replays that buffer atomically.
@MainActor
public final class VoiceInput {
    public typealias Recognize = @Sendable ([Float]) async throws -> String
    public enum Mode: Sendable { case suspended, wake, preparing, dictating, wholePhrase }
    public enum InputError: Error { case bufferOverrun }
    public private(set) var mode: Mode = .suspended
    /// Bench only: the voice share before the last checked clip.
    public var lastSpeechShare: Double { gate.lastClipSpeechShare }
    public var isChecking: Bool { (mode == .wake || mode == .wholePhrase) && gate.isChecking }
    /// When the microphone last heard a voice while dictating (systemUptime of the packet): «э-э-э» without words
    /// keeps him listening longer (slice 8b, decision 1).
    public private(set) var lastVoiceAt: TimeInterval = -.infinity
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
    private var heardInCheck: WakeHeard?
    private var whole: CheckedContinuation<String?, Never>?
    private var wholeResult: String??
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
        heardInCheck = nil
        lastVoiceAt = -.infinity
        resolveWhole(nil)
        wholeResult = nil
        gate.reset()
        vad.reset()
    }

    /// After a voice wake returns what Whisper already heard, and replays only the audio AFTER the checked clip:
    /// the clip may start with someone else's speech before the name, which Apple would dictate as the request
    /// (bench 3c, 2026-10-05). nil = the hotkey (nothing ambient is replayed at all).
    @discardableResult
    public func prepareDictation(replayWake: Bool, at: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> WakeHeard? {
        let heard = replayWake ? heardInCheck : nil
        if let heard, heard.wholePending {
            // Keep collecting the phrase into the gate; its whole check gives the request (`wholePhrase()`).
            heardInCheck = nil
            wholeResult = nil
            gate.collectWholePhrase()
            mode = .wholePhrase
            return heard
        }
        let audio = !replayWake ? [] : heard != nil ? gate.replayAfterClip() : gate.replay()
        guard let audio else { throw InputError.bufferOverrun }
        generation += 1             // invalidates any wake check still in flight
        task?.cancel()
        mode = .preparing
        dictationCutoff = replayWake ? nil : at
        pending = replayWake ? audio + frame : [] // a hotkey must not replay ANY ambient audio
        frame.removeAll(keepingCapacity: true)
        overrun = false
        sink = nil
        heardInCheck = nil
        return heard
    }

    /// After an early wake amid speech: the request from the whole phrase (Whisper's text after the name), or nil
    /// when the whole phrase did not carry the name (then the early clip's request stands).
    public func wholePhrase() async -> String? {
        if let done = wholeResult { wholeResult = nil; return done }
        guard mode == .wholePhrase else { return nil }
        return await withCheckedContinuation { whole = $0 }
    }

    private func resolveWhole(_ text: String?) {
        if let w = whole { whole = nil; w.resume(returning: text) } else if mode == .wholePhrase { wholeResult = .some(text) }
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
        case .dictating:
            sink?(accepted)
            // Voice activity only (decision 1): a 20 ms frame of the packet is enough, no words are kept.
            if accepted.count >= 320, speech ?? vad.isSpeech(Array(accepted.suffix(320))) {
                lastVoiceAt = ProcessInfo.processInfo.systemUptime    // the conversation's clock (packets arrive live)
            }
        case .preparing:
            if pending.count + accepted.count <= pendingLimit { pending += accepted }
            else { pending.removeAll(); overrun = true }
        case .wake, .wholePhrase:
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
                guard let self, self.generation == id, self.mode == .wake || self.mode == .wholePhrase,
                      !Task.isCancelled else { return }
                let request = WakePhrase.request(in: text)
                let hit = request != nil
                let end = ProcessInfo.processInfo.systemUptime
                self.onCheck(text, hit, end - start)
                if self.mode == .wholePhrase {
                    self.resolveWhole(request)
                    return
                }
                if let request {
                    let amid = self.gate.lastClipSpeechShare > 0.5
                    self.heardInCheck = WakeHeard(request: request, amidSpeech: amid,
                                                  wholePending: amid && self.gate.lastClipWasEarly)
                    self.onWake()
                } else {
                    self.gate.reject()
                }
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
