import AppKit
import ChilkBrain
import ChilkCore
import SwiftUI

/// Slice 8c (SPEC «Срез 8», decisions 3–8): confirmation cards. A tool that would write into Apple's apps or schedule
/// Chilk's message only proposes; the card shows what will really be written; «Да» writes it with the card's values
/// (the model takes no part then), «Нет» drops it, «Изменить» opens the panel, other words are a correction (a new
/// model turn with the card in [контекст]). No timeout; other bubbles may come over it, then it comes back.
/// Every button press names the card it was shown for: a stale bubble never answers the next card.
@MainActor
final class CardDesk {
    enum Source: String { case edge, voice, chat, panel }

    private let sim: CharacterSim
    private(set) var queue = CardQueue()
    /// The card is in Chilk's bubble at the edge right now (not inside a conversation's bubble).
    private(set) var showing = false
    /// Another bubble took its place: when it comes back, «А карточку-то подтвердишь?».
    private var displaced = false
    /// What the bubble shows (words, the card and its buttons): another bubble taking its place is noticed, and a
    /// press maps to the button that was really on screen.
    private var shownWords: String?
    private var shown: (id: UUID, buttons: [String])?
    /// The conversation shows the card in its own bubble (decision 3 of the plan).
    private(set) var inConversation = false
    /// A turn whose words were not «да / нет» while a card was up: its proposal of the same card replaces it.
    private(set) var correcting = false
    /// Expiry as last shown (the bubble and the chat are redrawn once when «Да» goes away).
    private var shownExpired = false
    /// The minute a timer card was drawn in: its «до HH:MM» moves on with the clock.
    private var shownMinute = 0
    private static var minuteNow: Int { Int(Date().timeIntervalSince1970 / 60) }
    /// A result waiting for a free stage (it must not cover another bubble).
    private var pendingResult: (line: String, until: Date)?
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
    /// The result of a «Да» (the chat shows it).
    var onResult: (UUID, String, Bool) -> Void = { _, _, _ in }
    /// The card left a conversation's bubble (answered elsewhere): the conversation stops routing its buttons.
    var onLeftConversation: () -> Void = {}
    /// Acceptance only (CHILK_DEMO_CARD_SNAPSHOT=/dir): the screen around him a few seconds after a card shows.
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
    /// At the edge he is out for the card.
    var ownsStage: Bool { showing }
    /// The user can see the card at the edge or in the conversation's bubble right now.
    var visible: Bool { showing || inConversation }

    // MARK: Proposals

    func propose(_ card: ActionCard) {
        // A correction replaces the card only if it is the same thing (the same kind and title, or the same time):
        // «напомни ещё…» during a correction turn is a new card in the queue.
        let replacing = correcting && queue.current.map { Self.sameThing($0, card) } == true
        if replacing { panel.close() }                  // an open editor would edit a card that is gone
        queue.add(card, replacingCurrent: replacing)
        proposals += 1
        log("card proposed\(replacing ? " (correction)" : ""): \(card.summary())")
        if showing { present(again: false) } else if inConversation { refreshInConversation() }
        onChange()
    }

    static func sameThing(_ a: ActionCard, _ b: ActionCard) -> Bool {
        switch (a.kind, b.kind) {
        case (.reminder(let t1, let d1), .reminder(let t2, let d2)): t1 == t2 || d1 == d2
        case (.message(let t1, let m1, let d1), .message(let t2, let m2, let d2)): t1 == t2 || m1 == m2 || d1 == d2
        case (.reminderChange(let i1, _, _, _, _), .reminderChange(let i2, _, _, _, _)),
             (.reminderChange(let i1, _, _, _, _), .reminderComplete(let i2, _, _)),
             (.reminderChange(let i1, _, _, _, _), .reminderDelete(let i2, _, _)),
             (.reminderComplete(let i1, _, _), .reminderChange(let i2, _, _, _, _)),
             (.reminderDelete(let i1, _, _), .reminderChange(let i2, _, _, _, _)): i1 == i2
        case (.reminder, .message), (.message, .reminder): a.when == b.when
        case (.timer, .timer): true                       // «нет, на 10 минут» / «назови его чай»
        default: false
        }
    }

    /// A turn ended (answered or failed): a correction that proposed nothing corrects nothing later.
    func turnEnded() { correcting = false }

    /// The conversation's bubble shows the card (its buttons route here).
    func showInConversation() {
        guard let card = current else { return }
        inConversation = true
        let words = text(card)
        let labels = buttons(card)
        sim.say(words, duration: .infinity, buttons: labels)
        shown = (card.id, labels)
        shownExpired = card.expired(now: Date())
        shownMinute = Self.minuteNow
        if let snapshot {
            shots += 1
            let name = String(format: "card-%02d-talk", shots)
            Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in MainActor.assumeIsolated { snapshot(name) } }
        }
    }

    /// The conversation goes on without the card in its bubble (a follow-up began, or it closed).
    func leaveConversation() {
        guard inConversation else { return }
        inConversation = false
        if !showing { shown = nil }
    }

    private func refreshInConversation() {
        guard inConversation, current != nil else { return }
        showInConversation()
    }

    /// [контекст] for a correction turn: what the card on screen says.
    func context() -> String? {
        guard let card = current else { return nil }
        return "на экране карточка подтверждения: \(card.summary()). Если пользователь её поправляет — вызови тот же "
            + "инструмент заново с исправленными значениями (новая карточка заменит эту); если просит другое — делай другое"
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

    /// A button under the bubble (edge or conversation): mapped through what was really shown. `false` = no card is
    /// in that bubble (another bubble's button).
    func pressed(_ index: Int, source: Source) -> Bool {
        guard let shown, visible, sim.bubbleWords != nil else { return false }
        if source == .edge, !inConversation, sim.bubbleWords != shownWords { return false }   // another bubble now
        guard let label = shown.buttons[safe: index] else { return true }
        press(label, card: shown.id, source: source)
        return true
    }

    /// The label of the button at `index` as it was shown (the conversation says the matching line).
    func shownLabel(_ index: Int) -> String? { shown?.buttons[safe: index] }

    /// A button on the chat's card (the chat edits inline itself).
    func pressedFromChat(_ label: String, card id: UUID) {
        guard label != Self.edit else { return }
        press(label, card: id, source: .chat)
    }

    private func press(_ label: String, card id: UUID, source: Source) {
        guard let card = current, card.id == id else { log("card: a press for a card that is gone"); return }
        switch label {
        case Self.yes: confirm(source: source)
        case Self.edit: openEditor()
        case Self.no: decline(source: source)
        default: break
        }
    }

    // MARK: Answers

    enum Spoken: Equatable { case confirming, declined(String), expired(String), correction }

    /// A spoken or typed answer while the card is up. `.correction`: the caller sends the words to Codex with
    /// `context()`.
    func answer(_ words: String, source: Source) -> Spoken {
        guard let card = current else { return .correction }
        switch CardAnswer.parse(words) {
        case .yes:
            guard !card.expired(now: Date()) else { return .expired(String(localized: "Это время уже прошло — скажи другое")) }
            confirm(source: source)
            return .confirming
        case .no:
            decline(source: source)
            return .declined(String(localized: "Ладно, ничего не делаю"))
        case .correction:
            correcting = true
            log("card: a correction (\(source.rawValue))")
            return .correction
        }
    }

    private func confirm(source: Source) {
        guard let card = current, !card.expired(now: Date()) else { return }
        settle(card, how: "yes (\(source.rawValue))")             // before the await: one card is written once
        Task {
            let result = await commit(card)
            log("card committed: ok=\(result.ok)")
            onResult(card.id, result.line, result.ok)
            guard source != .chat else { return }
            // At the edge the card's own bubble becomes the result; by voice it waits until the stage is free.
            if source == .edge || source == .panel, stageFree() || !sim.isTalking { sim.say(result.line, duration: 4) }
            else { pendingResult = (result.line, Date().addingTimeInterval(15)) }
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
        correcting = false
        log("card answered: \(how)")
        if showing { hide() }
        if inConversation {
            // Answered in the chat while his bubble shows it: the bubble keeps its words, loses the buttons.
            inConversation = false
            sim.setBubbleButtons([])
            onLeftConversation()
        }
        shown = nil
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
            self.replace(card.id, with: edited, how: "panel")
        }
    }

    /// An edited card takes the place of the one it was made from (gone meanwhile → nothing happens).
    func replace(_ id: UUID, with edited: ActionCard, how: String) {
        guard queue.cards.contains(where: { $0.id == id }) else { log("card: edited a card that is gone"); return }
        queue.replace(id, with: edited)
        log("card edited (\(how)): \(edited.summary())")
        onChange()
        if current?.id == edited.id {
            if showing { present(again: false) } else { refreshInConversation() }
        }
    }

    // MARK: The edge

    private func tick() {
        if let r = pendingResult {
            if Date() > r.until { pendingResult = nil }
            else if stageFree() { pendingResult = nil; sim.say(r.line, duration: 4) }
        }
        guard let card = current else { return }
        let expired = card.expired(now: Date())
        let timerMoved: Bool = if case .timer = card.kind { Self.minuteNow != shownMinute } else { false }
        if expired != shownExpired || timerMoved {         // «Да» goes away once — or a timer's «до HH:MM» moves on
            shownExpired = expired
            shownMinute = Self.minuteNow
            onChange()
            if showing { present(again: false) } else if inConversation { refreshInConversation() }
            return
        }
        if showing {
            if sim.bubbleWords != shownWords {                   // another bubble came over it
                showing = false
                displaced = true
                shown = inConversation ? shown : nil
                log("card: another bubble over it")
            } else if sim.standOut != .out {
                sim.standOut = .out                              // hidden or sent home meanwhile: out until answered
            }
            return
        }
        guard !inConversation, stageFree() else { return }
        present(again: displaced)
    }

    private func present(again: Bool) {
        guard let card = current else { return }
        let words = text(card, again: again)
        let labels = buttons(card)
        sim.say(words, duration: .infinity, buttons: labels)
        sim.standOut = .out
        shownWords = words
        shown = (card.id, labels)
        shownExpired = card.expired(now: Date())
        shownMinute = Self.minuteNow
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
                    guard let self, let i = self.shown?.buttons.firstIndex(of: label) else { return }
                    _ = self.pressed(i, source: .edge)
                    if label == Self.edit, self.snapshot != nil {
                        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                            MainActor.assumeIsolated { self?.panel.snapshot() }
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
    private var closeObserver: NSObjectProtocol?

    func show(_ card: ActionCard, beside chilk: NSRect, onLeftEdge: Bool, done: @escaping (ActionCard?) -> Void) {
        close()
        self.done = done
        let model = CardEditModel(card)
        let view = CardEditView(model: model, save: { [weak self] in self?.finish(model.edited()) },
                                cancel: { [weak self] in self?.finish(nil) })
        let size = NSSize(width: 360, height: model.hasText ? 250 : (model.hasDate || model.hasMinutes ? 190 : 150))
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
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w,
                                                               queue: .main) { [weak self, weak w] _ in
            MainActor.assumeIsolated { if let w, self?.window === w { self?.finish(nil) } }   // the red close button
        }
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    private func finish(_ edited: ActionCard?) {
        let callback = done
        done = nil
        close()
        callback?(edited)
    }

    /// Acceptance: the panel's own window to a PNG.
    func snapshot() {
        guard let w = window, let dir = ProcessInfo.processInfo.environment["CHILK_DEMO_CARD_SNAPSHOT"] else { return }
        _ = WindowSnapshot.write(w, to: URL(fileURLWithPath: dir).appending(path: "edit-panel.png"))
    }

    func close() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        guard let w = window else { return }
        window = nil
        done = nil
        w.contentViewController = nil
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
    /// Slice 8d: a Clock timer has minutes instead of a date (decision 5: «у таймера — минуты»). Kept as typed text: a
    /// macOS number field commits only on Return, so «Готово» clicked right after typing would save the old value.
    var minutesText = ""
    var minutes: Int? { Int(minutesText.trimmingCharacters(in: .whitespaces)) }
    private var startMinutes = 0
    let hasMinutes: Bool
    /// The date the card started with: a rename of a reminder keeps its time unless the user moves it.
    private let startDate: Date?

    init(_ card: ActionCard) {
        original = card
        switch card.kind {
        case .reminder(let t, let d): title = t; date = d; text = ""; hasText = false; hasDate = true; startDate = d
        case .message(let t, let m, let d): title = t; date = d; text = m; hasText = true; hasDate = true; startDate = d
        case .reminderChange(_, let old, _, let t, let d):
            // A reminder without a time gets no date field (renaming must not give it one).
            title = t.isEmpty ? old : t; date = d ?? Date().addingTimeInterval(3600); text = ""; hasText = false
            hasDate = d != nil; startDate = d
        case .reminderComplete(_, let t, let d), .reminderDelete(_, let t, let d):
            title = t; date = d ?? Date(); text = ""; hasText = false; hasDate = false; startDate = d
        case .timer(let t, let seconds):
            title = t; date = Date(); text = ""; hasText = false; hasDate = false; startDate = nil
            let m = min(1439, max(1, (seconds + 30) / 60))
            startMinutes = m
            minutesText = String(m)
        }
        if case .timer = card.kind { hasMinutes = true } else { hasMinutes = false }
    }

    var dateTouched: Bool { startDate.map { abs($0.timeIntervalSince(date)) >= 30 } ?? false }

    var valid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!hasText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (!hasDate || date > Date() || (isChange && !dateTouched))
            && (!hasMinutes || minutes.map { (1...1439).contains($0) } == true)
    }

    private var isChange: Bool { if case .reminderChange = original.kind { true } else { false } }

    /// The edited card: a new id (a new card), no guess marks — the user set the time himself.
    func edited() -> ActionCard {
        let t = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let kind: ActionCard.Kind
        switch original.kind {
        case .reminder: kind = .reminder(title: t, due: date)
        case .message: kind = .message(title: t, text: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)), at: date)
        case .reminderChange(let id, let old, let oldDue, _, let due):
            kind = .reminderChange(id: id, oldTitle: old, oldDue: oldDue, title: t, due: hasDate && dateTouched ? date : due)
        case .timer(_, let seconds):
            // Untouched minutes keep the exact seconds («через 90 секунд» stays 90 s).
            let m = minutes ?? startMinutes
            kind = .timer(title: t, seconds: m == startMinutes ? seconds : m * 60)
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
            if model.hasMinutes { MinutesField(text: $model.minutesText) }
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

/// «Минуты: [ 25 ] ±» — a Clock timer (1 min … 23 h 59 min); a wrong number turns the field red and «Готово» off.
struct MinutesField: View {
    @Binding var text: String

    private var value: Int? { Int(text.trimmingCharacters(in: .whitespaces)) }
    private var stepped: Binding<Int> {
        Binding(get: { min(1439, max(1, value ?? 1)) }, set: { text = String($0) })
    }

    var body: some View {
        HStack {
            Text(String(localized: "Минуты"))
            Spacer()
            TextField("", text: $text).frame(width: 64).multilineTextAlignment(.trailing)
                .foregroundStyle(value.map { (1...1439).contains($0) } == true ? Color.primary : Color.red)
            Stepper("", value: stepped, in: 1...1439).labelsHidden()
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
