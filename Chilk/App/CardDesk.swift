import AppKit
import ChilkBrain
import ChilkCore
import SwiftUI

/// Slice 8c (SPEC «Срез 8», decisions 3–8): confirmation cards. A tool that would write into Apple's apps or schedule
/// Chilk's message only proposes; the card shows what will really be written; «Да» writes it with the card's values
/// (the model takes no part then), «Нет» drops it, «Изменить» opens the panel, other words are a correction (a new
/// model turn with the card in [контекст]). No timeout; other bubbles may come over it, then it comes back.
@MainActor
final class CardDesk {
    enum Source: String { case edge, voice, chat, panel }

    private let sim: CharacterSim
    private(set) var queue = CardQueue()
    /// The card is in Chilk's bubble at the edge right now (not inside a conversation's bubble).
    private(set) var showing = false
    /// Another bubble took its place: when it comes back, «А карточку-то подтвердишь?».
    private var displaced = false
    /// The words of the card's bubble, to notice another bubble taking its place.
    private var shownWords: String?
    /// The conversation shows the card in its own bubble (decision 3 of the plan).
    var inConversation = false
    /// The next proposal corrects the card on screen (a correction turn is running): it takes its place.
    var correcting = false
    private var timer: Timer?
    private let panel = CardEditPanel()
    /// Counts proposals: a conversation shows the card in its bubble only if its own turn proposed one.
    private(set) var proposals = 0

    var log: (String) -> Void = { _ in }
    /// The stage is free for the card at the edge (no conversation, notice, request, popover, game, greeting…).
    var stageFree: () -> Bool = { false }
    /// His window and side: the «Изменить» panel opens beside him.
    var chilkFrame: () -> (frame: NSRect, onLeftEdge: Bool) = { (.zero, false) }
    /// After «Да»: writes the card (reminders / Chilk's message). Returns the line he says.
    var commit: (ActionCard) async -> (ok: Bool, line: String) = { _ in (false, "") }
    /// The chat mirrors the queue's first card.
    var onChange: () -> Void = {}
    /// Acceptance only (CHILK_DEMO_CARD_SNAPSHOT=/dir): the screen around him 1.5 s after a card shows.
    var snapshot: ((String) -> Void)?
    private var shots = 0
    private var demoPressed = false

    init(sim: CharacterSim) {
        self.sim = sim
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.1
    }

    var current: ActionCard? { queue.current }
    var hasCard: Bool { !queue.isEmpty }
    /// At the edge he is out for the card (balance waits like for a due notice only while it is up).
    var ownsStage: Bool { showing }

    // MARK: Proposals

    func propose(_ card: ActionCard) {
        let replacing = correcting && !queue.isEmpty
        correcting = false
        queue.add(card, replacingCurrent: replacing)
        proposals += 1
        log("card proposed\(replacing ? " (correction)" : ""): \(card.summary())")
        if showing { present(again: false) } else if inConversation { refreshInConversation() }
        onChange()
    }

    /// The conversation's bubble shows the card (its buttons route here).
    func showInConversation() {
        guard let card = current else { return }
        inConversation = true
        sim.say(text(card), duration: .infinity, buttons: buttons(card))
        if let snapshot {
            shots += 1
            let name = String(format: "card-%02d-talk", shots)
            Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in MainActor.assumeIsolated { snapshot(name) } }
        }
    }

    private func refreshInConversation() {
        guard inConversation, let card = current else { return }
        sim.say(text(card), duration: .infinity, buttons: buttons(card))
    }

    /// [контекст] for a correction turn: what the card on screen says.
    func context() -> String? {
        guard let card = current else { return nil }
        return "на экране карточка подтверждения: \(card.summary()) — пользователь её поправляет: вызови тот же инструмент "
            + "заново с исправленными значениями (новая карточка заменит эту)"
    }

    // MARK: Text and buttons

    static let yes = String(localized: "Да"), edit = String(localized: "Изменить"), no = String(localized: "Нет")

    func text(_ card: ActionCard, again: Bool = false) -> String {
        let body = card.lines(now: Date()).joined(separator: "\n")
        return again ? String(localized: "А карточку-то подтвердишь?") + "\n" + body : body
    }

    func buttons(_ card: ActionCard) -> [String] {
        var out: [String] = []
        if !card.expired(now: Date()) { out.append(Self.yes) }
        if card.editable { out.append(Self.edit) }
        out.append(Self.no)
        return out
    }

    /// A button on the chat's card (the chat edits inline itself).
    func pressedFromChat(_ index: Int) -> Bool {
        guard let card = current else { return false }
        let labels = buttons(card)
        guard labels.indices.contains(index) else { return true }
        switch labels[index] {
        case Self.yes: confirm(source: .chat)
        case Self.no: decline(source: .chat)
        default: break
        }
        return true
    }

    /// A button under the card (edge or conversation bubble). `false` = the card is not on screen.
    func pressed(_ index: Int, source: Source) -> Bool {
        guard let card = current, showing || inConversation else { return false }
        let labels = buttons(card)
        guard labels.indices.contains(index) else { return true }
        switch labels[index] {
        case Self.yes: confirm(source: source)
        case Self.edit: openEditor()
        default: decline(source: source)
        }
        return true
    }

    // MARK: Answers

    /// A spoken or typed answer while the card is up: the line he says for yes / no; nil = a correction (the caller
    /// sends it to Codex with `context()`).
    func answer(_ words: String, source: Source) -> String? {
        guard let card = current else { return nil }
        switch CardAnswer.parse(words) {
        case .yes:
            guard !card.expired(now: Date()) else { return String(localized: "Это время уже прошло — скажи другое") }
            confirm(source: source)
            return String(localized: "Делаю…")
        case .no:
            decline(source: source)
            return String(localized: "Ладно, ничего не делаю")
        case .correction:
            correcting = true
            log("card: a correction (\(source.rawValue))")
            return nil
        }
    }

    /// The result of the last «Да» (the conversation / chat shows it).
    var onResult: (String, Bool) -> Void = { _, _ in }

    private func confirm(source: Source) {
        guard let card = current, !card.expired(now: Date()) else { return }
        settle(card, how: "yes (\(source.rawValue))")
        Task {
            let result = await commit(card)
            log("card committed: ok=\(result.ok)")
            onResult(result.line, result.ok)
            guard source != .chat else { return }
            // A conversation ends first («Делаю…» stays a moment): the result comes after it, not under its close.
            if source == .voice { try? await Task.sleep(for: .seconds(1.6)) }
            sim.say(result.line, duration: 4)
        }
    }

    private func decline(source: Source) {
        guard let card = current else { return }
        settle(card, how: "no (\(source.rawValue))")
        if source == .edge || source == .panel { sim.say(String(localized: "Ладно, ничего не делаю"), duration: 2.5) }
        // By voice the conversation says it as it closes.
    }

    private func settle(_ card: ActionCard, how: String) {
        panel.close()
        queue.settle(card.id)
        log("card answered: \(how)")
        if showing { hide() }
        displaced = false
        onChange()
    }

    // MARK: «Изменить» (decision 5)

    func openEditor() {
        guard let card = current, card.editable else { return }
        let place = chilkFrame()
        log("card: edit panel opened")
        panel.show(card, beside: place.frame, onLeftEdge: place.onLeftEdge) { [weak self] edited in
            guard let self else { return }
            guard let edited else { self.log("card: edit cancelled"); return }
            self.queue.replace(card.id, with: edited)
            self.log("card edited: \(edited.summary())")
            self.onChange()
            if self.showing { self.present(again: false) } else { self.refreshInConversation() }
        }
    }

    /// The chat's own fields (decision «в чате — та же карточка с кнопками и полями»).
    func replaceCurrent(with edited: ActionCard) {
        guard let card = current else { return }
        queue.replace(card.id, with: edited)
        log("card edited in the chat: \(edited.summary())")
        onChange()
        if showing { present(again: false) }
    }

    // MARK: The edge

    private func tick() {
        guard let card = current else { return }
        if showing {
            if sim.bubbleWords != shownWords {                   // another bubble came over it
                showing = false
                displaced = true
                log("card: another bubble over it")
            } else if card.expired(now: Date()), sim.bubbleWords != nil {
                present(again: false)                             // «Да» goes away once the time has passed
            }
            return
        }
        guard !inConversation, stageFree() else { return }
        present(again: displaced)
    }

    private func present(again: Bool) {
        guard let card = current else { return }
        let words = text(card, again: again)
        sim.say(words, duration: .infinity, buttons: buttons(card))
        sim.standOut = .out
        shownWords = words
        showing = true
        displaced = false
        log("card shown\(again ? " again" : "")")
        if let snapshot {
            shots += 1
            let name = String(format: "card-%02d", shots)
            Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in MainActor.assumeIsolated { snapshot(name) } }
        }
        // Acceptance only: CHILK_DEMO_CARD_PRESS=<label> presses that button of the edge card 5 s after it shows,
        // through the same path as a click (once).
        if let label = ProcessInfo.processInfo.environment["CHILK_DEMO_CARD_PRESS"], !demoPressed {
            demoPressed = true
            Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let card = self.current, let i = self.buttons(card).firstIndex(of: label) else { return }
                    _ = self.pressed(i, source: .edge)
                    if label == Self.edit, let snapshot = self.snapshot {
                        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                            MainActor.assumeIsolated { self?.panel.snapshot(snapshot) }
                        }
                    }
                }
            }
        }
    }

    private func hide() {
        showing = false
        shownWords = nil
        sim.clearBubble()
        sim.standOut = .docked
    }

    func shutdown() { timer?.invalidate(); timer = nil; panel.close() }
}

// MARK: - «Изменить» panel

/// Beside Chilk: title, date and time (a message also its text); «Готово» → a new card, «Отмена» → the same one.
@MainActor
final class CardEditPanel {
    private var window: NSPanel?
    private var done: ((ActionCard?) -> Void)?

    func show(_ card: ActionCard, beside chilk: NSRect, onLeftEdge: Bool, done: @escaping (ActionCard?) -> Void) {
        close()
        self.done = done
        let model = CardEditModel(card)
        let view = CardEditView(model: model, save: { [weak self] in self?.finish(model.edited()) },
                                cancel: { [weak self] in self?.finish(nil) })
        let size = NSSize(width: 360, height: model.hasText ? 250 : 190)
        let screen = NSScreen.screens.first { $0.frame.intersects(chilk) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? chilk
        var x = onLeftEdge ? chilk.maxX - 30 : chilk.minX - size.width + 30
        x = min(max(x, screen.minX + 12), screen.maxX - size.width - 12)
        let y = min(max(chilk.midY - size.height / 2, screen.minY + 12), screen.maxY - size.height - 12)
        let w = NSPanel(contentRect: NSRect(origin: NSPoint(x: x, y: y), size: size),
                        styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        w.title = String(localized: "Изменить")
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.contentViewController = NSHostingController(rootView: view)
        w.setContentSize(size)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.window === w { self?.finish(nil, closing: false) } }
        }
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    private func finish(_ edited: ActionCard?, closing: Bool = true) {
        let callback = done
        done = nil
        if closing { close() } else { window = nil }
        callback?(edited)
    }

    /// Acceptance: the panel's own window to a PNG (`snapshot` names the file).
    func snapshot(_ write: (String) -> Void) {
        guard let w = window, let dir = ProcessInfo.processInfo.environment["CHILK_DEMO_CARD_SNAPSHOT"] else { return }
        _ = WindowSnapshot.write(w, to: URL(fileURLWithPath: dir).appending(path: "edit-panel.png"))
    }

    func close() {
        guard let w = window else { return }
        window = nil
        done = nil
        w.orderOut(nil)
    }
}

@MainActor
@Observable
final class CardEditModel {
    let original: ActionCard
    var title: String
    var date: Date
    var text: String
    let hasText: Bool
    let hasDate: Bool

    init(_ card: ActionCard) {
        original = card
        switch card.kind {
        case .reminder(let t, let d): title = t; date = d; text = ""; hasText = false; hasDate = true
        case .message(let t, let m, let d): title = t; date = d; text = m; hasText = true; hasDate = true
        case .reminderChange(_, let old, let oldDue, let t, let d):
            title = t.isEmpty ? old : t; date = d ?? oldDue ?? Date().addingTimeInterval(3600); text = ""; hasText = false; hasDate = true
        case .reminderComplete(_, let t, let d), .reminderDelete(_, let t, let d):
            title = t; date = d ?? Date(); text = ""; hasText = false; hasDate = false
        }
    }

    var valid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!hasText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (!hasDate || date > Date())
    }

    /// The edited card: a new id (a new card), no guess marks — the user set the time himself.
    func edited() -> ActionCard {
        let t = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let kind: ActionCard.Kind
        switch original.kind {
        case .reminder: kind = .reminder(title: t, due: date)
        case .message: kind = .message(title: t, text: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)), at: date)
        case .reminderChange(let id, let old, let oldDue, _, _):
            kind = .reminderChange(id: id, oldTitle: old, oldDue: oldDue, title: t, due: date)
        default: kind = original.kind
        }
        return ActionCard(kind: kind)
    }
}

struct CardEditView: View {
    @Bindable var model: CardEditModel
    var save: () -> Void
    var cancel: () -> Void

    var body: some View {
        Form {
            TextField(model.hasText ? String(localized: "Коротко") : String(localized: "Название"), text: $model.title)
            if model.hasText {
                TextField(String(localized: "Что сказать"), text: $model.text, axis: .vertical).lineLimit(2...4)
            }
            if model.hasDate {
                DatePicker(String(localized: "Когда"), selection: $model.date, in: Date()...,
                           displayedComponents: [.date, .hourAndMinute])
                    .environment(\.locale, Locale(identifier: "ru_RU"))
            }
            HStack {
                Spacer()
                Button(String(localized: "Отмена"), action: cancel).keyboardShortcut(.cancelAction)
                Button(String(localized: "Готово"), action: save).keyboardShortcut(.defaultAction).disabled(!model.valid)
            }
        }
        .formStyle(.grouped)
        .padding(4)
        .tint(TrayView.peach)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
