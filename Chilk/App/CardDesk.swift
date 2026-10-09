import AppKit
import ChilkBrain
import ChilkCore
import SwiftUI

/// Slice 8c (SPEC «Срез 8», decisions 3–8): confirmation cards. A tool that would write into Apple's apps or schedule
/// Chilk's message only proposes; the card shows what will really be written; «Да» writes it with the card's values,
/// «Нет» drops it, «Изменить» opens the panel, other words are a correction (a new model turn with the card in
/// [контекст]). No timeout.
/// Slice 10 (SPEC «Срез 10», Б9, decision 18): the first card of the queue is pinned over his bubble from its proposal
/// until it is answered — «Да» / «Нет» (a button, voice, the chat, the sheet), a correction (a new card replaces it) or
/// an empty plan. The user's words, his answers, requests and notices go into the bubble under it and never push it
/// away. Every button press names the card it was shown for: a stale press never answers the next card.
@MainActor
final class CardDesk {
    enum Source: String { case edge, voice, chat, panel, sheet }

    private let sim: CharacterSim
    private(set) var queue = CardQueue()
    /// What the pinned block shows (the card, its words and buttons): a press maps to the button really on screen.
    private var shown: (id: UUID, words: String, buttons: [String])?
    /// A turn whose words were not «да / нет» while a card was up: its proposal of the same card replaces it.
    private(set) var correcting = false
    /// Expiry as last shown (the block and the chat are redrawn once when «Да» goes away).
    private var shownExpired = false
    /// The minute a timer card was drawn in: its «до HH:MM» moves on with the clock.
    private var shownMinute = 0
    private static var minuteNow: Int { Int(Date().timeIntervalSince1970 / 60) }
    /// A result waiting for a free stage (it must not cover another bubble).
    private var pendingResult: (line: String, until: Date)?
    private var timer: Timer?
    private let panel = CardEditPanel()
    /// Slice 9 (decision 8), slice 10 (decision 18): cards proposed in a voice conversation — once it is over and the
    /// stage is free, he listens one more minute without his name for the answer (once per card: never a loop).
    private var bornInVoice: Set<UUID> = []
    private var listenAgain: (id: UUID, until: Date)?
    /// The last card proposed (a voice turn marks it as born in voice).
    private var lastProposed: UUID?
    /// He should listen for the card's answer again (a voice-born card outlived its conversation).
    var onListenAgain: () -> Void = {}
    /// A card was answered (any way): a conversation listening for a spoken answer stops.
    var onSettled: () -> Void = {}
    /// Counts proposals: a turn knows whether it proposed a card.
    private(set) var proposals = 0
    /// Slice 10 (decision 19): the turn in flight while a card is up — the user's words, where they came from, the card
    /// on screen and the proposals count when it began (Codex may answer only that card, only on these words).
    private var turn: (words: String, source: Source, card: UUID, proposals: Int)?

    var log: (String) -> Void = { _ in }
    /// The stage is free (no conversation, notice, request, popover, game, greeting, bubble…): a result line may show.
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
    /// Acceptance only (CHILK_DEMO_CARD_SNAPSHOT=/dir): the screen around him a few seconds after a card is pinned and
    /// soon after another bubble shows under it.
    var snapshot: ((String) -> Void)?
    private var shots = 0
    private var shotWords: String?
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
    /// The card is pinned at the edge (it holds him out there, see `CharacterSim.pinCard`).
    var pinned: Bool { shown != nil }
    /// The user can see the card at the edge right now: a spoken «да / нет» may answer it (a card behind the popover is
    /// not answered blind).
    var visible: Bool { shown != nil && sim.isCardOnScreen }

    // MARK: Proposals

    func propose(_ card: ActionCard) {
        // A correction replaces the card only if it is the same thing (the same kind and title, or the same time):
        // «напомни ещё…» during a correction turn is a new card in the queue.
        let replacing = correcting && queue.current.map { Self.sameThing($0, card) } == true
        if replacing { panel.close() }                  // an open editor would edit a card that is gone
        queue.add(card, replacingCurrent: replacing)
        proposals += 1
        lastProposed = card.id
        log("card proposed\(replacing ? " (correction)" : ""): \(card.summary())")
        pin()
        onChange()
    }

    /// The voice turn that just ended proposed a card: after the conversation he listens once more for its answer.
    func proposedInVoice() {
        if let id = lastProposed, queue.cards.contains(where: { $0.id == id }) { bornInVoice.insert(id) }
    }

    /// The minute for «да» right after the card passed in silence: no second minute after the conversation.
    func answerWaited() {
        if let id = current?.id { bornInVoice.remove(id) }
    }

    /// The conversation is over: a voice-born card is still pinned — he listens for its answer once more as soon as the
    /// stage is free (within 30 s).
    func conversationEnded() {
        guard let card = current, bornInVoice.remove(card.id) != nil else { return }
        listenAgain = (card.id, Date().addingTimeInterval(30))
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
    func turnEnded() { correcting = false; turn = nil }

    /// [контекст] for a correction turn: what the card on screen says.
    func context() -> String? {
        guard let card = current else { return nil }
        if case .plan = card.kind {
            return "на экране карточка плана: \(card.summary()). Пользователь с ней ясно соглашается («да, всё верно») — "
                + "chilk_card_answer yes, отказывается — no. Поправляет — вызови chilk_plan с action finish, тем же днём и ВСЕМ "
                + "исправленным списком (новая карточка заменит эту); если просит другое — делай другое"
        }
        return "на экране карточка подтверждения: \(card.summary()). Пользователь с ней ясно соглашается («да, всё верно», "
            + "«подтверждаю») — chilk_card_answer yes, отказывается — no. Поправляет — вызови тот же инструмент заново с "
            + "исправленными значениями (новая карточка заменит эту); если просит другое — делай другое"
    }

    // MARK: Text and buttons

    static let yes = String(localized: "Да"), edit = String(localized: "Изменить"), no = String(localized: "Нет")

    func text(_ card: ActionCard) -> String {
        card.lines(now: Date()).joined(separator: "\n")
    }

    func buttons(_ card: ActionCard) -> [String] {
        var out: [String] = []
        if !card.expired(now: Date()) { out.append(Self.yes) }
        if card.editable { out.append(Self.edit) }
        out.append(Self.no)
        return out
    }

    /// A button of the pinned block at the edge (its index on the card), mapped through what was really shown.
    func pressedPinned(_ index: Int) {
        guard let shown, let label = shown.buttons[safe: index] else { return }
        press(label, card: shown.id, source: .edge)
    }

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
            turn = (words, source, card.id, proposals)
            log("card: a correction (\(source.rawValue))")
            return .correction
        }
    }

    /// Slice 10 (SPEC «Срез 10», decision 19): `chilk_card_answer` — Codex answers the card on screen for the user. It
    /// counts only as `CardModelAnswer.judge` allows; «Да» writes the card exactly as shown.
    func modelAnswer(yes: Bool) -> CardModelAnswer {
        let card = current
        let verdict = CardModelAnswer.judge(yes: yes, words: turn?.words, cardUp: card != nil,
                                            sameCard: card != nil && turn?.card == card?.id && turn?.proposals == proposals,
                                            deleting: card?.deletes ?? false, expired: card?.expired(now: Date()) ?? false)
        log("card: Codex answered \(yes ? "yes" : "no") → \(verdict.rawValue)")
        guard let source = turn?.source else { return verdict }
        switch verdict {
        case .confirm: confirm(source: source)
        case .decline: decline(source: source)
        default: break
        }
        return verdict
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
            // At the edge the result shows in his bubble at once unless another one holds it; by voice it waits for the
            // conversation to end.
            tell(result.line, duration: 4, now: source != .voice)
        }
    }

    private func decline(source: Source) {
        guard let card = current else { return }
        settle(card, how: "no (\(source.rawValue))")
        onDeclined(card)
        // From the sheet the block simply goes; the line only when the stage is his (review 10). By voice the
        // conversation says it as it closes.
        if source == .edge || source == .panel || (source == .sheet && stageFree()) {
            tell(String(localized: "Ладно, ничего не делаю"), duration: 2.5, now: true)
        }
    }

    /// A line about the answer: now when no other bubble holds him, else once the stage is free (within 15 s).
    private func tell(_ line: String, duration: Double, now: Bool) {
        if now, stageFree() || !sim.isTalking { sim.say(line, duration: duration) }
        else { pendingResult = (line, Date().addingTimeInterval(15)) }
    }

    private func settle(_ card: ActionCard, how: String) {
        panel.close()
        queue.settle(card.id)
        bornInVoice.remove(card.id)
        if listenAgain?.id == card.id { listenAgain = nil }
        correcting = false
        log("card answered: \(how)")
        pin()                                                 // the next card of the queue, or none
        onSettled()
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
        if current?.id == edited.id { pin() }
    }

    // MARK: The pinned block (slice 10, decision 18)

    /// The first card of the queue pinned over his bubble (or none). The same words again change nothing; new words
    /// (a correction, a timer's minute, «Да» gone with the time) pop it anew.
    private func pin() {
        guard let card = current else {
            if shown != nil {
                shown = nil
                sim.unpinCard()
                log("card unpinned")
            }
            return
        }
        let words = text(card)
        let labels = buttons(card)
        let fresh = shown?.id != card.id
        sim.pinCard(words, buttons: labels)
        shown = (card.id, words, labels)
        shownExpired = card.expired(now: Date())
        shownMinute = Self.minuteNow
        guard fresh else { return }
        log("card pinned")
        shoot("card-%02d", after: 4)
        // Acceptance only: CHILK_DEMO_CARD_PRESS=<label> presses that button of the pinned card 5 s after it shows,
        // through the same path as a click (once).
        if let label = ProcessInfo.processInfo.environment["CHILK_DEMO_CARD_PRESS"], !demoPressed {
            demoPressed = true
            Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let i = self.shown?.buttons.firstIndex(of: label) else { return }
                    self.pressedPinned(i)
                    if label == Self.edit, self.snapshot != nil {
                        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                            MainActor.assumeIsolated { self?.panel.snapshot() }
                        }
                    }
                }
            }
        }
    }

    private func shoot(_ format: String, after seconds: Double) {
        guard let snapshot, shots < 12 else { return }
        shots += 1
        let name = String(format: format, shots)
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { snapshot(name) } }
    }

    private func tick() {
        if let r = pendingResult {
            if Date() > r.until { pendingResult = nil }
            else if stageFree() { pendingResult = nil; sim.say(r.line, duration: 4) }
        }
        if let again = listenAgain {
            if current?.id != again.id || Date() > again.until { listenAgain = nil }
            else if stageFree() {
                listenAgain = nil
                log("card still pinned after the conversation: listening for the answer")
                onListenAgain()
            }
        }
        guard let card = current else { return }
        let expired = card.expired(now: Date())
        let timerMoved: Bool = if case .timer = card.kind { Self.minuteNow != shownMinute } else { false }
        if expired != shownExpired || timerMoved || shown?.id != card.id {   // «Да» goes away once; «до HH:MM» moves on
            pin()
            onChange()
        }
        // Acceptance only: another bubble under the pinned card — the screen soon after it shows.
        if snapshot != nil, let words = sim.bubbleWords, words != shotWords {
            shotWords = words
            shoot("card-%02d-under", after: 1)
        }
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
