import AVFoundation
import Foundation
import Speech

public enum EarsError: Error, CustomStringConvertible {
    case microphoneDenied
    case noAudioFormat
    case assets(String)

    public var description: String {
        switch self {
        case .microphoneDenied: "microphone access denied"
        case .noAudioFormat: "no audio format for the dictation model"
        case .assets(let why): "dictation model unavailable: \(why)"
        }
    }
}

/// Live Russian dictation (В30, step 3): Apple's on-device DictationTranscriber via SpeechAnalyzer.
/// Feed it audio in any format; the text so far (final + still-changing part) comes back as it is spoken.
public final class Dictation: @unchecked Sendable {
    public typealias TextHandler = @Sendable (_ text: String, _ isFinal: Bool) -> Void

    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var analyzer: SpeechAnalyzer?
    private var analyzeTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    public init() {}

    /// Downloads the ru-RU dictation model if needed (once; works offline afterwards).
    public static func ensureModel(locale: Locale = Locale(identifier: "ru-RU")) async throws {
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        if await AssetInventory.status(forModules: [transcriber]) == .installed { return }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw EarsError.assets(String(describing: error))
        }
    }

    public func start(locale: Locale = Locale(identifier: "ru-RU"), hints: [String] = ["Чилк"], onText: @escaping TextHandler) async throws {
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        try await Self.ensureModel(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let context = AnalysisContext()
        context.contextualStrings[.general] = hints
        try? await analyzer.setContext(context)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw EarsError.noAudioFormat }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        lock.withLock {
            self.format = format
            self.continuation = continuation
            self.analyzer = analyzer
            self.converter = nil
        }
        resultsTask = Task {
            var finalText = ""
            do {
                for try await result in transcriber.results {
                    let piece = String(result.text.characters)
                    if result.isFinal {
                        finalText += piece
                        onText(finalText.trimmingCharacters(in: .whitespaces), true)
                    } else {
                        onText((finalText + piece).trimmingCharacters(in: .whitespaces), false)
                    }
                }
            } catch {}
        }
        analyzeTask = Task {
            do {
                if let last = try await analyzer.analyzeSequence(stream) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                await analyzer.cancelAndFinishNow()
            }
        }
    }

    /// Any PCM format; converted to the model's format here. Safe to call from the audio thread.
    public func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let format, let continuation else { lock.unlock(); return }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        let converter = self.converter
        lock.unlock()
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        final class Once: @unchecked Sendable { var used = false }
        let once = Once()
        nonisolated(unsafe) let source = buffer
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if once.used { status.pointee = .noDataNow; return nil }
            once.used = true
            status.pointee = .haveData
            return source
        }
        if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
    }

    /// No more audio: waits until the last words are finalised and delivered.
    public func finish() async {
        let c = lock.withLock { () -> AsyncStream<AnalyzerInput>.Continuation? in
            defer { continuation = nil }
            return continuation
        }
        c?.finish()
        await analyzeTask?.value
        await resultsTask?.value
    }

    public func cancel() async {
        let (c, a) = lock.withLock { () -> (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?) in
            defer { continuation = nil }
            return (continuation, analyzer)
        }
        c?.finish()
        await a?.cancelAndFinishNow()
        resultsTask?.cancel()
    }

    /// Plays an audio file into `feed` in 100 ms chunks, optionally at real-time pace (tests, demos).
    public func play(file url: URL, realtime: Bool) async throws {
        let file = try AVAudioFile(forReading: url)
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            feed(buffer)
            if realtime { try await Task.sleep(for: .milliseconds(100)) }
        }
    }
}

/// The default microphone through AVAudioEngine. `onBuffer` runs on the audio thread.
public final class Microphone: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var running = false

    public init() {}

    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    /// - Parameter onBuffer: audio + its RMS level (0…1).
    public func start(_ onBuffer: @escaping @Sendable (AVAudioPCMBuffer, Float) -> Void) throws {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            var level: Float = 0
            if let data = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var sum: Float = 0
                for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
                level = min(1, (sum / Float(buffer.frameLength)).squareRoot() * 8)
            }
            onBuffer(buffer, level)
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    public func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }
}
