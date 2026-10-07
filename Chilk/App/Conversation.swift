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
    /// A Codex emotion of this turn waits for the words (6c, revised at acceptance): taken once the reply shows.
    var takeEmote: () -> QueuedEmote? = { nil }
    var playEmote: (Emotion, Bool) -> Void = { _, _ in }
    /// Called when the stage is free again (balance shows its prompt again).
    var onEnd: (() -> Void)?
    /// «Лежит» (slice 6b): a ready line instead of listening — no Codex. `nil` = he talks.
    var refusal: () -> String? = { nil }
    /// Minimal context for Codex (В24): time and how long the user has been sitting.
    var context: () -> String = { "" }
    /// Local debug log (CHILK_BALANCE_LOG), never sent anywhere.
    var log: (String) -> Void = { _ in }
    /// His window on screen and whether he lives on the left edge: the long-answer panel opens beside him.
    var chilkFrame: () -> (frame: NSRect, onLeftEdge: Bool) = { (.zero, false) }

    private let sim: CharacterSim
    private let brain: Brain
    private let ears: Ears
    private let answerPanel = AnswerPanel()
    /// The whole reply while the bubble shows only its start with «Подробнее» (decision 2026-10-05).
    private var longAnswer: String?
    private var listeningGeneration = 0
    private var stripWakeAddress = false
    /// Whisper's text after «Чилк» from the wake check (decision 2026-10-05, MVP); nil = the hotkey / a follow-up.
    private var heardInCheck: String?
    private var suppressFollowUps = false
    private var dictation: Dictation?
    private var detector = EndOfSpeech(start: 0)
    private var lastVoiceSeen: TimeInterval = -.infinity
    private var window: TimeInterval?
    private var poll: Timer?
    private var earsTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    private var endTimer: Timer?
    private var closing = false
    private var heard = Latest()
    private var answer = Latest()
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

    init(sim: CharacterSim, brain: Brain, ears: Ears) {
        self.sim = sim
        self.brain = brain
        self.ears = ears
        ears.onLevel = { [weak self] level in self?.heard.setLevel(level) }
    }

    // MARK: The chat (slice 5b)

    /// A voice turn finished: question (as heard), answer, the thread — it goes to the chat as text (decision 10).
    var onTurn: ((String, String, String) -> Void)?

    /// He hears, thinks or answers by voice right now: a typed question waits.
    var voiceBusy: Bool { phase == .listening || phase == .thinking || phase == .answering }

    /// Slice 6c: Codex may show an emotion now — he is thinking and no tool question is on screen.
    var canEmote: Bool { phase == .thinking && question == nil && !closing }

    /// The user started typing while he waited for a spoken follow-up: the wait closes quietly, the text goes to
    /// the same thread («Решено по умолчанию»).
    func yieldToChat() {
        guard phase == .waiting else { return }
        log("follow-up closed by the chat")
        leave(saying: nil, after: 0.2)
    }

    // MARK: Controls

    func trigger() {
        if phase == .idle, !closing, let line = refusal() { return leave(saying: line, after: 3.5) }
        if phase == .idle { suppressFollowUps = false }
        perform(Dialogue.hotkey(phase))
    }

    func wake() {
        guard phase == .idle, !closing else { return }
        if let line = refusal() { return leave(saying: line, after: 3.5) }
        suppressFollowUps = false
        closeLongAnswer()
        if let problem = brain.problem { return leave(saying: problem, after: 4) }
        turns = 0
        sim.call(line: Lines.listening)
        listen(window: nil, replayWake: true)
    }

    /// A deliberate mute stops listening NOW, and prevents an answer from reopening the microphone.
    func muteEars() {
        suppressFollowUps = true
        if phase == .listening || phase == .waiting { perform(.leaveQuietly) }
    }

    /// A click on Чилк. `false` = not about the conversation (the balance gets it).
    func clicked() -> Bool {
        guard let command = Dialogue.click(phase) else { return false }
        perform(command)
        return true
    }

    /// A button under his bubble. `false` = not ours (the balance gets it).
    func pressedButton(_ index: Int) -> Bool {
        if question != nil { settleQuestion(index); return true }
        guard index == 0, let longAnswer else { return false }
        let place = chilkFrame()
        log("long answer opened")
        answerPanel.show(longAnswer, beside: place.frame, onLeftEdge: place.onLeftEdge)
        return true
    }

    /// The bubble shows what fits; a longer reply gets «Подробнее» → the panel with all of it.
    private func showReply(_ text: String) {
        let preview = Dialogue.preview(text)
        sim.updateBubble(preview.text)
        longAnswer = preview.isCut ? text : nil
        sim.setBubbleButtons(preview.isCut ? [Lines.more] : [])
        // Acceptance helper (like CHILK_DEMO_TALK): «press» Подробнее after 2 s.
        if preview.isCut, ProcessInfo.processInfo.environment["CHILK_DEMO_MORE"] != nil {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.pressedButton(0) }
            }
        }
    }

    private func closeLongAnswer() {
        longAnswer = nil
        answerPanel.close()
    }

    private func perform(_ command: DialogueCommand) {
        log("\(phase) → \(command)")
        switch command {
        case .startListening:
            if let problem = brain.problem { return sim.call(line: problem) }
            endTimer?.invalidate()
            closing = false
            turns = 0
            closeLongAnswer()
            sim.call(line: Lines.listening)
            listen(window: nil)
        case .doneTalking:
            finishListening()
        case .leaveQuietly:
            stopEars()
            leave(saying: nil, after: 0.2)
        case .interruptAndListen:
            settleQuestion(nil)
            answerTask?.cancel()
            Task { await brain.interrupt() }
            sim.stopAct()
            sim.updateBubble(Lines.listening)
            listen(window: Dialogue.followUpWindow(mode: .question, replyLength: 0))
        case .cancel:
            settleQuestion(nil)
            answerTask?.cancel()
            stopEars()
            Task { await brain.interrupt() }
            leave(saying: Lines.okNevermind, after: 2.5)
        }
    }

    // MARK: A question from a tool («Можно я загляну…?», decision 2026-10-05)

    private var question: CheckedContinuation<Int?, Never>?
    private var questionTimer: Timer?

    /// While Codex is thinking, a tool asks the user: the bubble shows `text` with `buttons` until one is pressed
    /// (its index), `timeout` passes or the conversation ends (`nil`). Buttons only — a spoken «да» is not an answer.
    func ask(_ text: String, buttons: [String], timeout: TimeInterval) async -> Int? {
        guard phase == .thinking, question == nil else { return nil }
        sim.stopAct()
        sim.say(text, duration: .infinity, buttons: buttons)
        log("asked the user «\(text)» (\(buttons.count) buttons)")
        // Acceptance helper (like CHILK_DEMO_MORE): «press» button N after 2 s through the same path as a click.
        if let demo = ProcessInfo.processInfo.environment["CHILK_DEMO_ANSWER"].flatMap(Int.init) {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.pressedButton(demo) }
            }
        }
        return await withCheckedContinuation { continuation in
            question = continuation
            questionTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.settleQuestion(nil) }
            }
        }
    }

    private func settleQuestion(_ index: Int?) {
        guard let pending = question else { return }
        question = nil
        questionTimer?.invalidate()
        questionTimer = nil
        log("question answered: \(index.map(String.init) ?? "none")")
        if phase == .thinking {
            sim.setBubbleButtons([])
            sim.perform(.think(seconds: 120))
            sim.updateBubble("·")
        }
        pending.resume(returning: index)
    }

    // MARK: Listening

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// - Parameter window: `nil` = the first question (7 s of silence → «Не расслышал»);
    ///   otherwise a follow-up: silence for `window` seconds → he leaves quietly.
    private func listen(window: TimeInterval?, replayWake: Bool = false) {
        listeningGeneration += 1
        let generation = listeningGeneration
        stripWakeAddress = replayWake
        let wake: WakeHeard?
        do { wake = try ears.prepareListening(replayWake: replayWake) }
        catch { return leave(saying: Lines.didntHear, after: 3) }
        heardInCheck = wake?.request
        if wake?.amidSpeech == true {
            // A follow-up window would hear the same TV and send it to Codex: answer once; «Чилк» again for more.
            suppressFollowUps = true
            log("wake amid speech: no follow-up")
        }
        phase = window == nil ? .listening : .waiting
        self.window = window
        heard = Latest()
        lastHeardVersion = 0
        lastVoiceSeen = now
        if let wake, wake.wholePending {
            // Slice 8b (decision 17): out at once with «Слушаю…»; amid a TV the request is the whole phrase as Whisper
            // heard it (the early clip may end mid-word, Apple would dictate the TV), as before the early check.
            dictation = nil
            sim.standOut = .out
            sim.listening = true
            sim.earsDroop = 0
            sim.say(Lines.listening, duration: .infinity)
            if !wake.request.isEmpty { sim.updateBubble(request("")) }
            log("early wake amid speech: waiting for the whole phrase")
            // The gate checks the phrase at most 5 s after it began; 8 s without an answer = the ears are stuck.
            let deadline = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, generation == self.listeningGeneration, self.phase == .listening else { return }
                    self.log("whole phrase: no answer in 8 s")
                    self.stopEars()                               // suspends the input: the wait ends as cancelled
                }
            }
            earsTask = Task {
                let whole = await ears.wholePhrase()
                deadline.invalidate()
                guard generation == listeningGeneration, !Task.isCancelled, phase == .listening else { return }
                switch whole {
                case .heard(let text?): heardInCheck = text
                case .heard(nil): break                           // no name in the whole phrase: the early request stands
                case .cancelled: heardInCheck = nil
                }
                if heardInCheck?.isEmpty != false { stopEars(); return leave(saying: Lines.didntHear, after: 3) }
                startPoll()
                finishListening()
            }
            return
        }
        if let wake, wake.amidSpeech, !wake.request.isEmpty {
            // Bench 3c part 3: amid other speech Apple keeps dictating the TV after the request (1/22 requests right
            // at 15 dB). Whisper already heard the request: ask with it, without listening on.
            dictation = nil
            sim.standOut = .out
            startPoll()
            return finishListening()
        }
        sim.standOut = .out
        sim.listening = true
        sim.earsDroop = 0
        if window == nil { sim.say(Lines.listening, duration: .infinity) }      // a follow-up keeps his answer visible
        if heardInCheck?.isEmpty == false { sim.updateBubble(request("")) }
        detector = freshDetector()
        let dictation = Dictation()
        self.dictation = dictation
        let heard = self.heard
        let file = !replayWake && earsFiles?.isEmpty == false ? earsFiles!.removeFirst() : nil
        let silentDemo = earsFiles != nil && file == nil                         // demo ran out of recordings
        earsTask = Task {
            do {
                if replayWake || earsFiles == nil { try await ears.captureForDictation() }
                try await dictation.start { text, isFinal in heard.set(text, final: isFinal) }
                guard generation == listeningGeneration, !Task.isCancelled,
                      phase == .listening || phase == .waiting else { return await dictation.cancel() }
                try ears.attach(dictation)
                detector = freshDetector()                  // the clock starts when the microphone is really on
                if let file {
                    try await dictation.play(file: file, realtime: true)
                } else if silentDemo { log("follow-up demo silence") }
            } catch {
                guard generation == listeningGeneration, !Task.isCancelled else { return }
                if case EarsError.microphoneDenied = error { leave(saying: Lines.noMicrophone, after: 4) }
                else { leave(saying: Lines.earsFailed, after: 3) }
            }
        }
        startPoll()
    }

    private func startPoll() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// What he will be asked: after a voice wake, without the address (and starting with what Whisper heard).
    private func request(_ dictated: String) -> String {
        stripWakeAddress ? WakePhrase.request(heardInCheck: heardInCheck, dictated: dictated) : dictated
    }

    /// A request Whisper already heard counts as speech: silence after it means he can answer.
    private func freshDetector() -> EndOfSpeech {
        var d = EndOfSpeech(start: now)
        if let window { d.nothingHeardAfter = window; d.maxDuration = window + 45 }
        if heardInCheck?.isEmpty == false { d.heard(request(""), isFinal: false, at: now) }
        return d
    }

    private func tick() {
        switch phase {
        case .listening, .waiting:
            let h = heard.get()
            if h.version != lastHeardVersion {
                lastHeardVersion = h.version
                let text = request(h.text)
                detector.heard(text, isFinal: h.final, at: now)
                if !text.isEmpty {
                    if phase == .waiting {                                       // the follow-up has begun
                        phase = .listening
                        longAnswer = nil
                        sim.setBubbleButtons([])
                    }
                    sim.earsDroop = 0
                    sim.updateBubble(text)
                }
            }
            sim.hearing = Double(heard.currentLevel)
            // Slice 8b (decision 1): «э-э-э» — a voice without new words — makes him wait longer.
            if ears.lastVoiceAt > lastVoiceSeen {
                lastVoiceSeen = ears.lastVoiceAt
                detector.voice(at: lastVoiceSeen)
            }
            if phase == .waiting, let window { sim.earsDroop = (now - detector.started) / window }
            else if phase == .listening, let waited = detector.waited(at: now) {
                // While he waits for the end of the phrase his ears slowly drop (after the first half second).
                let pause = detector.pause
                sim.earsDroop = max(0, (waited * pause - 0.5) / (pause - 0.5))
            }
            switch detector.verdict(at: now) {
            case .keepListening: break
            case .nothingHeard where window != nil: perform(.leaveQuietly)
            case .nothingHeard: stopEars(); leave(saying: Lines.didntHear, after: 3)
            case .done, .tooLong: finishListening()
            }
        case .thinking:
            if question != nil { return }                          // the question stays until answered
            if !Dialogue.partialReply(answer.get().text).isEmpty {
                phase = .answering
                sim.stopAct()
                return tick()
            }
            if sim.act == nil { sim.perform(.think(seconds: 120)) }  // the emotion is over, the answer is not yet
            dots = (dots + 1) % 12
            sim.updateBubble(String(repeating: "·", count: dots / 4 + 1))
        case .answering:
            let a = answer.get()
            if a.version != lastAnswerVersion {
                lastAnswerVersion = a.version
                let text = Dialogue.plain(Dialogue.partialReply(a.text))
                if !text.isEmpty { sim.updateBubble(Dialogue.preview(text).text) }
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
        answer = Latest()
        lastAnswerVersion = 0
        let answer = self.answer
        let dictation = self.dictation
        let heard = self.heard
        let stripWake = stripWakeAddress
        let heardInCheck = self.heardInCheck
        ears.stopListening()
        earsTask?.cancel()
        answerTask = Task {
            await dictation?.finish()
            guard !Task.isCancelled else { return }
            var question = stripWake ? WakePhrase.request(heardInCheck: heardInCheck, dictated: heard.get().text)
                                     : EndOfSpeech.stripAddress(heard.get().text)
            // Acceptance helper for tool flows (with CHILK_EARS_FILE): the words, without dictation's guesses.
            if let demo = ProcessInfo.processInfo.environment["CHILK_DEMO_HEARD"], !demo.isEmpty { question = demo }
            log("heard «\(question)»")
            guard !question.isEmpty else {
                return wasFollowUp ? leave(saying: nil, after: 0.2) : leave(saying: Lines.didntHear, after: 3)
            }
            let asked = now
            do {
                defer { ClockCheck.turnEnded(.voice) }
                let raw = try await brain.ask(ClockCheck.question(question, context: context(), channel: .voice) + question) { partial in
                    answer.set(partial)
                }
                guard !Task.isCancelled, phase == .thinking || phase == .answering else { _ = takeEmote(); return }
                let reply = Dialogue.parse(raw.text)
                let text = Dialogue.plain(reply.reply)
                turns += 1
                log(String(format: "turn %d in %.1f s: [%@] «%@»", turns, now - asked, reply.mode.rawValue, text))
                onTurn?(question, text, raw.thread)
                phase = .answering
                sim.stopAct()
                showReply(text)
                if let q = takeEmote() {
                    // The words first — they explain the reaction — then the emotion 0.2 s after they are all on
                    // screen; the bubble stays over him while it plays (acceptance 2026-10-06, decision 11 revised).
                    try? await Task.sleep(for: .seconds(sim.bubbleRevealLeft + 0.2))
                    guard !Task.isCancelled, phase == .answering else { return }
                    playEmote(q.emotion, q.strong)
                    try? await Task.sleep(for: .seconds(q.seconds))
                    guard !Task.isCancelled, phase == .answering else { return }
                }
                if !suppressFollowUps, let window = Dialogue.followUpWindow(mode: reply.mode, replyLength: text.count) {
                    listen(window: window)
                } else {
                    leave(saying: nil, after: Dialogue.readingTime(text.count))
                }
            } catch {
                guard !Task.isCancelled, phase != .idle else { return }
                log("brain error: \(error)")
                _ = takeEmote()
                leave(saying: Lines.brainFailed, after: 3.5)
            }
        }
    }

    private func stopEars() {
        listeningGeneration += 1
        ears.stopListening()
        earsTask?.cancel()
        let d = dictation
        Task { await d?.cancel() }
    }

    /// 6d (acceptance 2026-10-06): «спрячься» by voice — no answer and no follow-up window; he hides at once.
    func endForHide() {
        guard phase == .thinking, !closing else { return }
        log("hide asked by voice: no answer, the conversation ends now")
        answerTask?.cancel()
        Task { await brain.interrupt() }
        leave(saying: nil, after: 0.05)
    }

    /// Back to the edge after `after` seconds (the farewell / last answer stays readable until then).
    private func leave(saying line: String?, after seconds: Double) {
        settleQuestion(nil)
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
                self.closeLongAnswer()
                self.sim.clearBubble()
                self.sim.standOut = .docked
                self.log("conversation over after \(self.turns) turn(s)")
                self.onEnd?()
            }
        }
    }
}
