import AppKit
import ChilkBrain
import ChilkCore
import ChilkEars
import SwiftUI

/// Slice 5b (SPEC «Срез 5», decisions 2, 10–15, 17): the chat window. Voice and text are one conversation on the
/// shared thread; a typed question is answered only here while Chilk «thinks» at the edge without a bubble.
@MainActor
final class ChatController: NSObject, NSWindowDelegate {
    private let store: ChatStore
    private let brain: Brain
    private let conversation: Conversation
    private let ears: Ears
    private let sim: CharacterSim
    let model = ChatModel()
    private var window: NSWindow?
    /// Chips of the turns in flight, by Codex thread.
    private var chips: [String: [ChatChip]] = [:]
    /// The next typed question starts a clean thread even within 15 minutes (acceptance «@new»).
    private var freshNext = false
    private var dictation: Dictation?
    /// The microphone is finishing (its last words may still arrive): no second start or stop meanwhile.
    private var micStopping = false
    /// Words still arriving go into the field (`false` once the field was sent or the microphone cancelled).
    private var micKeepsWords = true
    private var micPoll: Timer?
    private var lastDraftChange = Date()
    /// The chat the shared thread wrote to last: the window follows it unless the user is reading another one.
    private var lastLiveChat: UUID?
    private var openTimer: Timer?
    /// Only the acceptance script (CHILK_DEMO_CHAT) may use «@new» / «@oldest».
    private var demoMode = false

    /// Slice 8c: confirmation cards — a typed «да / нет» answers the card here, without Codex.
    weak var cards: CardDesk? {
        didSet { refreshCard() }
    }

    /// The card on screen, mirrored here (the desk calls it on every change).
    func refreshCard() {
        guard let card = cards?.current else {
            model.card = nil
            model.cardEdit = nil
            return
        }
        let shown = ChatCard(id: card.id, lines: card.lines(now: Date()), buttons: cards?.buttons(card) ?? [])
        if model.card != shown {
            if model.card?.id != card.id { model.cardEdit = nil }
            model.card = shown
            model.cardNote = nil
        }
    }

    /// A typed «да» waits for the write: the pair goes into the chat with its result, not with «Делаю…».
    private var confirmingWords: [UUID: String] = [:]

    /// The result of a card answered anywhere (edge, voice, chat): into the chat after a typed «да», else a note.
    func cardResult(_ id: UUID, _ line: String) {
        guard let words = confirmingWords.removeValue(forKey: id) else { model.cardNote = line; return }
        let id = store.recordLocal(question: words, answer: line, via: .text,
                                   continuing: model.selected.flatMap { store.log.session($0)?.id })
        lastLiveChat = id
        model.selected = id
    }

    /// [контекст] for a turn (time, sitting time, name).
    var context: () -> String = { "" }
    /// Chilk is free at the edge for the «thinking» pose (no bubble, no break, not in the popover).
    var chilkFree: () -> Bool = { false }
    /// «Лежит» (slice 6b): the ready line that answers instead of Codex. `nil` = a normal turn.
    var refusal: () -> String? = { nil }
    var log: (String) -> Void = { _ in }
    /// A typed question is being answered: the balance waits, like for a conversation.
    private(set) var thinking = false
    /// Slice 6c: this turn has Chilk thinking at the edge, so an emotion from Codex can play there.
    private(set) var posing = false

    /// Codex may show an emotion now: Chilk still thinks at the edge (no bubble came up meanwhile).
    /// A Codex emotion of this turn waits for the words (6c, revised at acceptance).
    var takeEmote: () -> QueuedEmote? = { nil }
    var playEmote: (Emotion, Bool) -> Void = { _, _ in }

    var canEmote: Bool {
        guard posing, thinking, !sim.isTalking else { return false }
        if let act = sim.act, case .think = act { return true }
        return sim.act == nil                 // review 9e: the 60-s thinking pose may be over on a long turn
    }

    init(store: ChatStore, brain: Brain, conversation: Conversation, ears: Ears, sim: CharacterSim) {
        self.store = store
        self.brain = brain
        self.conversation = conversation
        self.ears = ears
        self.sim = sim
        super.init()
        store.onChange.append { [weak self] in self?.refresh() }
        wire()
        refresh()
    }

    // MARK: Turns

    func chip(_ chip: ChatChip, thread: String) { chips[thread, default: []].append(chip) }

    /// A turn starts on `thread`: what an unfinished turn left there (an error, an interrupted voice turn) is not its.
    func turnStarted(_ thread: String) { chips[thread] = nil }

    /// A typed turn ended: a break asked for in it starts now (like after a conversation).
    var onTurnEnd: () -> Void = {}

    /// Slice 9b (decision 11): a plan collected in the chat — 20 s without typing asks «Это всё?», 20 s more shows its
    /// card. Typing (a non-empty field) holds the count.
    var planCollecting: () -> Bool = { false }
    var planSilence: () -> Bool = { false }
    private var planTimer: Timer?
    private var planAsked = false
    private var planQuietSince = Date()

    private func armPlan() {
        planTimer?.invalidate()
        planTimer = nil
        planAsked = false
        planQuietSince = Date()
        guard planCollecting() else { return }
        planTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.planTick() }
        }
    }

    private func planTick() {
        guard planCollecting() else { planTimer?.invalidate(); planTimer = nil; return }
        if model.pending != nil || !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { planQuietSince = Date(); return }
        guard Date().timeIntervalSince(planQuietSince) >= Dialogue.planSilence else { return }
        planQuietSince = Date()
        if !planAsked {
            planAsked = true
            let id = store.recordLocal(question: "", answer: PlanLines.allDone, via: .text,
                                       continuing: model.selected.flatMap { store.log.session($0)?.id })
            lastLiveChat = id
            model.selected = id
            log("chat: plan silence — «это всё?»")
        } else {
            planTimer?.invalidate()
            planTimer = nil
            planAsked = false
            log(planSilence() ? "chat: plan card after silence" : "chat: plan silence, nothing to show")
        }
    }

    /// Slice 9b (decision 13): Chilk's own line in the chat's current thread (the plan offer) — no model turn; the user's
    /// answer continues the same thread.
    func postLocal(_ line: String) {
        let id = store.recordLocal(question: "", answer: line, via: .text,
                                   continuing: model.selected.flatMap { store.log.session($0)?.id })
        lastLiveChat = id
        model.selected = id
        log("chat: Chilk's own line «\(line)»")
    }

    /// A voice turn: kept as text in the chat of its thread (decision 10, 13).
    func recordVoice(question: String, answer: String, thread: String) {
        let previous = lastLiveChat
        let id = store.record(question: question, answer: answer, via: .voice, chips: chips.removeValue(forKey: thread) ?? [],
                              thread: thread, continuing: nil)
        lastLiveChat = id
        if model.pending == nil, model.selected == nil || model.selected == previous {
            model.selected = id
        }
    }

    private func send() {
        let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, model.pending == nil else { return }
        if demoMode, text == "@new" {                            // acceptance only: as if 15 minutes passed
            model.draft = ""
            model.selected = nil
            freshNext = true
            return
        }
        if demoMode, text == "@oldest" {                         // acceptance only: pick the oldest chat
            model.draft = ""
            model.selected = store.log.sessions.last?.id
            return
        }
        if demoMode, text == "@delete" {                         // acceptance only: delete the chat on the right
            model.draft = ""
            if let id = model.selected { model.delete(id) }
            return
        }
        if demoMode, text == "@mic" {                            // acceptance only: the microphone button
            model.draft = ""
            return toggleMic()
        }
        guard !conversation.voiceBusy else { model.error = Lines.chatVoiceBusy; return }
        if let line = refusal() {
            // Lying, he does not talk (decision 8): the pair goes into the chat, nothing goes to Codex.
            model.draft = ""
            model.error = nil
            // Into the chat the user picked (not the live thread's chat), with no thread mapped to it.
            let id = store.recordLocal(question: text, answer: line, via: .text,
                                       continuing: model.selected.flatMap { store.log.session($0)?.id })
            lastLiveChat = id
            model.selected = id
            log("chat: refused while lying (\(text.count) chars), no Codex turn")
            return
        }
        if let cards, let card = cards.current, let line = { () -> String? in
            switch cards.answer(text, source: .chat) {
            case .confirming: confirmingWords[card.id] = text; return ""
            case .declined(let l), .expired(let l): return l
            case .correction: return nil
            case .unclear(let l): return l             // voice only (tech-debt pass, Д2): typed words are never cut
            }
        }() {
            // Decision 4: a typed «да» is an answer too — no Codex turn.
            model.draft = ""
            model.error = nil
            if line.isEmpty { log("chat: card confirmed by text"); return }   // the result records the pair
            let id = store.recordLocal(question: text, answer: line, via: .text,
                                       continuing: model.selected.flatMap { store.log.session($0)?.id })
            lastLiveChat = id
            model.selected = id
            log("chat: card answered by text")
            return
        }
        if let problem = brain.problem { cards?.turnEnded(.chat); model.error = problem; return }
        conversation.yieldToChat()
        stopMic(send: false)
        model.draft = ""
        model.error = nil
        model.pending = text

        // Which chat this continues (decision 12): see `ChatLog.plan`.
        let plan = store.log.plan(picked: model.selected, liveThread: brain.liveThread)
        let fresh = freshNext || plan.fresh
        freshNext = false

        thinking = true
        let pose = chilkFree()
        posing = pose
        if pose { sim.perform(.think(seconds: 60)) }              // at the edge, no bubble (decision 13)
        log("chat: typed question (\(text.count) chars)\(fresh ? ", clean thread" : "")\(plan.continuing != nil ? ", continues a chat" : "")\(pose ? "" : ", Chilk busy at the edge")")
        let cardNote = cards?.correcting == true ? cards?.context() : nil
        let base = cardNote.map { VoiceContext.adding($0, to: VoiceContext.chat(context())) } ?? VoiceContext.chat(context())
        let question = ClockCheck.question(text, context: base, channel: .chat) + text
        Task {
            defer {
                thinking = false
                posing = false
                if pose, case .think = sim.act { sim.stopAct() }  // an emotion (6c) plays to its end
                ClockCheck.turnEnded(.chat)
                cards?.turnEnded(.chat)
                onTurnEnd()
            }
            do {
                let reply = try await brain.ask(question, fresh: fresh, seed: plan.seed) { _ in }
                let answer = Dialogue.plain(Dialogue.parse(reply.text).reply)
                let id = store.record(question: text, answer: answer, via: .text, chips: chips.removeValue(forKey: reply.thread) ?? [],
                                      thread: reply.thread, continuing: plan.continuing)
                lastLiveChat = id
                model.pending = nil
                model.selected = id
                log("chat: answered «\(answer)»")
                armPlan()
                if let q = takeEmote() {
                    // 6c (revised at acceptance): the answer in a bubble at the edge first — it explains the
                    // reaction — then the emotion 0.2 s after the words are all there; the bubble stays meanwhile.
                    let words = Dialogue.preview(answer).text
                    if case .think = sim.act { sim.stopAct() }
                    let reveal = CharacterSim.revealTime(words)
                    sim.say(words, duration: reveal + 0.2 + q.seconds + Dialogue.readingTime(words.count))
                    try? await Task.sleep(for: .seconds(reveal + 0.2))
                    playEmote(q.emotion, q.strong)
                    try? await Task.sleep(for: .seconds(q.seconds))
                }
            } catch {
                model.pending = nil
                model.draft = text
                model.error = brain.problem ?? Lines.chatFailed
                _ = takeEmote()
                log("chat: brain error \(error)")
            }
        }
    }

    // MARK: Microphone in the field (decision 15)

    private func toggleMic() {
        guard !micStopping else { return }
        if dictation != nil { return stopMic(send: true) }
        guard !conversation.voiceBusy, model.pending == nil else { return }
        conversation.yieldToChat()
        let d = Dictation()
        dictation = d
        micKeepsWords = true
        model.listening = true
        let before = model.draft
        lastDraftChange = Date()
        Task {
            do {
                // Same order as a conversation: the passive ears step aside, the microphone opens, dictation attaches.
                _ = try ears.prepareListening(replayWake: false)
                try await ears.captureForDictation()
                try await d.start { [weak self] text, _ in
                    Task { @MainActor in
                        guard let self, self.dictation === d, self.micKeepsWords else { return }
                        let joined = before.isEmpty ? text : before + " " + text
                        if joined != self.model.draft { self.model.draft = joined; self.lastDraftChange = Date() }
                    }
                }
                guard dictation === d else { return await d.cancel() }
                try ears.attach(d)
                log("chat: microphone on")
            } catch {
                log("chat: microphone failed \(error)")
                model.error = Lines.chatMicFailed
                stopMic(send: false)
            }
        }
        // ~1.5 s without new words after something was said → send.
        micPoll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.dictation != nil else { return }
                if self.model.draft != before, Date().timeIntervalSince(self.lastDraftChange) > 1.5 { self.stopMic(send: true) }
            }
        }
    }

    private func stopMic(send: Bool) {
        micPoll?.invalidate()
        micPoll = nil
        guard let d = dictation, !micStopping else { return }
        micStopping = true
        micKeepsWords = send                                       // sending now: later words must not refill the field
        Task {
            // Keep `dictation` until the recogniser has handed over its final words, then let them land in the field.
            await d.finish()
            try? await Task.sleep(for: .milliseconds(150))
            dictation = nil
            micStopping = false
            model.listening = false
            ears.stopListening()
            ears.resume()
            log("chat: microphone off")
            if send { self.send() }
        }
    }

    /// The user types: a spoken follow-up he was waiting for is closed quietly («Решено по умолчанию»).
    private func typed() {
        if !model.draft.isEmpty, dictation == nil { conversation.yieldToChat() }
    }

    // MARK: Window (decision 2)

    /// Slice 9, decision 2: ⌘Q / the Dock's «Завершить» close the window (Chilk stays at the edge).
    func close() { window?.performClose(nil) }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = Lines.chatTitle
            let host = NSHostingController(rootView: ChatView(model: model))
            host.sizingOptions = [.minSize]                       // the window keeps its size; SwiftUI only sets the minimum
            w.contentViewController = host
            w.setContentSize(NSSize(width: 780, height: 560))
            w.minSize = NSSize(width: 560, height: 380)
            w.isReleasedWhenClosed = false
            w.delegate = self
            if !w.setFrameUsingName("ChilkChat") || w.frame.width < w.minSize.width || w.frame.height < w.minSize.height {
                w.setContentSize(NSSize(width: 780, height: 560))
                w.center()
            }
            w.setFrameAutosaveName("ChilkChat")
            window = w
        }
        refresh()
        if model.selected == nil { model.selected = brain.liveThread.flatMap { store.log.session(forThread: $0)?.id } }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        // Counted once from open to close; a minimised window is still open (`isVisible` is false for it).
        if !counted {
            counted = true
            WindowPolicy.opened()
        } else {
            NSApp.activate()
        }
        openTimer?.invalidate()
        openTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        log("chat window open")
    }

    func windowWillClose(_ notification: Notification) {
        stopMic(send: false)
        openTimer?.invalidate()
        openTimer = nil
        if counted {
            counted = false
            WindowPolicy.closed()
        }
        log("chat window closed")
    }

    /// This window is counted in `WindowPolicy` (open, possibly minimised).
    private var counted = false

    var isOpen: Bool { window?.isVisible == true }

    /// Acceptance only (CHILK_DEMO_CHAT): types each line once Codex is ready and waits for its answer; «@wait:N» pauses;
    /// «@do:<op>» runs an app step (slice 10: the day sheet's ✕ / «Записать» / a snapshot, the card's «Изменить»).
    var demoStep: (String) -> Void = { _ in }
    func runDemo(_ steps: [String], snapshot url: URL?) {
        demoMode = true
        Task {
            while brain.state != .ready { try? await Task.sleep(for: .milliseconds(500)) }
            show()
            try? await Task.sleep(for: .seconds(1))
            for step in steps {
                if step.hasPrefix("@wait:"), let seconds = Double(step.dropFirst(6)) {     // «@wait:40»: let time pass
                    try? await Task.sleep(for: .seconds(seconds))
                    continue
                }
                if step.hasPrefix("@do:") {                            // slice 10: «@do:x:1», «@do:record», «@do:edit»…
                    demoStep(String(step.dropFirst(4)))
                    try? await Task.sleep(for: .seconds(1.5))
                    continue
                }
                model.draft = step
                send()
                while model.pending != nil { try? await Task.sleep(for: .milliseconds(300)) }
                try? await Task.sleep(for: .seconds(1))
            }
            if let url { snapshot(to: url) }
            log("chat demo done")
        }
    }

    /// Acceptance: the window as composited on screen, to a PNG (own window: no Screen Recording needed).
    func snapshot(to url: URL) {
        guard let window else { return }
        log("chat snapshot \(url.lastPathComponent)\(WindowSnapshot.write(window, to: url) ? "" : " failed")")
    }

    // MARK: Model

    private func refresh() {
        let sessions = store.log.sessions
        if sessions != model.sessions { model.sessions = sessions }
        if let s = model.selected, !sessions.contains(where: { $0.id == s }) { model.selected = nil }
        model.voiceBusy = conversation.voiceBusy
    }

    private func tick() {
        let busy = conversation.voiceBusy
        if model.voiceBusy != busy { model.voiceBusy = busy }
    }

    private func wire() {
        model.send = { [weak self] in self?.send() }
        model.toggleMic = { [weak self] in self?.toggleMic() }
        model.delete = { [weak self] id in
            guard let self else { return }
            // Deleting deletes everything: the live thread that still holds this chat is dropped too.
            if let live = self.brain.liveThread, self.store.log.session(forThread: live)?.id == id {
                self.brain.dropLiveThread()
                self.chips[live] = nil
            }
            if self.lastLiveChat == id { self.lastLiveChat = nil }
            self.store.delete(id)
            self.log("chat deleted")
        }
        model.typed = { [weak self] in self?.typed() }
        model.cardButton = { [weak self] title in
            guard let self, let cards = self.cards, let shown = self.model.card else { return }
            if title == CardDesk.edit {
                guard let card = cards.current, card.id == shown.id else { return }
                // Slice 10: a plan is edited in «Лист дня» (its «Ещё не записано»), not in the inline fields.
                if case .plan = card.kind { cards.openEditor() } else { self.model.cardEdit = CardEditModel(card) }
                return
            }
            cards.pressedFromChat(title, card: shown.id)        // a double click cannot answer the next card
        }
        model.cardSave = { [weak self] in
            guard let self, let edit = self.model.cardEdit else { return }
            self.model.cardEdit = nil
            self.cards?.replace(edit.original.id, with: edit.edited(), how: "chat")
        }
    }
}

/// Decision 2: while a Chilk window is open the app is a regular one (Dock icon, ⌘Tab, its menu bar); after the last
/// one closes it is back to the tray only.
@MainActor
enum WindowPolicy {
    private static var open = 0

    static func opened() {
        open += 1
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
    }

    static func closed() {
        open = max(0, open - 1)
        guard open == 0 else { return }
        // After the close finishes; a window opened meanwhile keeps the app regular.
        DispatchQueue.main.async { if open == 0 { NSApp.setActivationPolicy(.accessory) } }
    }
}
