import AVFoundation
import CFvad
import ChilkCore
import ChilkEars
import CoreMedia
import Foundation
import Speech

/// Bench 3c (decision 2026-10-04): which wake detector survives continuous background speech?
///   chilk-voice bench whisper-v1 <model-folder> <list.txt> <out.jsonl>  — the shipped VoiceInput (VAD gate)
///   chilk-voice bench whisper-v2 <model-folder> <list.txt> <out.jsonl>  — prototype: no skipped phrases + sliding windows
///   chilk-voice bench apple - <list.txt> <out.jsonl>                     — Apple dictation, continuous, word timings
///   chilk-voice bench request <model-folder> <list.tsv> <out.jsonl>      — the shipped wake → request path in noise;
///       list lines are «path<TAB>seconds where pure background starts»; that background then loops (a TV that
///       never stops). Apple's words after the wake are written with timings; analyze_request.py applies the pause rule.
/// Real time is simulated honestly: while a recognition runs, the audio that would have arrived in that wall time is
/// fed afterwards (the detector cannot see it earlier). One JSON line per file; rules are applied by analyze.py.
@MainActor
enum Bench {
    static func run(_ args: [String]) async throws {
        guard args.count == 4 else { print("usage: chilk-voice bench whisper-v1|whisper-v2|apple <model|-> <list.txt> <out.jsonl>"); exit(2) }
        let lines = try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let out = URL(fileURLWithPath: args[3])
        try? FileManager.default.removeItem(at: out)
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        var model: WakeModel?
        if args[0].hasPrefix("whisper") || args[0] == "request" {
            let folder = URL(fileURLWithPath: args[1])
            let base = folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let m = WakeModel()
            try await m.prepare(folder: folder, base: base)
            model = m
        }
        for (n, line) in lines.enumerated() {
            let fields = line.split(separator: "\t").map(String.init)
            let path = fields[0]
            // 1 s of trailing silence closes the last phrase (same for every variant).
            let file = try AudioSamples.load(file: URL(fileURLWithPath: path))
            let samples = file + [Float](repeating: 0, count: 16_000)
            let cpu0 = cpuSeconds(), wall0 = now()
            var row: [String: Any]
            switch args[0] {
            case "whisper-v1": row = try await whisperV1(samples, model: model!)
            case "whisper-v1c": row = try await whisperV1(samples, model: model!, continuous: true)
            case "whisper-v1e": row = try await whisperV1(samples, model: model!, continuous: true, early: true)
            case "whisper-v2": row = try await whisperV2(samples, model: model!)
            case "apple": row = try await apple(path)
            case "request": row = try await request(file, background: Int((Double(fields[1]) ?? 0) * 16_000), model: model!)
            default: print("unknown variant"); exit(2)
            }
            row["file"] = path
            row["audio_s"] = Double(samples.count) / 16_000
            row["cpu_s"] = cpuSeconds() - cpu0
            row["wall_s"] = now() - wall0
            handle.write(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            handle.write(Data("\n".utf8))
            print("\(n + 1)/\(lines.count) \(URL(fileURLWithPath: path).lastPathComponent) checks/segments=\((row["checks"] as? [Any])?.count ?? (row["segments"] as? [Any])?.count ?? 0)")
        }
        try handle.close()
    }

    // MARK: Request — the shipped wake → request path (decision 2026-10-05, MVP)

    /// The background (pure, after the call) also plays for 8 s BEFORE the file, as a TV does before you call him.
    /// Runs the shipped continuous detector until the first wake, then takes what the app dictates: only the audio
    /// after the checked clip (Whisper's text after the name is the start of the request). That audio + 25 s of what
    /// follows (the background looped) goes through Apple dictation with word timings.
    @MainActor
    static func request(_ file: [Float], background: Int, model: WakeModel) async throws -> [String: Any] {
        let tail = background < file.count - 16_000 ? Array(file[background...]) : [Float](repeating: 0, count: 16_000)
        var before: [Float] = []
        while before.count < 16_000 * 8 { before += tail }
        var samples = before + file
        let callEnds = samples.count + 16_000
        while samples.count < callEnds + 16_000 * 40 { samples += tail }
        let clock = SimClock()
        let input = VoiceInput(recognize: { audio in
            let t = now()
            let text = try await model.recognize(audio)
            await clock.finished(after: now() - t)
            return text
        }, gate: WakeAudioGate(continuous: true, early: ProcessInfo.processInfo.environment["BENCH_EARLY"] == "1"))
        var lastText = "", woke = false
        input.onCheck = { text, _, _ in lastText = text }
        input.arm { woke = true }
        var i = 0
        func feedChunk() { let end = min(i + 320, samples.count); input.feed(Array(samples[i..<end])); i = end }
        while i < callEnds, !woke {
            feedChunk()
            guard input.isChecking else { continue }
            let dt = await clock.waitComputed()
            var extra = Int(dt * 16_000)
            while extra > 0, i < samples.count { let before = i; feedChunk(); extra -= i - before }
            await clock.go()
            for _ in 0..<100_000 { if !input.isChecking || woke { break }; await Task.yield() }
        }
        guard woke else { input.suspend(); return ["woke": false] }
        let wakeAt = Double(i) / 16_000
        let share = input.lastSpeechShare
        var heard = try input.prepareDictation(replayWake: true)
        var wholeAt: Double?
        if let early = heard, early.wholePending {
            // Slice 8b: an early wake amid speech — the request is the whole phrase; feed on (real time) until it is checked.
            final class Box: @unchecked Sendable { var done = false; var text: String? }
            let box = Box()
            let waiter = Task { @MainActor in box.text = await input.wholePhrase(); box.done = true }
            while !box.done, i < samples.count {
                feedChunk()
                guard input.isChecking else { continue }
                let dt = await clock.waitComputed()
                var extra = Int(dt * 16_000)
                while extra > 0, i < samples.count { let before = i; feedChunk(); extra -= i - before }
                await clock.go()
                for _ in 0..<100_000 { if box.done { break }; await Task.yield() }
            }
            _ = await waiter.value
            heard = WakeHeard(request: box.text ?? early.request, amidSpeech: true)
            wholeAt = Double(i) / 16_000
            input.suspend()
            var row: [String: Any] = ["segments": [Any]()]
            row["woke"] = true
            row["wake_at"] = wakeAt
            row["whole_at"] = wholeAt
            row["wake_text"] = lastText
            row["heard"] = heard?.request ?? NSNull()
            row["amid_speech"] = true
            row["early_whole"] = true
            row["speech_share"] = share
            row["replayed_s"] = 0
            return row
        }
        var dictated: [Float] = []
        try input.attach { dictated += $0 }
        let replayed = dictated.count
        let end = min(samples.count, i + 16_000 * 25)
        while i < end { feedChunk() }
        input.suspend()
        let url = FileManager.default.temporaryDirectory.appending(path: "chilk-request-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let buffer = AudioSamples.buffer(dictated) else { throw EarsError.noAudioFormat }
        do {                                                  // the header is complete only once the file is closed
            let out = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
            try out.write(from: buffer)
            out.close()
        }
        FileHandle.standardError.write(Data("woke at \(wakeAt) s, dictating \(dictated.count / 16_000) s\n".utf8))
        var row = try await apple(url.path)
        row["woke"] = true
        row["wake_at"] = wakeAt
        row["wake_text"] = lastText
        row["heard"] = heard?.request ?? NSNull()
        row["amid_speech"] = heard?.amidSpeech ?? false
        row["speech_share"] = share
        row["replayed_s"] = Double(replayed) / 16_000
        return row
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    // MARK: Whisper v1 — the shipped detector, unchanged

    /// The recognizer reports its compute time and waits; the harness then feeds that much audio and releases it.
    actor SimClock {
        private var computed: Double?
        private var computedWaiter: CheckedContinuation<Double, Never>?
        private var release: CheckedContinuation<Void, Never>?
        func finished(after seconds: Double) async {
            if let w = computedWaiter { computedWaiter = nil; w.resume(returning: seconds) } else { computed = seconds }
            await withCheckedContinuation { release = $0 }
        }
        func waitComputed() async -> Double {
            if let c = computed { computed = nil; return c }
            return await withCheckedContinuation { computedWaiter = $0 }
        }
        func go() { release?.resume(); release = nil }
    }

    /// `continuous` = the WakeAudioGate candidate: speech that arrived during a check is checked next (no waiting
    /// for a pause), back-to-back windows overlapping by the pre-roll. Same VoiceInput otherwise.
    @MainActor
    static func whisperV1(_ samples: [Float], model: WakeModel, continuous: Bool = false, early: Bool = false) async throws -> [String: Any] {
        let clock = SimClock()
        let input = VoiceInput(recognize: { audio in
            let t = now()
            let text = try await model.recognize(audio)
            await clock.finished(after: now() - t)
            return text
        }, gate: WakeAudioGate(continuous: continuous, early: early))
        var lastText = "", woke = false
        input.onCheck = { text, _, _ in lastText = text }
        input.arm { woke = true }
        var checks: [[String: Any]] = []
        var i = 0
        func feedChunk() { let end = min(i + 320, samples.count); input.feed(Array(samples[i..<end])); i = end }
        while i < samples.count {
            feedChunk()
            if woke { woke = false; input.arm { woke = true } }
            guard input.isChecking else { continue }
            let start = Double(i) / 16_000
            let dt = await clock.waitComputed()
            var extra = Int(dt * 16_000)
            while extra > 0, i < samples.count { let before = i; feedChunk(); extra -= i - before }
            await clock.go()
            for _ in 0..<100_000 { if !input.isChecking || woke { break }; await Task.yield() }
            checks.append(["t": start, "secs": dt, "text": lastText])
            if woke { woke = false; input.arm { woke = true } }
        }
        input.suspend()
        return ["checks": checks]
    }

    // MARK: Whisper v2 — prototype: every phrase checked (queue), sliding windows while speech never pauses

    struct SlidingGate {
        let preRoll = 11_200, pause = 9_600, window = 80_000, minimum = 12_800
        /// BENCH_HOP (samples) and BENCH_ONSET=1 are bench knobs: hop between overlapping windows, and an extra
        /// window aligned to a loudness jump (a nearby voice starting over continuous background speech).
        let hop = Int(ProcessInfo.processInfo.environment["BENCH_HOP"] ?? "") ?? 40_000
        let onsetEnabled = ProcessInfo.processInfo.environment["BENCH_ONSET"] == "1"
        var ring = [Float](repeating: 0, count: 16_000 * 12)
        var written = 0, silence = 0, cursor = 0
        var speaking = false
        var recent: [Double] = [], longPower = 0.0, above = 0, refractoryUntil = 0
        var pendingOnset: Int?
        var onsets = 0

        mutating func append(_ frame: [Float], speech: Bool) -> [(Int, Int)] {
            let before = written
            for s in frame { ring[written % ring.count] = s; written += 1 }
            var out: [(Int, Int)] = []
            if onsetEnabled {
                let power = frame.reduce(0.0) { $0 + Double($1 * $1) } / Double(frame.count)
                recent.append(power); if recent.count > 5 { recent.removeFirst() }
                if longPower == 0 { longPower = power }
                let ratio = 10 * log10((recent.reduce(0, +) / Double(recent.count) + 1e-10) / (longPower + 1e-10))
                above = (written > refractoryUntil && ratio > 6) ? above + 1 : 0
                if above == 8 {                                   // 160 ms clearly louder than the last ~3 s
                    pendingOnset = max(0, written - 8 * 320 - 4_800, written - ring.count)
                    refractoryUntil = written + 24_000
                    onsets += 1
                }
                longPower += (power - longPower) / 150
                if let start = pendingOnset, written - start >= window { out.append((start, start + window)); pendingOnset = nil }
            }
            if speech {
                silence = 0
                if !speaking { speaking = true; cursor = max(0, before - preRoll, written - ring.count) }
            } else { silence += frame.count }
            guard speaking else { return out }
            while written - cursor >= window {                     // speech without a pause: overlapping windows
                out.append((cursor, cursor + window))
                cursor += hop
            }
            if silence >= pause {                                  // phrase over: whatever is not yet covered
                if written - silence - cursor >= minimum - preRoll { out.append((cursor, written)) }
                if let start = pendingOnset { out.append((start, written)); pendingOnset = nil }
                speaking = false
            }
            return out
        }
        func audio(_ r: (Int, Int)) -> [Float]? {
            guard written - r.0 <= ring.count else { return nil }
            return (r.0..<r.1).map { ring[$0 % ring.count] }
        }
    }

    static func whisperV2(_ samples: [Float], model: WakeModel) async throws -> [String: Any] {
        guard let vad = fvad_new() else { throw EarsError.noAudioFormat }
        defer { fvad_free(vad) }
        fvad_set_mode(vad, 3); fvad_set_sample_rate(vad, 16_000)
        var gate = SlidingGate()
        var queue: [[Float]] = [], starts: [(Int, Int)] = []
        var checks: [[String: Any]] = []
        var dropped = 0
        var i = 0
        func feed(_ count: Int) {
            var left = count
            while left > 0, i + 320 <= samples.count {
                let frame = Array(samples[i..<(i + 320)]); i += 320; left -= 320
                let pcm = frame.map { Int16(max(-32_768, min(32_767, $0 * 32_768))) }
                let speech = pcm.withUnsafeBufferPointer { fvad_process(vad, $0.baseAddress, 320) == 1 }
                for r in gate.append(frame, speech: speech) {
                    guard let audio = gate.audio(r) else { continue }
                    queue.append(audio); starts.append(r)
                    if queue.count > 2 { queue.removeFirst(); starts.removeFirst(); dropped += 1 }
                }
            }
            if count > 0, i + 320 > samples.count { i = samples.count }
        }
        while i < samples.count || !queue.isEmpty {
            if queue.isEmpty { feed(320); continue }
            let audio = queue.removeFirst(), r = starts.removeFirst()
            let t = now()
            let text = try await model.recognize(audio + [Float](repeating: 0, count: 8_000))
            let dt = now() - t
            checks.append(["t": Double(i) / 16_000, "from": Double(r.0) / 16_000, "to": Double(r.1) / 16_000, "secs": dt, "text": text])
            feed(Int(dt * 16_000))
        }
        return ["checks": checks, "dropped": dropped, "onsets": gate.onsets]
    }

    // MARK: Apple dictation — continuous, final segments with word timings

    static func apple(_ path: String) async throws -> [String: Any] {
        let locale = Locale(identifier: "ru-RU")
        let transcriber = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [],
                                               reportingOptions: [.frequentFinalization], attributeOptions: [.audioTimeRange])
        try await Dictation.ensureModel(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let context = AnalysisContext()
        context.contextualStrings[.general] = ["Чилк"]
        try? await analyzer.setContext(context)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw EarsError.noAudioFormat }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        struct Word: Sendable { let w: String; let start: Double; let end: Double }
        struct Segment: Sendable { let start: Double; let end: Double; let text: String; let words: [Word] }
        let collector = Task { () -> [Segment] in
            var segments: [Segment] = []
            for try await result in transcriber.results where result.isFinal {
                var words: [Word] = []
                for run in result.text.runs {
                    let piece = String(result.text[run.range].characters)
                    if let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] {
                        words.append(Word(w: piece, start: range.start.seconds, end: range.end.seconds))
                    }
                }
                segments.append(Segment(start: result.range.start.seconds, end: result.range.end.seconds,
                                        text: String(result.text.characters), words: words))
            }
            return segments
        }
        let analysis = Task {
            if let last = try await analyzer.analyzeSequence(stream) { try await analyzer.finalizeAndFinish(through: last) }
            else { await analyzer.cancelAndFinishNow() }
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else { throw EarsError.noAudioFormat }
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate)          // 1 s
        while file.framePosition < file.length {
            guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
            try file.read(into: input, frameCount: chunk)
            if input.frameLength == 0 { break }
            let capacity = AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / input.format.sampleRate + 64)
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { break }
            final class Once: @unchecked Sendable { var used = false }
            let once = Once()
            nonisolated(unsafe) let source = input
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if once.used { status.pointee = .noDataNow; return nil }
                once.used = true; status.pointee = .haveData; return source
            }
            if let error { throw error }
            continuation.yield(AnalyzerInput(buffer: output))
            await Task.yield()
        }
        continuation.finish()
        try await analysis.value
        let segments = try await collector.value
        return ["segments": segments.map { seg -> [String: Any] in
            ["start": seg.start, "end": seg.end, "text": seg.text,
             "words": seg.words.map { ["w": $0.w, "start": $0.start, "end": $0.end] as [String: Any] }]
        }]
    }
}
