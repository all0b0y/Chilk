import ChilkBrain
import ChilkCore
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

    init(reminders: ChilkReminderExecutor) {
        self.reminders = reminders
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
        channel = c
        touched = now()
        offered = nil
        log("plan: started for \(PlanDay.iso(d, calendar: cal)) from the offer, \(items.count) already there")
        return true
    }

    /// [контекст] while collecting: the day and the draft as the app has it; right after the offer — the offer.
    func context() -> String? {
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
        } else {
            let already: [String]
            do { already = try await reminders.day(day).map(\.title) } catch ReminderAccessError.denied {
                return .failure("no_access: no access to Reminders. The user can allow it in System Settings → Privacy & Security → Reminders → Чилк")
            } catch {
                return .failure("reminders_unreachable: could not read Apple Reminders; nothing was planned")
            }
            current = PlanDraft(day: day, already: already)
            channel = c
            offered = nil
            log("plan: started for \(PlanDay.iso(day, calendar: cal)), \(already.count) already there")
        }
        // «всё» often comes with an empty list (the model sent it already): finish keeps the draft as collected.
        if !(action == .finish && items.isEmpty) { current.update(items) }
        draft = current
        touched = now
        if action == .finish { return finish(reason: "finish") }
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
        guard let card = d.card() else {
            log("plan: finished with nothing new (\(reason))")
            return .failure("empty_plan: nothing new to add — the plan stays as it is; say so in a few words")
        }
        guard let cards else { return .failure("cards_unavailable: nothing was planned") }
        cards.propose(card)
        log("plan: card proposed (\(reason)), \(d.items.count) item(s)")
        return .ok(["awaiting_confirmation": true, "card": .string(card.summary()),
                    "note": "Nothing is created yet. The user confirms the plan card with Да, changes it, or says Нет."])
    }

    /// The second silence (voice or chat): the draft becomes its card. `false` — there was nothing to show.
    func silenceFinish() -> Bool { finish(reason: "silence").success }
}

enum PlanLines {
    /// Decision 11: the first silence while collecting.
    static var allDone: String { String(localized: "Это всё?") }
}
