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
    /// Gave up after the quiet restarts, or no microphone access: the tray shows a problem line (slice 5a).
    private(set) var broken = false
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
    private var recovery = EarsRecovery()
    private var retryTimer: Timer?
    private let journal = EarsJournal()
    /// Acceptance runs only: CHILK_EARS_FAIL=n — the first n microphone starts break 3 s later.
    private var injectedFailures = ProcessInfo.processInfo.environment["CHILK_EARS_FAIL"].flatMap(Int.init) ?? 0
    private let demo = ProcessInfo.processInfo.environment["CHILK_WAKE_FILE"].map { URL(fileURLWithPath: $0) }

    init() {
        enabled = UserDefaults.standard.bool(forKey: "wakeEarsEnabled") || demo != nil
        let model = self.model
        // Bench 3c (2026-10-05): speech that arrives while a phrase is being checked is checked next, so a TV or a
        // podcast that never pauses no longer leaves him deaf after the first phrase.
        // Slice 8b (decision 17): the early check is off in code until bench 3c passes; CHILK_EARLY_WAKE=1/0 overrides.
        let early = ProcessInfo.processInfo.environment["CHILK_EARLY_WAKE"].map { $0 == "1" } ?? Ears.earlyWakeByDefault
        input = VoiceInput(recognize: { try await model.recognize($0) }, gate: WakeAudioGate(continuous: true, early: early))
        // CHILK_WAKE_TEXT=1 (diagnosis with synthetic speech only): what Whisper heard goes to the debug log —
        // never to the journal, never by default.
        let showText = ProcessInfo.processInfo.environment["CHILK_WAKE_TEXT"] != nil
        input.onCheck = { [weak self] text, hit, seconds in
            guard let self else { return }
            self.checkCount += 1
            // Only event/cost; never the background transcript.
            self.note(String(format: "wake check %d hit=%@ %.2f s", self.checkCount, hit ? "yes" : "no", seconds))
            if showText { self.log("wake text «\(text)»") }
        }
        input.onError = { [weak self] error in self?.fail(error) }
        note("ears \(enabled ? "on" : "off") at launch, early check \(early ? "on" : "off")")
    }

    func start() { if enabled { prepare() } }

    func toggle() {
        enabled.toggle()
        if demo == nil { UserDefaults.standard.set(enabled, forKey: "wakeEarsEnabled") }
        retryTimer?.invalidate()
        recovery.reset()
        broken = false
        note(enabled ? "ears turned on" : "ears turned off")
        if enabled { passive.retry(); prepare() }
        else {
            stopCapture(because: "turned off")
            status = String(localized: "Уши выключены")
            onDisabled?()
        }
    }

    /// «Слух сломался — включить» in the tray: off and on again, as the user would do by hand.
    func restart() {
        if enabled { toggle() }
        toggle()
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
                note("wake model ready")
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
            self.note("wake accepted")
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

    /// Slice 8b: the early check (decision 17) — on by default only once bench 3c passed its thresholds.
    static let earlyWakeByDefault = false

    /// When the microphone last heard a voice while dictating (decision 1: «э-э-э» keeps him listening).
    var lastVoiceAt: TimeInterval { input.lastVoiceAt }

    /// After an early wake amid other speech: the request from the whole phrase (decision 17).
    func wholePhrase() async -> String? { await input.wholePhrase() }

    func attach(_ dictation: Dictation) throws {
        try input.attach { samples in
            if let buffer = AudioSamples.buffer(samples) { dictation.feed(buffer) }
        }
    }

    /// While thinking/answering the microphone is CLOSED; voice cannot interrupt the answer (SPEC).
    func stopListening() {
        passive.pause()
        dictating = false
        stopCapture(because: "answering")
        if enabled { status = String(localized: "Уши на паузе: Чилк отвечает") }
    }

    func shutdown() { passive.pause(); retryTimer?.invalidate(); stopCapture(because: "quit") }

    private func stopCapture(because reason: String) {
        if capturing { note("capture stopped (\(reason))") }
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
            started("file")
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
        started("microphone")
    }

    private func started(_ source: String) {
        let now = ProcessInfo.processInfo.systemUptime
        recovery.started(at: now)
        note("capture started (\(source))")
        if injectedFailures > 0 {
            injectedFailures -= 1
            let generation = captureGeneration
            Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.capturing, self.captureGeneration == generation else { return }
                    self.fail(EarsError.assets("injected failure (CHILK_EARS_FAIL)"))
                }
            }
        }
    }

    /// Decision 2026-10-05: restart quietly after 2 / 10 / 60 s; the 4th failure in a row is said out loud.
    /// Denied microphone access is never retried — only the user can change it.
    private func fail(_ error: Error) {
        passive.fail()
        stopCapture(because: "error")
        dictating = false
        note("ears error: \(error)")
        retryTimer?.invalidate()
        if case EarsError.microphoneDenied = error {
            status = String(localized: "Нет доступа к микрофону")
            broken = true
            notice(Lines.noMicrophone)
            onError?()
            return
        }
        switch recovery.failed(at: ProcessInfo.processInfo.systemUptime) {
        case .retry(let after):
            status = String(localized: "Уши: перезапускаю…")
            note(String(format: "retry %d in %.0f s", recovery.attempts, after))
            retryTimer = Timer.scheduledTimer(withTimeInterval: after, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.retry() }
            }
        case .giveUp:
            status = String(localized: "Уши недоступны — выключи и включи их")
            broken = true
            note("gave up after \(EarsRecovery.delays.count) restarts")
            notice(Lines.earsBroken)
        }
        onError?()
    }

    private func retry() {
        guard enabled else { return }
        passive.retry()
        note("retrying")
        if ready { startPassive() } else { prepare() }
    }

    /// Ears events go to the always-on local journal (no audio, no words) and to the debug log.
    private func note(_ line: String) {
        journal.write(line)
        log(line)
    }

    private enum AudioPacket: Sendable { case audio([Float], Float, TimeInterval), failed }
    private final class OverflowFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.withLock { flag = true } }
        var value: Bool { lock.withLock { flag } }
    }
}

/// `ears.log` next to the app state: events and error codes only — never audio or recognised words. ~1 MB at
/// most (one previous file is kept as ears.1.log).
@MainActor
final class EarsJournal {
    private let url = AppState.directory.appendingPathComponent("ears.log")
    private let limit = 512 * 1024
    private let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        f.timeZone = .current
        return f
    }()

    func write(_ line: String) {
        let data = Data("\(stamp.string(from: Date())) \(line)\n".utf8)
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit {
            let old = url.deletingLastPathComponent().appendingPathComponent("ears.1.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }
}
