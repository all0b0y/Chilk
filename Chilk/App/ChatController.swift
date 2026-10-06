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

    /// [контекст] for a turn (time, sitting time, name).
    var context: () -> String = { "" }
    /// Chilk is free at the edge for the «thinking» pose (no bubble, no break, not in the popover).
    var chilkFree: () -> Bool = { false }
    var log: (String) -> Void = { _ in }
    /// A typed question is being answered: the balance waits, like for a conversation.
    private(set) var thinking = false

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
        if let problem = brain.problem { model.error = problem; return }
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
        if pose { sim.perform(.think(seconds: 60)) }              // at the edge, no bubble (decision 13)
        log("chat: typed question (\(text.count) chars)\(fresh ? ", clean thread" : "")\(plan.continuing != nil ? ", continues a chat" : "")")
        let question = VoiceContext.chat(context()) + text
        Task {
            defer {
                thinking = false
                if pose { sim.stopAct() }
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
            } catch {
                model.pending = nil
                model.draft = text
                model.error = brain.problem ?? Lines.chatFailed
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

    /// Acceptance only (CHILK_DEMO_CHAT): types each line once Codex is ready and waits for its answer.
    func runDemo(_ steps: [String], snapshot url: URL?) {
        demoMode = true
        Task {
            while brain.state != .ready { try? await Task.sleep(for: .milliseconds(500)) }
            show()
            try? await Task.sleep(for: .seconds(1))
            for step in steps {
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
