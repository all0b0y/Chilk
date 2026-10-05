import AVFoundation
import ChilkBrain
import ChilkCore
import ChilkEars
import Foundation

// chilk-voice status                 — is Чилк's Codex profile logged in?
// chilk-voice ask "текст" ["ещё"]     — real Codex turns on one warm thread, with timings
// chilk-voice hear file.wav [--fast]  — live dictation of a file through the app's code path + end of speech

let persona = """
Ты — Чилк, милый анимированный компаньон на краю экрана Mac. Говори по-русски, на «ты», коротко: 1–2 предложения, \
до 140 символов, без markdown. Тон добрый, с лёгкой подколкой. Нельзя: мат, шутки про внешность, вес и здоровье, \
стыжение, токсичная продуктивность. Не выдумывай факты.
"""

func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

func setup() throws -> CodexSetup {
    guard let codex = CodexSetup.locateCodex() else { throw CodexClient.ClientError.cannotLaunch("codex not found") }
    let s = CodexSetup(dataDir: CodexSetup.defaultDataDir, executable: codex)
    try s.prepare()
    return s
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "status":
    let s = try setup()
    let client = s.makeClient()
    try await client.start()
    let account = try await client.account()
    print("codex:", s.executable.path, "| CODEX_HOME:", s.codexHome.path)
    print(account.map { "logged in: \($0.email ?? "?") (\($0.plan ?? "?"))" } ?? "NOT logged in")
    await client.stop()

case "ask":
    let s = try setup()
    let client = s.makeClient()
    let t0 = now()
    try await client.start()
    guard try await client.account() != nil else { print("NOT logged in"); exit(1) }
    let thread = try await client.startThread(model: s.model, instructions: persona, cwd: s.workDir)
    print(String(format: "app-server + thread: %.2f s", now() - t0))
    // --json: the dialogue schema (reply + mode), printing how the reply streams out of the JSON
    let structured = args.contains("--json")
    let schema = structured ? JSON(any: Dialogue.schema) : nil
    let jsonNote = "\nОтвечай JSON: reply — реплика; mode — question (задал вопрос/ждёшь ответа), answer, done (просьба выполнена), end (пользователь прощается — reply = прощание)."
    for question in args.dropFirst() where question != "--json" {
        let start = now()
        final class First: @unchecked Sendable { var at: TimeInterval?; var partials: [String] = [] }
        let first = First()
        let answer = try await client.ask(threadId: thread, text: question + (structured ? jsonNote : ""), outputSchema: schema) { text in
            if first.at == nil { first.at = now() }
            if structured { let p = Dialogue.partialReply(text); if first.partials.last != p { first.partials.append(p) } }
        }
        print(String(format: "> %@\n< %@\n  first token %.2f s, total %.2f s", question, answer, (first.at ?? now()) - start, now() - start))
        if structured {
            let r = Dialogue.parse(answer)
            print("  parsed: mode=\(r.mode.rawValue) reply=«\(r.reply)» | streamed steps: \(first.partials.count), e.g. \(first.partials.prefix(3))")
        }
    }
    print("declined server requests:", await client.declined)
    await client.stop()

case "wake":
    guard args.count >= 3 else { print("usage: chilk-voice wake model-folder audio-folder [--json-out report.json]"); exit(2) }
    let modelFolder = URL(fileURLWithPath: args[1])
    let folder = URL(fileURLWithPath: args[2])
    let model = WakeModel()
    let base = modelFolder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let loaded = now()
    try await model.prepare(folder: modelFolder, base: base)
    print(String(format: "wake model loaded in %.2f s", now() - loaded))
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { ["wav", "aiff", "m4a"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    var rows: [[String: Any]] = []
    let dumpClips = args.contains("--dump-clips")
    for file in files {
        let input = VoiceInput(recognize: { samples in
            if dumpClips, let buffer = AudioSamples.buffer(samples) {
                let out = file.deletingLastPathComponent().appending(path: "clips/\(file.lastPathComponent)")
                try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                let writer = try AVAudioFile(forWriting: out, settings: buffer.format.settings)
                try writer.write(from: buffer)
            }
            return try await model.recognize(samples)
        })
        let expected = file.lastPathComponent.hasPrefix("A_") || file.lastPathComponent.hasPrefix("B_")
        var hit = false, wakes = 0, checks = 0, texts: [String] = [], elapsed = 0.0
        input.onCheck = { text, found, seconds in
            checks += 1; texts.append(text); elapsed += seconds
            if found { hit = true; wakes += 1 }
            if checks % 100 == 0 { print("progress: \(file.lastPathComponent) \(checks) checks, \(wakes) wakes") }
        }
        input.onError = { error in print("wake error:", error) }
        input.arm { input.suspend() }
        // Leading/trailing silence is input audio, not a transcript shortcut. The real WebRTC gate runs.
        let samples = Array(repeating: Float(0), count: 9_600) + (try AudioSamples.load(file: file)) + Array(repeating: Float(0), count: 12_800)
        for offset in stride(from: 0, to: samples.count, by: 320) {
            input.feed(Array(samples[offset..<min(offset + 320, samples.count)]))
            // Finish each recognition before continuing an offline file (real-time behaviour is exercised in the app demo).
            while input.isChecking { try await Task.sleep(for: .milliseconds(10)) }
            if input.mode == .suspended, !expected { input.arm { input.suspend() } }
        }
        let row: [String: Any] = ["file": file.lastPathComponent, "expected": expected, "hit": hit, "wakes": wakes, "checks": checks, "seconds": elapsed, "texts": texts]
        rows.append(row)
        if let flag = args.firstIndex(of: "--json-out"), flag + 1 < args.count {
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[flag + 1]))
        }
        print(String(format: "%@ %@ %d checks %.2f s | %@", hit == expected ? "PASS" : "FAIL", file.lastPathComponent, checks, elapsed, texts.joined(separator: " / ")))
    }
    if let flag = args.firstIndex(of: "--json-out"), flag + 1 < args.count {
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[flag + 1]))
    }
    let positives = rows.filter { $0["expected"] as? Bool == true }
    let negatives = rows.filter { $0["expected"] as? Bool == false }
    print("wake:", positives.filter { $0["hit"] as? Bool == true }.count, "/", positives.count,
          "false:", negatives.filter { $0["hit"] as? Bool == true }.count, "/", negatives.count)

case "bench":
    try await Bench.run(Array(args.dropFirst()))

case "hear":
    guard args.count >= 2 else { print("usage: chilk-voice hear file.wav [--fast]"); exit(2) }
    let url = URL(fileURLWithPath: args[1])
    let realtime = !args.contains("--fast")
    let dictation = Dictation()
    final class Box: @unchecked Sendable {
        var detector = EndOfSpeech(start: now())
        let lock = NSLock()
    }
    let box = Box()
    let t0 = now()
    try await dictation.start { text, isFinal in
        box.lock.withLock { box.detector.heard(text, isFinal: isFinal, at: now()) }
        print(String(format: "%6.2f s %@ %@", now() - t0, isFinal ? "FINAL" : "     ", text))
    }
    box.lock.withLock { box.detector = EndOfSpeech(start: now()) }
    try await dictation.play(file: url, realtime: realtime)
    // keep "listening" to silence until the detector decides
    var verdict = EndOfSpeech.Verdict.keepListening
    while verdict == .keepListening {
        try await Task.sleep(for: .milliseconds(100))
        verdict = box.lock.withLock { box.detector.verdict(at: now()) }
    }
    let decidedAt = now() - t0
    await dictation.finish()
    let text = box.lock.withLock { box.detector.text }
    print(String(format: "verdict %@ at %.2f s → request: «%@»", "\(verdict)", decidedAt, EndOfSpeech.stripAddress(text)))

default:
    print("usage: chilk-voice status | ask \"text\" [...] | hear file.wav [--fast]")
}
