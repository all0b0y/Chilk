import AppKit
import AVFoundation
import Darwin
import ChilkCore
import ChilkEars

/// A single microphone shared by passive wake detection and conversation dictation. Passive ears are
/// opt-in; turning them off closes the device immediately. No ambient speech is logged or sent to Codex.
@MainActor
final class Ears {
    private(set) var enabled: Bool
    private(set) var ready = false
    private(set) var status = String(localized: "Уши выключены")
    var onWake: (() -> Void)?
    var onDisabled: (() -> Void)?
    var onError: (() -> Void)?
    var onLevel: (Float) -> Void = { _ in }
    var log: (String) -> Void = { _ in }
    var notice: (String) -> Void = { _ in }

    private let model = WakeModel()
    private let mic = Microphone()
    private let input: VoiceInput
    private var preparation: Task<Void, Never>?
    private var capture: Task<Void, Never>?
    private var captureGeneration = 0
    private var passiveStart: Task<Void, Never>?
    private var capturing = false
    private var checkCount = 0
    private var dictating = false
    private var passive = PassiveEarsPolicy()
    private let demo = ProcessInfo.processInfo.environment["CHILK_WAKE_FILE"].map { URL(fileURLWithPath: $0) }

    init() {
        enabled = UserDefaults.standard.bool(forKey: "wakeEarsEnabled") || demo != nil
        let model = self.model
        // Bench 3c (2026-10-05): speech that arrives while a phrase is being checked is checked next, so a TV or a
        // podcast that never pauses no longer leaves him deaf after the first phrase.
        input = VoiceInput(recognize: { try await model.recognize($0) }, gate: WakeAudioGate(continuous: true))
        input.onCheck = { [weak self] _, hit, seconds in
            guard let self else { return }
            self.checkCount += 1
            // Only event/cost; never the background transcript.
            self.log(String(format: "wake check %d hit=%@ %.2f s", self.checkCount, hit ? "yes" : "no", seconds))
        }
        input.onError = { [weak self] error in self?.fail(error) }
    }

    func start() { if enabled { prepare() } }

    func toggle() {
        enabled.toggle()
        if demo == nil { UserDefaults.standard.set(enabled, forKey: "wakeEarsEnabled") }
        if enabled { passive.retry(); prepare() }
        else {
            stopCapture()
            status = String(localized: "Уши выключены")
            log("ears disabled; microphone closed")
            onDisabled?()
        }
    }

    private func prepare() {
        if ready { startPassive(); return }
        guard preparation == nil else { status = String(localized: "Учусь слышать…"); return }
        status = String(localized: "Учусь слышать…")
        notice(String(localized: "Учусь слышать твоё имя 👂 Горячая клавиша уже работает"))
        let env = ProcessInfo.processInfo.environment
        let folder = env["CHILK_WAKE_MODEL"].map { URL(fileURLWithPath: $0) }
        let base = env["CHILK_WAKE_BASE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Chilk/ears")
        preparation = Task {
            do {
                try await model.prepare(folder: folder, base: base) { [weak self] state in
                    Task { @MainActor in self?.progress(state) }
                }
                ready = true
                preparation = nil
                log("wake model ready")
                startPassive()
            } catch {
                preparation = nil
                fail(error)
            }
        }
    }

    private func progress(_ state: WakeModel.State) {
        guard enabled else { return }
        switch state {
        case .downloading(let fraction): status = String(localized: "Скачиваю слух…") + " \(Int(fraction * 100))%"
        case .learning: status = String(localized: "Учусь слышать… Первое включение может занять несколько минут")
        case .ready: break
        }
    }

    func resume() {
        passive.conversationEnded()
        startPassive()
    }

    private func startPassive() {
        guard enabled, ready, !dictating, passive.allowed else { return }
        input.arm { [weak self] in
            guard let self, self.enabled, !self.dictating, self.passive.allowed else { return }
            self.log("wake accepted")
            self.onWake?()
        }
        status = String(localized: "Уши включены: «Чилк» / «Эй, Чилк»")
        passiveStart?.cancel()
        passiveStart = Task {
            do { try await startCapture() }
            catch is CancellationError {}
            catch { fail(error) }
        }
    }

    /// Called synchronously before Apple prepares its model, so speech during setup is also buffered.
    /// After a voice wake: what Whisper already heard (the request after the name, and whether others were talking).
    @discardableResult
    func prepareListening(replayWake: Bool) throws -> WakeHeard? {
        passiveStart?.cancel()
        passive.pause()
        dictating = true
        return try input.prepareDictation(replayWake: replayWake, at: AVAudioTime.seconds(forHostTime: mach_absolute_time()))
    }

    func captureForDictation() async throws { try await startCapture() }

    func attach(_ dictation: Dictation) throws {
        try input.attach { samples in
            if let buffer = AudioSamples.buffer(samples) { dictation.feed(buffer) }
        }
    }

    /// While thinking/answering the microphone is CLOSED; voice cannot interrupt the answer (SPEC).
    func stopListening() {
        passive.pause()
        dictating = false
        stopCapture()
        if enabled { status = String(localized: "Уши на паузе: Чилк отвечает") }
    }

    func shutdown() { passive.pause(); stopCapture() }

    private func stopCapture() {
        captureGeneration += 1
        passiveStart?.cancel()
        capture?.cancel()
        capture = nil
        mic.stop()
        capturing = false
        input.suspend()
    }

    private func startCapture() async throws {
        guard !capturing else { return }
        let generation = captureGeneration
        if let demo {
            let samples = Array(repeating: Float(0), count: 9_600) + (try AudioSamples.load(file: demo))
            capturing = true
            capture = Task { [weak self] in
                for offset in stride(from: 0, to: samples.count, by: 640) {
                    guard !Task.isCancelled, let self, self.captureGeneration == generation else { return }
                    self.input.feed(Array(samples[offset..<min(offset + 640, samples.count)]))
                    try? await Task.sleep(for: .milliseconds(40))
                }
                while !Task.isCancelled {
                    guard let self, self.captureGeneration == generation else { return }
                    self.input.feed(Array(repeating: 0, count: 640))
                    try? await Task.sleep(for: .milliseconds(40))
                }
            }
            log("capture started (file)")
            return
        }
        guard await Microphone.requestAccess() else { throw EarsError.microphoneDenied }
        guard generation == captureGeneration, !Task.isCancelled else { throw CancellationError() }
        let converter = AudioSamples()
        let (stream, continuation) = AsyncStream<AudioPacket>.makeStream(bufferingPolicy: .bufferingNewest(80))
        let overflow = OverflowFlag()
        try mic.start { buffer, level, time in
            do {
                let capturedAt = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime)
                    : AVAudioTime.seconds(forHostTime: mach_absolute_time()) - Double(buffer.frameLength) / buffer.format.sampleRate
                let samples = try converter.convert(buffer)
                if case .dropped = continuation.yield(.audio(samples, level, capturedAt)) { overflow.set() }
            } catch { continuation.yield(.failed) }
        }
        capturing = true
        capture = Task { [weak self] in
            for await packet in stream {
                guard !Task.isCancelled, let self, self.captureGeneration == generation else { break }
                if overflow.value { self.fail(VoiceInput.InputError.bufferOverrun); break }
                switch packet {
                case .audio(let samples, let level, let capturedAt):
                    self.input.feed(samples, capturedAt: capturedAt); self.onLevel(level)
                case .failed: self.fail(EarsError.noAudioFormat)
                }
            }
            continuation.finish()
        }
        log("capture started (microphone)")
    }

    private func fail(_ error: Error) {
        passive.fail()
        stopCapture()
        dictating = false
        status = String(localized: "Уши недоступны — попробуй выключить и включить их")
        log("ears error: \(error)")
        if case EarsError.microphoneDenied = error { notice(Lines.noMicrophone) }
        else { notice(Lines.earsFailed) }
        onError?()
    }

    private enum AudioPacket: Sendable { case audio([Float], Float, TimeInterval), failed }
    private final class OverflowFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.withLock { flag = true } }
        var value: Bool { lock.withLock { flag } }
    }
}
