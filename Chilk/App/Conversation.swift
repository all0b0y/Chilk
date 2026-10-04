import AppKit
import ChilkCore
import ChilkEars

/// A spoken dialogue with Чилк (decided 2026-10-04):
/// hotkey → ears up, live text → pause → thinking → the answer streams into his bubble → he keeps listening for a
/// while (longer after his own question, shorter after «готово»; the ears droop as the window closes) →
/// a follow-up continues the same thread; silence, «спасибо, всё», the hotkey or a click end it.
@MainActor
final class Conversation {
    private(set) var phase: DialoguePhase = .idle
    /// Busy until he is back at the edge (including the farewell being read).
    var isActive: Bool { phase != .idle || closing }
    /// Called when the stage is free again (balance shows its prompt again).
    var onEnd: (() -> Void)?
    /// Minimal context for Codex (В24): time and how long the user has been sitting.
    var context: () -> String = { "" }
    /// Local debug log (CHILK_BALANCE_LOG), never sent anywhere.
    var log: (String) -> Void = { _ in }

    private let sim: CharacterSim
    private let brain: Brain
    private let mic = Microphone()
    private var dictation: Dictation?
    private var detector = EndOfSpeech(start: 0)
    private var window: TimeInterval?
    private var poll: Timer?
    private var earsTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    private var endTimer: Timer?
    private var closing = false
    private let heard = Latest()
    private let answer = Latest()
    private var lastHeardVersion = 0, lastAnswerVersion = 0
    private var dots = 0
    private var turns = 0
    /// CHILK_EARS_FILE=a.wav:b.wav — «hear» recordings instead of the microphone, one per listening (demo / acceptance).
    private var earsFiles = ProcessInfo.processInfo.environment["CHILK_EARS_FILE"]?
        .split(separator: ":").map { URL(fileURLWithPath: String($0)) }

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

    // MARK: Controls

    func trigger() {
        perform(Dialogue.hotkey(phase))
    }

    /// A click on Чилк. `false` = not about the conversation (the balance gets it).
    func clicked() -> Bool {
        guard let command = Dialogue.click(phase) else { return false }
        perform(command)
        return true
    }

    private func perform(_ command: DialogueCommand) {
        log("\(phase) → \(command)")
        switch command {
        case .startListening:
            if let problem = brain.problem { return sim.call(line: problem) }
            endTimer?.invalidate()
            closing = false
            turns = 0
            sim.call(line: Lines.listening)
            listen(window: nil)
        case .doneTalking:
            finishListening()
        case .leaveQuietly:
            stopEars()
            leave(saying: nil, after: 0.2)
        case .interruptAndListen:
            answerTask?.cancel()
            Task { await brain.interrupt() }
            sim.stopAct()
            sim.updateBubble(Lines.listening)
            listen(window: Dialogue.followUpWindow(mode: .question, replyLength: 0))
        case .cancel:
            answerTask?.cancel()
            stopEars()
            Task { await brain.interrupt() }
            leave(saying: Lines.okNevermind, after: 2.5)
        }
    }

    // MARK: Listening

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// - Parameter window: `nil` = the first question (7 s of silence → «Не расслышал»);
    ///   otherwise a follow-up: silence for `window` seconds → he leaves quietly.
    private func listen(window: TimeInterval?) {
        phase = window == nil ? .listening : .waiting
        self.window = window
        heard.reset()
        lastHeardVersion = 0
        sim.standOut = .out
        sim.listening = true
        sim.earsDroop = 0
        if window == nil { sim.say(Lines.listening, duration: .infinity) }      // a follow-up keeps his answer visible
        detector = EndOfSpeech(start: now)
        if let window {
            detector.nothingHeardAfter = window
            detector.maxDuration = window + 25
        }
        let dictation = Dictation()
        self.dictation = dictation
        let heard = self.heard
        let file = earsFiles?.isEmpty == false ? earsFiles!.removeFirst() : nil
        let silentDemo = earsFiles != nil && file == nil                         // demo ran out of recordings
        earsTask = Task {
            guard await Microphone.requestAccess() else { return leave(saying: Lines.noMicrophone, after: 4) }
            do {
                try await dictation.start { text, isFinal in heard.set(text, final: isFinal) }
                guard phase == .listening || phase == .waiting else { return await dictation.cancel() }
                detector = EndOfSpeech(start: now)          // the clock starts when the microphone is really on
                if let window { detector.nothingHeardAfter = window; detector.maxDuration = window + 25 }
                if let file {
                    try await dictation.play(file: file, realtime: true)
                } else if !silentDemo {
                    try mic.start { buffer, level in
                        dictation.feed(buffer)
                        heard.setLevel(level)
                    }
                }
            } catch {
                leave(saying: Lines.earsFailed, after: 3)
            }
        }
        if poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    private func tick() {
        switch phase {
        case .listening, .waiting:
            let h = heard.get()
            if h.version != lastHeardVersion {
                lastHeardVersion = h.version
                detector.heard(h.text, isFinal: h.final, at: now)
                if !h.text.isEmpty {
                    if phase == .waiting { phase = .listening }                  // the follow-up has begun
                    sim.earsDroop = 0
                    sim.updateBubble(h.text)
                }
            }
            sim.hearing = Double(heard.currentLevel)
            if phase == .waiting, let window { sim.earsDroop = (now - detector.started) / window }
            switch detector.verdict(at: now) {
            case .keepListening: break
            case .nothingHeard where window != nil: perform(.leaveQuietly)
            case .nothingHeard: stopEars(); leave(saying: Lines.didntHear, after: 3)
            case .done, .tooLong: finishListening()
            }
        case .thinking:
            if !Dialogue.partialReply(answer.get().text).isEmpty {
                phase = .answering
                sim.stopAct()
                return tick()
            }
            dots = (dots + 1) % 12
            sim.updateBubble(String(repeating: "·", count: dots / 4 + 1))
        case .answering:
            let a = answer.get()
            if a.version != lastAnswerVersion {
                lastAnswerVersion = a.version
                let text = Dialogue.plain(Dialogue.partialReply(a.text))
                if !text.isEmpty { sim.updateBubble(text) }
            }
        case .idle:
            poll?.invalidate()
            poll = nil
        }
    }

    // MARK: Thinking and answering

    private func finishListening() {
        guard phase == .listening || phase == .waiting else { return }
        let wasFollowUp = window != nil
        phase = .thinking
        sim.listening = false
        sim.hearing = 0
        sim.earsDroop = 0
        sim.perform(.think(seconds: 120))
        sim.updateBubble("·")
        answer.reset()
        lastAnswerVersion = 0
        let answer = self.answer
        let dictation = self.dictation
        mic.stop()
        answerTask = Task {
            await dictation?.finish()
            let question = EndOfSpeech.stripAddress(heard.get().text)
            log("heard «\(question)»")
            guard !question.isEmpty else {
                return wasFollowUp ? leave(saying: nil, after: 0.2) : leave(saying: Lines.didntHear, after: 3)
            }
            let asked = now
            do {
                let raw = try await brain.ask(context() + question) { partial in answer.set(partial) }
                guard !Task.isCancelled else { return }
                let reply = Dialogue.parse(raw)
                let text = Dialogue.plain(reply.reply)
                turns += 1
                log(String(format: "turn %d in %.1f s: [%@] «%@»", turns, now - asked, reply.mode.rawValue, text))
                phase = .answering
                sim.stopAct()
                sim.updateBubble(text)
                if let window = Dialogue.followUpWindow(mode: reply.mode, replyLength: text.count) {
                    listen(window: window)
                } else {
                    leave(saying: nil, after: Dialogue.readingTime(text.count))
                }
            } catch {
                guard !Task.isCancelled, phase != .idle else { return }
                log("brain error: \(error)")
                leave(saying: Lines.brainFailed, after: 3.5)
            }
        }
    }

    private func stopEars() {
        mic.stop()
        earsTask?.cancel()
        let d = dictation
        Task { await d?.cancel() }
    }

    /// Back to the edge after `after` seconds (the farewell / last answer stays readable until then).
    private func leave(saying line: String?, after seconds: Double) {
        phase = .idle
        closing = true
        poll?.invalidate()
        poll = nil
        stopEars()
        sim.listening = false
        sim.hearing = 0
        sim.earsDroop = 0
        sim.stopAct()
        if let line { sim.say(line, duration: seconds + 0.3) }
        endTimer?.invalidate()
        endTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .idle else { return }
                self.closing = false
                self.sim.clearBubble()
                self.sim.standOut = .docked
                self.log("conversation over after \(self.turns) turn(s)")
                self.onEnd?()
            }
        }
    }
}
