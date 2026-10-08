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
    enum Source: String { case edge, voice, chat, panel, sheet }

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
    /// Slice 9, decision 8: cards first shown in a voice conversation — back at the edge, he listens for the answer.
    private var bornInVoice: Set<UUID> = []
    /// A voice-born card is shown again at the edge (the conversation opens a minute without the name).
    var onShownAgain: () -> Void = {}
    /// A card was answered (any way): a conversation watching for a spoken answer stops listening.
    var onSettled: () -> Void = {}
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
    /// Slice 9b (decision 13): a card was confirmed and written — which one, where it was answered, whether it worked.
    var onCommitted: (ActionCard, Source, Bool) -> Void = { _, _, _ in }
    /// Slice 10 (decision 2): «Нет» on a card (the planner tells Codex on the next turn).
    var onDeclined: (ActionCard) -> Void = { _ in }
    /// Slice 10 (decision 4): «Изменить» on a plan card opens «Лист дня» on the plan's day — the draft is edited there.
    var openPlanSheet: (Date) -> Void = { _ in }
    /// Slice 10 (decision 6): the result line of «Записать» in the sheet (a chat plan shows it in the chat too).
    var onSheetResult: (String) -> Void = { _ in }
    /// The result line of a card answered by voice still waits for a free stage.
    var resultPending: Bool { pendingResult != nil }
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

    /// Slice 8f: the note a change card is about (nil for anything else).
    private static func noteID(_ kind: ActionCard.Kind) -> String? {
        switch kind {
        case .noteAppend(let id, _, _), .noteRewrite(let id, _, _, _, _), .noteDelete(let id, _): id
        default: nil
        }
    }

    /// The same words, whatever the case or the spacing (a correction may retype them).
    private static func sameText(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> String { s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        return words(a) == words(b)
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
        // Slice 8e: «нет, в календарь» turns a reminder card into an event card (and back) — the same title or time.
        case (.event(let t1, let s1, _, _), .event(let t2, let s2, _, _)): t1 == t2 || s1 == s2
        case (.reminder(let t1, let d1), .event(let t2, let d2, _, _)), (.event(let t1, let d1, _, _), .reminder(let t2, let d2)):
            t1 == t2 || d1 == d2
        case (.eventChange(let i1, _, _, _, _, _, _, _), .eventChange(let i2, _, _, _, _, _, _, _)),
             (.eventChange(let i1, _, _, _, _, _, _, _), .eventDelete(let i2, _, _, _, _)),
             (.eventDelete(let i1, _, _, _, _), .eventChange(let i2, _, _, _, _, _, _, _)),
             (.eventDelete(let i1, _, _, _, _), .eventDelete(let i2, _, _, _, _)): i1 == i2
        // Slice 8f: «нет, назови её «Покупки»» / «нет, добавь ещё сыр» — a correction of the one note on the card;
        // «нет, допиши это в «Покупки»» turns a new note into an append (the same text).
        case (.note(let t1, let x1), .note(let t2, let x2)): t1 == t2 || sameText(x1, x2)
        case (.note(_, let x1), .noteAppend(_, _, let x2)), (.noteAppend(_, _, let x1), .note(_, let x2)): sameText(x1, x2)
        // Slice 9b: a correction of the plan of the same day («маме не в 15, а в 16») replaces its card.
        case (.plan(let d1, _, _), .plan(let d2, _, _)): Calendar.current.isDate(d1, inSameDayAs: d2)
        default: noteID(a.kind).map { $0 == noteID(b.kind) } ?? false
        }
    }

    /// A turn ended (answered or failed): a correction that proposed nothing corrects nothing later.
    func turnEnded() { correcting = false }

    /// The conversation's bubble shows the card (its buttons route here).
    func showInConversation() {
        guard let card = current else { return }
        inConversation = true
        bornInVoice.insert(card.id)
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
        if case .plan = card.kind {
            return "на экране карточка плана: \(card.summary()). Если пользователь её поправляет — вызови chilk_plan с action "
                + "finish, тем же днём и ВСЕМ исправленным списком (новая карточка заменит эту); если просит другое — делай другое"
        }
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
        switch CardAnswer.parse(words, deleting: card.deletes) {
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

    /// Slice 10 (decision 6): «Записать» in «Лист дня» — the same «Да», for the card it was drawn for (first in the queue).
    func confirm(_ id: UUID, source: Source) {
        guard current?.id == id else { log("card: «Записать» for a card that is not first"); return }
        confirm(source: source)
    }

    /// Slice 10: every thing of a plan card removed in the sheet — the same «Нет».
    func decline(_ id: UUID, source: Source) {
        guard current?.id == id else {
            if let card = queue.cards.first(where: { $0.id == id }) {
                _ = queue.settle(id)
                bornInVoice.remove(card.id)
                log("card answered: no (\(source.rawValue), not first)")
                onDeclined(card)
                onChange()
            }
            return
        }
        decline(source: source)
    }

    private func confirm(source: Source) {
        guard let card = current, !card.expired(now: Date()) else { return }
        settle(card, how: "yes (\(source.rawValue))")             // before the await: one card is written once
        Task {
            let result = await commit(card)
            log("card committed: ok=\(result.ok)")
            onResult(card.id, result.line, result.ok)
            onCommitted(card, source, result.ok)
            if source == .sheet { onSheetResult(result.line) }
            guard source != .chat else { return }
            // At the edge the card's own bubble becomes the result; by voice it waits until the stage is free.
            if source == .edge || source == .panel || source == .sheet, stageFree() || !sim.isTalking { sim.say(result.line, duration: 4) }
            else { pendingResult = (result.line, Date().addingTimeInterval(15)) }
        }
    }

    private func decline(source: Source) {
        guard let card = current else { return }
        settle(card, how: "no (\(source.rawValue))")
        onDeclined(card)
        // From the sheet the block simply goes; the line only when the stage is his (review 10).
        if source == .edge || source == .panel || (source == .sheet && stageFree()) {
            sim.say(String(localized: "Ладно, ничего не делаю"), duration: 2.5)
        }
        // By voice the conversation says it as it closes.
    }

    private func settle(_ card: ActionCard, how: String) {
        panel.close()
        queue.settle(card.id)
        bornInVoice.remove(card.id)
        correcting = false
        log("card answered: \(how)")
        onSettled()
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
        // Slice 10 (decisions 3, 4; Б1): a plan is edited in «Лист дня», in its «Ещё не записано» — no panel over the sheet.
        if case .plan(let day, _, _) = card.kind {
            log("card: plan edit → the day sheet")
            openPlanSheet(day)
            return
        }
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
        if again, bornInVoice.remove(card.id) != nil { onShownAgain() }   // one watch per card: never a loop
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
        let content: NSViewController
        let size: NSSize
        // Slice 10 (decision 4): a plan card never comes here — it is edited in «Лист дня».
        do {
            let model = CardEditModel(card)
            content = NSHostingController(rootView: CardEditView(model: model, save: { [weak self] in self?.finish(model.edited()) },
                                                                 cancel: { [weak self] in self?.finish(nil) }))
            size = NSSize(width: 360, height: model.isNote ? 330 : model.hasText ? 250 : model.hasDate && model.hasMinutes ? 230
                          : (model.hasDate || model.hasMinutes ? 190 : 150))
        }
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
        w.contentViewController = content
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
    /// Slice 8e: an all-day event — the date only.
    let dateOnly: Bool
    /// Slice 8d: a Clock timer has minutes instead of a date (decision 5: «у таймера — минуты»); slice 8e: an event with a
    /// time has its length. Kept as typed text: a macOS number field commits only on Return, so «Готово» clicked right
    /// after typing would save the old value.
    var minutesText = ""
    var minutes: Int? { Int(minutesText.trimmingCharacters(in: .whitespaces)) }
    private var startMinutes = 0
    /// The field as it opened: untouched, the exact length stays («через 90 секунд» stays 90 s; a hand-made event longer
    /// than the field's 1439 minutes keeps its length).
    private var startMinutesText = ""
    private var minutesTouched: Bool { minutesText.trimmingCharacters(in: .whitespaces) != startMinutesText }
    let hasMinutes: Bool
    /// The date the card started with: a rename keeps the time unless the user moves it.
    private let startDate: Date?

    init(_ card: ActionCard) {
        original = card
        var length: TimeInterval?
        switch card.kind {
        case .reminder(let t, let d):
            title = t; date = d; text = ""; hasText = false; hasDate = true; startDate = d; dateOnly = false
        case .message(let t, let m, let d):
            title = t; date = d; text = m; hasText = true; hasDate = true; startDate = d; dateOnly = false
        case .reminderChange(_, let old, _, let t, let d):
            // A reminder without a time gets no date field (renaming must not give it one).
            title = t.isEmpty ? old : t; date = d ?? Date().addingTimeInterval(3600); text = ""; hasText = false
            hasDate = d != nil; startDate = d; dateOnly = false
        case .reminderComplete(_, let t, let d), .reminderDelete(_, let t, let d):
            title = t; date = d ?? Date(); text = ""; hasText = false; hasDate = false; startDate = d; dateOnly = false
        case .timer(let t, let seconds):
            title = t; date = Date(); text = ""; hasText = false; hasDate = false; startDate = nil; dateOnly = false
            length = TimeInterval(seconds)
        case .event(let t, let s, let e, let allDay), .eventChange(_, _, _, _, let allDay, let t, let s, let e):
            title = t; date = s; text = ""; hasText = false; hasDate = true; startDate = s; dateOnly = allDay
            if !allDay { length = e.timeIntervalSince(s) }
        case .eventDelete(_, let t, let s, _, _):
            title = t; date = s; text = ""; hasText = false; hasDate = false; startDate = s; dateOnly = false
        case .note(let t, let x), .noteAppend(_, let t, let x), .noteRewrite(_, _, _, let t, let x):
            title = t; date = Date(); text = x; hasText = true; hasDate = false; startDate = nil; dateOnly = false
        case .noteDelete(_, let t):
            title = t; date = Date(); text = ""; hasText = false; hasDate = false; startDate = nil; dateOnly = false
        case .plan(let d, let items, _):
            // Slice 10: a plan is edited in «Лист дня»; this one-item model is never shown for it.
            title = items.first?.title ?? ""; date = d; text = ""; hasText = false; hasDate = false; startDate = nil; dateOnly = false
        }
        hasMinutes = length != nil
        if let length {
            let m = min(1439, max(1, Int((length / 60).rounded())))
            startMinutes = m
            minutesText = String(m)
            startMinutesText = String(m)
        }
    }

    var dateTouched: Bool { startDate.map { abs($0.timeIntervalSince(date)) >= 30 } ?? false }

    /// Slice 8f: a note's card edits its title and text; an append edits only the lines to add.
    var isNote: Bool {
        switch original.kind {
        case .note, .noteAppend, .noteRewrite: true
        default: false
        }
    }

    var hasTitle: Bool {
        if case .noteAppend = original.kind { return false }
        return true
    }

    var titleLabel: String {
        isNote ? String(localized: "Заголовок") : hasText ? String(localized: "Коротко") : String(localized: "Название")
    }

    var textLabel: String {
        if case .noteAppend = original.kind { return String(localized: "Что дописать") }
        return isNote ? String(localized: "Текст") : String(localized: "Что сказать")
    }

    /// A new note may be only its title; every other text field must say something.
    private var textOptional: Bool {
        if case .note = original.kind { return true }
        return false
    }

    /// «Минуты» for a Clock timer, «Длительность, мин» for an event.
    var minutesLabel: String {
        if case .timer = original.kind { return String(localized: "Минуты") }
        return String(localized: "Длительность, мин")
    }

    /// The earliest day or moment the picker offers: today for an all-day event, now otherwise — but never later than a
    /// change card's own start: a picker bound above a past start would pull it up to now and silently move the event.
    var earliest: Date {
        let base = dateOnly ? Calendar.current.startOfDay(for: Date()) : Date()
        return isChange ? min(startDate ?? base, base) : base
    }

    var valid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!hasText || textOptional || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (!hasDate || dateValid)
            && (!hasMinutes || minutes.map { (1...1439).contains($0) } == true)
    }

    /// A change may keep a past time it does not move; anything new lies ahead (an all-day event: from today).
    private var dateValid: Bool {
        if isChange && !dateTouched { return true }
        return dateOnly ? date >= Calendar.current.startOfDay(for: Date()) : date > Date()
    }

    private var isChange: Bool {
        switch original.kind {
        case .reminderChange, .eventChange: true
        default: false
        }
    }

    /// The edited card: a new id (a new card), no guess marks — the user set the time himself.
    func edited() -> ActionCard {
        let t = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let noteText = String(ChilkToolCatalog.noteText(text).prefix(2000))
        let kind: ActionCard.Kind
        switch original.kind {
        case .reminder: kind = .reminder(title: t, due: date)
        case .message: kind = .message(title: t, text: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)), at: date)
        case .reminderChange(let id, let old, let oldDue, _, let due):
            kind = .reminderChange(id: id, oldTitle: old, oldDue: oldDue, title: t, due: hasDate && dateTouched ? date : due)
        case .timer(_, let seconds):
            kind = .timer(title: t, seconds: minutesTouched ? (minutes ?? startMinutes) * 60 : seconds)
        case .event(_, let start, let end, let allDay):
            let span = slot(start: start, end: end, allDay: allDay)
            kind = .event(title: t, start: span.start, end: span.end, allDay: allDay)
        case .eventChange(let id, let old, let oldStart, let oldEnd, let allDay, _, let start, let end):
            let span = slot(start: start, end: end, allDay: allDay)
            kind = .eventChange(id: id, oldTitle: old, oldStart: oldStart, oldEnd: oldEnd, allDay: allDay, title: t,
                                start: span.start, end: span.end)
        case .note: kind = .note(title: t, text: noteText)
        case .noteAppend(let id, let title, _): kind = .noteAppend(id: id, title: title, text: noteText)
        case .noteRewrite(let id, let old, let oldText, _, _):
            kind = .noteRewrite(id: id, oldTitle: old, oldText: oldText, title: t, text: noteText)
        default: kind = original.kind
        }
        return ActionCard(kind: kind)
    }

    /// Slice 8e: an untouched date keeps the exact start and untouched minutes the exact length; a whole day moves by
    /// whole days.
    private func slot(start: Date, end: Date, allDay: Bool) -> (start: Date, end: Date) {
        guard !allDay else { return dateTouched ? ActionCard.allDaySlot(movedTo: date, start: start, end: end) : (start, end) }
        let s = dateTouched ? date : start
        return (s, s.addingTimeInterval(minutesTouched ? TimeInterval((minutes ?? startMinutes) * 60) : end.timeIntervalSince(start)))
    }
}

struct CardEditView: View {
    @Bindable var model: CardEditModel
    var save: () -> Void
    var cancel: () -> Void

    var body: some View {
        Form {
            if model.hasTitle { TextField(model.titleLabel, text: $model.title) }
            if model.hasText && model.isNote {
                // A note has lines: Return makes a new one here (in a text field it would press «Готово»).
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.textLabel).foregroundStyle(.secondary)
                    TextEditor(text: $model.text).font(.body).scrollContentBackground(.hidden).frame(minHeight: 96, maxHeight: 150)
                }
            } else if model.hasText {
                TextField(model.textLabel, text: $model.text, axis: .vertical).lineLimit(2...4)
            }
            if model.hasDate {
                DatePicker(String(localized: "Когда"), selection: $model.date, in: model.earliest...,
                           displayedComponents: model.dateOnly ? [.date] : [.date, .hourAndMinute])
                    .environment(\.locale, Locale(identifier: "ru_RU"))
            }
            if model.hasMinutes { MinutesField(text: $model.minutesText, label: model.minutesLabel) }
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

/// «Минуты: [ 25 ] ±» — a Clock timer or an event's length (1 min … 23 h 59 min); a wrong number turns the field red and
/// «Готово» off.
struct MinutesField: View {
    @Binding var text: String
    var label = String(localized: "Минуты")

    private var value: Int? { Int(text.trimmingCharacters(in: .whitespaces)) }
    private var stepped: Binding<Int> {
        Binding(get: { min(1439, max(1, value ?? 1)) }, set: { text = String($0) })
    }

    var body: some View {
        HStack {
            Text(label)
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
