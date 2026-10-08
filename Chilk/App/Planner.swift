import ChilkBrain
import ChilkCore
import EventKit
import Foundation

/// Slice 9b (SPEC «Срез 9», decisions 9–13): the day plan being collected by voice or in the chat. The model sends the
/// whole list with every `chilk_plan` call; «всё» — or 20 s of silence, «Это всё?», 20 s more — turns it into ONE card.
/// Nothing is written before the card's «Да».
@MainActor
final class Planner {
    enum Channel { case voice, chat }

    private(set) var draft: PlanDraft?
    private(set) var channel: Channel = .voice
    private var touched = Date()
    private let reminders: ChilkReminderExecutor
    weak var cards: CardDesk?
    var log: (String) -> Void = { _ in }
    /// The user's words of the turn that called the tool (the night «завтра» rule).
    var lastWords: () -> String = { "" }
    var now: () -> Date = { Date() }
    /// A draft nobody touched for this long is dropped (the user walked away mid-plan).
    static let lapse: TimeInterval = 600
    /// Decision 13: «спланируем день целиком?» was just offered for this day — the next turns know it for a while.
    private var offered: (day: Date, at: Date)?
    static let offerHeard: TimeInterval = 180

    /// Slice 10 (decisions 2, 3, 5): the plan card proposed last — its day and the user's edits so far (the draft's
    /// edits travel with it).
    private var pending: (id: UUID, day: Date, edits: PlanEdits)?
    /// The user's edits of the draft being collected (all of them — they go to the card's outcome).
    private var draftEdits = PlanEdits()
    /// The edits since the last turn: the next turn hears them once (decision 5).
    private var sheetNote = PlanEdits()
    /// The card's end (decision 2): the next turn hears it once.
    private var notes: [String] = []
    /// The draft or the plan card changed: «Лист дня» redraws its «Ещё не записано».
    var onChange: () -> Void = {}
    private var observer: NSObjectProtocol?

    init(reminders: ChilkReminderExecutor) {
        self.reminders = reminders
        // Decision 8: «уже в плане» follows Reminders («+» in the sheet, the iPhone) while a plan is collected.
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAlready() }
        }
    }

    /// A plan is being collected (an abandoned one lapses).
    var collecting: Bool {
        guard draft != nil else { return false }
        if now().timeIntervalSince(touched) > Self.lapse {
            draft = nil
            log("plan: the draft lapsed")
            return false
        }
        return true
    }

    func collecting(in c: Channel) -> Bool { collecting && channel == c }

    func offer(_ day: Date) { offered = (Calendar.current.startOfDay(for: day), now()) }

    /// «Давай» on the offer: that day's plan starts without a model turn; what is already there goes to «Уже в плане».
    func start(day: Date, channel c: Channel) async -> Bool {
        let cal = Calendar.current
        let d = cal.startOfDay(for: day)
        guard let items = try? await reminders.day(d) else {
            log("plan: the offer's day could not be read")
            return false
        }
        draft = PlanDraft(day: d, already: items.map(\.title))
        draftEdits = PlanEdits()
        sheetNote = PlanEdits()
        channel = c
        touched = now()
        offered = nil
        log("plan: started for \(PlanDay.iso(d, calendar: cal)) from the offer, \(items.count) already there")
        onChange()
        return true
    }

    /// [контекст] of the next turn: the card's end and the user's edits in the sheet (once), the plan being collected,
    /// or right after the offer — the offer.
    func context() -> String? {
        var parts = notes
        notes = []
        if let e = sheetNote.text {
            parts.append("пользователь сам поправил черновик в «Листе дня»: \(e). Черновик ниже — уже с этим; убранное не возвращай")
            sheetNote = PlanEdits()
        }
        if let current = collectingContext() { parts.append(current) }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    /// [контекст] while collecting: the day and the draft as the app has it; right after the offer — the offer.
    private func collectingContext() -> String? {
        let cal = Calendar.current
        guard collecting, let draft else {
            guard let o = offered, now().timeIntervalSince(o.at) < Self.offerHeard else { return nil }
            let iso = PlanDay.iso(o.day, calendar: cal)
            return "Чилк только что сам предложил спланировать \(PlanDay.title(o.day, now: now(), calendar: cal)) (\(iso)) целиком. "
                + "Согласие («давай», «да») — chilk_plan collect с day=\(iso) (и делами, если названы); отказ — коротко, без вызова"
        }
        let list = draft.items.isEmpty ? "пока пусто"
            : draft.items.map { ($0.time.map { $0.text + " " } ?? "") + $0.title }.joined(separator: "; ")
        return "идёт план на \(PlanDay.title(draft.day, now: now(), calendar: cal)) (\(PlanDay.iso(draft.day, calendar: cal))); "
            + "черновик: \(list)" + (draft.already.isEmpty ? "" : "; уже в плане: " + draft.already.joined(separator: ", "))
            + ". Новое дело или поправка — chilk_plan collect со ВСЕМ списком; «всё» — finish; отвечай в два-три слова"
    }

    func handle(_ action: PlanAction, day said: Date?, items: [PlanItem], channel c: Channel) async -> CodexToolResult {
        let cal = Calendar.current
        let now = now()
        if action == .cancel {
            let had = draft != nil
            draft = nil
            offered = nil
            log("plan: cancelled")
            onChange()
            return .ok(["cancelled": .bool(had)])
        }
        // A day said starts (or moves) the plan; none said keeps the plan's day, or takes the default one.
        let day: Date
        if said == nil, collecting, let d = draft?.day {
            day = d
        } else {
            let r = PlanDay.resolve(said, words: lastWords(), now: now, calendar: cal)
            if r.nightTomorrow { log("plan: «завтра» at night — the day after sleep") }
            day = r.day
        }
        guard PlanDay.inRange(day, now: now, calendar: cal) else {
            return .failure("day_out_of_range: a plan is for today or a day ahead, at most a year; ask which day")
        }
        var current: PlanDraft
        if collecting, let d = draft, cal.isDate(d.day, inSameDayAs: day) {
            current = d
            // Decision 8: what reached Reminders meanwhile («+» in the sheet, the iPhone) is «уже в плане» now.
            if let items = try? await reminders.day(day) { current.refresh(already: items.map(\.title)) }
        } else {
            let already: [String]
            do { already = try await reminders.day(day).map(\.title) } catch ReminderAccessError.denied {
                return .failure("no_access: no access to Reminders. The user can allow it in System Settings → Privacy & Security → Reminders → Чилк")
            } catch {
                return .failure("reminders_unreachable: could not read Apple Reminders; nothing was planned")
            }
            current = PlanDraft(day: day, already: already)
            draftEdits = PlanEdits()
            sheetNote = PlanEdits()
            channel = c
            offered = nil
            log("plan: started for \(PlanDay.iso(day, calendar: cal)), \(already.count) already there")
        }
        // A night hour only when said so — for what is new in this turn (things kept from earlier turns keep their hour).
        let words = lastWords()
        let kept = Set(current.items.map { $0.title + "|" + ($0.time?.text ?? "") })
        let items = items.map { kept.contains($0.title + "|" + ($0.time?.text ?? "")) ? $0 : $0.dayHour(words: words) }
        // «всё» often comes with an empty list (the model sent it already): finish keeps the draft as collected.
        if !(action == .finish && items.isEmpty) { current.update(items) }
        draft = current
        channel = c                    // the channel of this turn: the silences follow the user (review 9b)
        touched = now
        if action == .finish { return finish(reason: "finish") }
        onChange()
        return .ok(["day": .string(PlanDay.iso(day, calendar: cal)),
                    "day_text": .string(PlanDay.title(day, now: now, calendar: cal)),
                    "count": .number(Double(current.items.count)),
                    "already": .array(current.already.map(JSON.string)),
                    "note": "Nothing is created yet: keep collecting; when the user says всё — action finish (one card)."])
    }

    /// «всё» or the second silence: one card for the plan; the collecting ends either way.
    @discardableResult
    func finish(reason: String) -> CodexToolResult {
        guard let d = draft else { return .failure("no_plan: nothing is being planned; start with action collect") }
        draft = nil
        defer { onChange() }
        guard let card = d.card() else {
            log("plan: finished with nothing new (\(reason))")
            return .failure("empty_plan: nothing new to add — the plan stays as it is; say so in a few words")
        }
        guard let cards else { return .failure("cards_unavailable: nothing was planned") }
        // Slice 10: the draft's edits travel with its card; a correction of a card of the same day keeps that card's.
        var edits = draftEdits
        if let p = pending, Calendar.current.isDate(p.day, inSameDayAs: d.day),
           cards.queue.cards.contains(where: { $0.id == p.id }) { edits.append(p.edits) }
        draftEdits = PlanEdits()
        pending = (card.id, d.day, edits)
        cards.propose(card)
        log("plan: card proposed (\(reason)), \(d.items.count) item(s)")
        return .ok(["awaiting_confirmation": true, "card": .string(card.summary()),
                    "note": "Nothing is created yet. The user confirms the plan card with Да, changes it, or says Нет."])
    }

    /// The second silence (voice or chat): the draft becomes its card. `false` — there was nothing to show.
    func silenceFinish() -> Bool { finish(reason: "silence").success }

    // MARK: Slice 10 — «Ещё не записано» in «Лист дня» (decisions 1, 3, 5, 6, 8) and the card's end (decision 2)

    /// What is not written yet for `day`: the draft being collected, or the plan card waiting for «Да». `canRecord` —
    /// «Записать» can write it now (a card first in the queue and not expired, or a draft with things in it).
    func unwritten(for day: Date) -> (items: [PlanItem], canRecord: Bool)? {
        let cal = Calendar.current
        if collecting, let d = draft, cal.isDate(d.day, inSameDayAs: day) { return (d.items, !d.items.isEmpty) }
        guard let p = pending, cal.isDate(p.day, inSameDayAs: day), let card = pendingCard(),
              case .plan(_, let items, _) = card.kind else { return nil }
        return (items, cards?.current?.id == p.id && !card.expired(now: now()))
    }

    private func pendingCard() -> ActionCard? {
        guard let p = pending else { return nil }
        return cards?.queue.cards.first { $0.id == p.id }
    }

    /// Decision 3: ✕ (nil) or a double-click edit in the sheet — of the draft being collected, or of the waiting card.
    func editUnwritten(day: Date, index: Int, to item: PlanItem?) {
        let cal = Calendar.current
        if collecting, var d = draft, cal.isDate(d.day, inSameDayAs: day) {
            guard let old = d.edit(index, to: item) else { return }
            draft = d
            draftEdits.record(old, item)
            sheetNote.record(old, item)
            touched = now()
            log("plan: the draft edited in the sheet (\(item == nil ? "removed" : "changed"))")
            onChange()
            return
        }
        guard var p = pending, cal.isDate(p.day, inSameDayAs: day), let card = pendingCard(),
              case .plan(let planDay, var items, let already) = card.kind, items.indices.contains(index) else { return }
        let old = items[index]
        if let item { items[index] = item } else { items.remove(at: index) }
        p.edits.record(old, item)
        pending = p
        if items.isEmpty {
            log("plan: every thing of the card removed in the sheet — the card is declined")
            cards?.decline(card.id, source: .sheet)
        } else {
            cards?.replace(card.id, with: ActionCard(id: card.id, kind: .plan(day: planDay, items: items, already: already)),
                           how: "sheet")
        }
        onChange()
    }

    /// Decision 6: «Записать» = «Да» of the plan's card (a draft being collected becomes its card first).
    func recordUnwritten(day: Date) {
        let cal = Calendar.current
        if collecting, let d = draft, cal.isDate(d.day, inSameDayAs: day) {
            guard finish(reason: "sheet").success else { return }
        }
        guard let p = pending, cal.isDate(p.day, inSameDayAs: day) else { return }
        cards?.confirm(p.id, source: .sheet)
    }

    /// Decision 2: the plan card was written (or partly) — the next turn hears what, with the user's edits.
    func committed(_ card: ActionCard, written: [String], failed: [String]) {
        guard case .plan(let day, _, _) = card.kind else { return }
        let edits = pending?.id == card.id ? pending!.edits : PlanEdits()
        if pending?.id == card.id { pending = nil }
        notes.append(PlanOutcome.written(day: day, written: written, failed: failed, edits: edits, now: now(),
                                         calendar: .current))
        onChange()
    }

    /// Decision 2: «Нет» on the plan card.
    func declined(_ card: ActionCard) {
        guard case .plan(let day, _, _) = card.kind else { return }
        if pending?.id == card.id { pending = nil }
        notes.append(PlanOutcome.declined(day: day, now: now(), calendar: .current))
        onChange()
    }

    /// Decision 8: «уже в плане» of the draft being collected, from Reminders now.
    func refreshAlready() {
        guard collecting, let day = draft?.day else { return }
        Task {
            guard let items = try? await reminders.day(day), var d = draft, d.day == day else { return }
            let before = d.items.count
            d.refresh(already: items.map(\.title))
            draft = d
            if d.items.count != before { log("plan: \(before - d.items.count) draft thing(s) already in Reminders") }
            onChange()
        }
    }
}

enum PlanLines {
    /// Decision 11: the first silence while collecting.
    static var allDone: String { String(localized: "Это всё?") }
}
