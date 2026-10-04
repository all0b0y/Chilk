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
