import AppKit
import ChilkCore
import ChilkEars

/// «Чилк, …» / hotkey → he hops out with his ears up, live text while you speak (Apple dictation, В30 step 3),
/// a thinking pose while Codex answers, then the answer appears word by word in his bubble.
@MainActor
final class Conversation {
    enum Phase { case idle, listening, thinking, answering }

    private(set) var phase: Phase = .idle
    var isActive: Bool { phase != .idle }
    /// Called when the stage is free again (balance shows its prompt again).
    var onEnd: (() -> Void)?
    /// Minimal context for Codex (В24): time and how long the user has been sitting.
    var context: () -> String = { "" }
    /// Local debug log (CHILK_BALANCE_LOG), never sent anywhere.
    var log: (String) -> Void = { _ in }
    /// CHILK_EARS_FILE=/path.wav: «hear» a recording instead of the microphone (demo / acceptance without a person).
    private let earsFile = ProcessInfo.processInfo.environment["CHILK_EARS_FILE"].map { URL(fileURLWithPath: $0) }

    private let sim: CharacterSim
    private let brain: Brain
    private let mic = Microphone()
    private var dictation: Dictation?
    private var detector = EndOfSpeech(start: 0)
    private var poll: Timer?
    private var task: Task<Void, Never>?
    private var endTimer: Timer?
    private let heard = Latest()
    private let answer = Latest()
    private var dots = 0

    /// Latest text from a background callback, read by the UI timer (keeps updates in order).
    final class Latest: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ("", false, 0)
        private var level: Float = 0
        func set(_ text: String, final: Bool = false) { lock.withLock { value = (text, final, value.2 + 1) } }
        func get() -> (text: String, final: Bool, version: Int) { lock.withLock { value } }
        func setLevel(_ l: Float) { lock.withLock { level = l } }
        var currentLevel: Float { lock.withLock { level } }
        func reset() { lock.withLock { value = ("", false, 0); level = 0 } }
    }

    init(sim: CharacterSim, brain: Brain) {
        self.sim = sim
        self.brain = brain
    }

    /// Hotkey / Dock: start listening; while listening — «I'm done»; while answering — stop.
    func trigger() {
        switch phase {
        case .idle: start()
        case .listening: finishListening()
        case .thinking, .answering: cancel()
        }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func start() {
        endTimer?.invalidate()
        if let problem = brain.problem {
            sim.call(line: problem)
            return
        }
        phase = .listening
        heard.reset()
        answer.reset()
        sim.call(line: Lines.listening)
        sim.say(Lines.listening, duration: .infinity)
        sim.standOut = .out
        sim.listening = true
        detector = EndOfSpeech(start: now)
        let dictation = Dictation()
        self.dictation = dictation
        let heard = self.heard
        task = Task {
            guard await Microphone.requestAccess() else { return finish(saying: Lines.noMicrophone) }
            do {
                try await dictation.start { text, isFinal in heard.set(text, final: isFinal) }
                guard phase == .listening else { return await dictation.cancel() }
                detector = EndOfSpeech(start: now)          // the clock starts when the microphone is really on
                if let earsFile {
                    try await dictation.play(file: earsFile, realtime: true)
                } else {
                    try mic.start { buffer, level in
                        dictation.feed(buffer)
                        heard.setLevel(level)
                    }
                }
            } catch {
                finish(saying: Lines.earsFailed)
            }
        }
        poll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private var lastHeardVersion = 0, lastAnswerVersion = 0

    private func tick() {
        switch phase {
        case .listening:
            let h = heard.get()
            if h.version != lastHeardVersion {
                lastHeardVersion = h.version
                detector.heard(h.text, isFinal: h.final, at: now)
                if !h.text.isEmpty { sim.updateBubble(h.text) }
            }
            sim.hearing = Double(heard.currentLevel)
            switch detector.verdict(at: now) {
            case .keepListening: break
            case .nothingHeard: stopEars(); finish(saying: Lines.didntHear)
            case .done, .tooLong: finishListening()
            }
        case .thinking:
            let a = answer.get()
            if a.version != lastAnswerVersion, !a.text.isEmpty {
                phase = .answering
                sim.stopAct()
            } else {
                dots = (dots + 1) % 12
                sim.updateBubble(String(repeating: "·", count: dots / 4 + 1))
            }
            fallthrough
        case .answering:
            let a = answer.get()
            if a.version != lastAnswerVersion, !a.text.isEmpty {
                lastAnswerVersion = a.version
                sim.updateBubble(a.text)
            }
        case .idle:
            poll?.invalidate()
        }
    }

    private func finishListening() {
        guard phase == .listening else { return }
        phase = .thinking
        sim.listening = false
        sim.hearing = 0
        sim.perform(.think(seconds: 90))
        sim.updateBubble("·")
        let answer = self.answer
        task?.cancel()
        task = Task {
            mic.stop()
            await dictation?.finish()
            let question = EndOfSpeech.stripAddress(heard.get().text)
            log("heard «\(question)»")
            guard !question.isEmpty else { return finish(saying: Lines.didntHear) }
            let asked = ProcessInfo.processInfo.systemUptime
            do {
                let reply = try await brain.ask(context() + question) { partial in answer.set(partial) }
                answer.set(reply)
                log(String(format: "answer in %.2f s: «%@»", ProcessInfo.processInfo.systemUptime - asked, reply))
                guard phase != .idle else { return }
                tick()
                finish(saying: nil, readingTime: 2.5 + Double(reply.count) / 14)
            } catch is CancellationError {
                finish(saying: nil)
            } catch {
                log("brain error: \(error)")
                guard phase != .idle else { return }
                finish(saying: Lines.brainFailed)
            }
        }
    }

    private func stopEars() {
        mic.stop()
        let d = dictation
        Task { await d?.cancel() }
    }

    func cancel() {
        guard phase != .idle else { return }
        let wasThinking = phase == .thinking || phase == .answering
        task?.cancel()
        stopEars()
        if wasThinking { Task { await brain.interrupt() } }
        finish(saying: Lines.okNevermind)
    }

    /// Back to the edge after the answer has been read (or with a short line).
    private func finish(saying line: String?, readingTime: Double = 3) {
        phase = .idle
        poll?.invalidate()
        sim.listening = false
        sim.hearing = 0
        sim.stopAct()
        if let line { sim.say(line, duration: readingTime) }
        endTimer?.invalidate()
        endTimer = Timer.scheduledTimer(withTimeInterval: readingTime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .idle else { return }
                self.sim.clearBubble()
                self.sim.standOut = .docked
                self.onEnd?()
            }
        }
    }
}
