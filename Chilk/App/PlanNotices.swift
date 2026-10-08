import AppKit
import ChilkBrain
import ChilkCore

/// Slice 9b (SPEC «Срез 9», decisions 13, 15, 17): the day plan's own moments at the edge.
/// - Morning (15): at the first activity after 05:00, one bubble with today's things and a wish; no buttons, a click
///   opens «Лист дня». Yesterday left open and not summed up — «Вчера не подвели итоги — подвести?» + «Подвести».
/// - Evening (17, without «Сон»): when «Конец дня» fires and today had things — «Подведём день?» + «Подвести».
/// Both follow the timer's display rule: they stay while the user is away; seen = input, then gone.
/// - The offer (13): the second single reminder for the same day within 30 minutes — after its card's result,
///   «Может, спланируем день целиком?» in the channel the card was answered in.
@MainActor
final class PlanNotices {
    private enum Notice: Equatable {
        case morning(text: String, review: Date?)
        case evening(day: Date, text: String)

        var id: String {
            switch self {
            case .morning: "plan-morning"
            case .evening(let day, _): "plan-evening-\(Int(day.timeIntervalSince1970))"
            }
        }
    }

    private let sim: CharacterSim
    private let reminders: ChilkReminderExecutor
    private let board: PlanBoard
    private var book: PlanBook
    private var display = NoticeDisplay()
    private var queue: [Notice] = []
    private var showing: Notice?
    private var timer: Timer?
    private var preparingMorning = false
    /// Decision 13: the offer waits for its card's result line (and, at the edge, for a free stage).
    private var offer: (day: Date, viaChat: Bool, from: Date)?
    /// Offered at the edge: «Давай» / «Не надо» under his bubble are ours until then.
    private var offerButtons: (day: Date, until: Date)?

    /// The stage is free for him to speak (no conversation, card, timer, request, popover, game).
    var stageFree: () -> Bool = { false }
    var conversationActive: () -> Bool = { false }
    var signals: () -> (idle: TimeInterval, locked: Bool) = { (0, false) }
    /// The card's result line is still waiting to be said.
    var resultPending: () -> Bool = { false }
    /// «Напоминания Apple» on in «Инструменты» (decision 18).
    var enabled: () -> Bool = { true }
    var collecting: () -> Bool = { false }
    var openSheet: (_ day: Date, _ review: Bool) -> Void = { _, _ in }
    /// The offer at the edge: he asks with the buttons and (ears on) listens a while for a spoken answer.
    var offerAtEdge: (_ line: String, _ buttons: [String]) -> Void = { _, _ in }
    var offerInChat: (_ line: String) -> Void = { _ in }
    /// The next turn knows the offer (the planner's context).
    var onOffer: (Date) -> Void = { _ in }
    var startPlan: (Date) -> Void = { _ in }
    var declineOffer: () -> Void = {}
    /// A notice left: the balance shows its prompt again.
    var onDone: () -> Void = {}
    var log: (String) -> Void = { _ in }
    var now: () -> Date = { Date() }

    private static var file: URL { AppState.directory.appendingPathComponent("plan.json") }

    init(sim: CharacterSim, reminders: ChilkReminderExecutor, board: PlanBoard) {
        self.sim = sim
        self.reminders = reminders
        self.board = board
        book = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode(PlanBook.self, from: $0) } ?? PlanBook()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.2
    }

    var ownsStage: Bool { showing != nil }

    func shutdown() { timer?.invalidate(); timer = nil }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try encoder.encode(book).write(to: Self.file, options: .atomic) } catch { log("plan book not saved: \(error)") }
    }

    private func iso(_ d: Date) -> String { PlanDay.iso(d, calendar: .current) }

    // MARK: The loop

    private func tick() {
        let s = signals()
        if !preparingMorning, showing == nil, enabled(), board.canRead, !queue.contains(where: { $0.id == "plan-morning" }),
           PlanNotice.morningDue(now: now(), idle: s.idle, locked: s.locked, book: book, calendar: .current) {
            prepareMorning()
        }
        stepOffer()
        if showing != nil, conversationActive() {
            display.interrupted()                       // he talks now; the notice comes back afterwards, unseen
            showing = nil
            log("plan notice interrupted by a conversation")
            return
        }
        guard let next = queue.first else { return }
        if showing == nil { display.seenAfter = Self.seenAfter(text(next)) }
        switch display.step(now: ProcessInfo.processInfo.systemUptime, idle: s.idle, locked: s.locked,
                            canPresent: showing == nil && stageFree(), next: next.id) {
        case .none: break
        case .show: present(next)
        case .dismiss: finish(how: "input")
        }
    }

    /// Long lines stay a little longer once the user is back (~14 characters a second).
    private static func seenAfter(_ text: String) -> TimeInterval { max(NoticeDisplay.seenAfterInput, Double(text.count) / 14) }

    private func text(_ n: Notice) -> String {
        switch n {
        case .morning(let t, _), .evening(_, let t): t
        }
    }

    private func present(_ n: Notice) {
        showing = n
        let buttons: [String] = switch n {
        case .morning(_, let review): review == nil ? [] : [PlanLines.sumUp]
        case .evening: [PlanLines.sumUp]
        }
        sim.call(line: text(n))
        sim.say(text(n), duration: .infinity, buttons: buttons)
        sim.standOut = .peek
        log("plan notice shown: \(n.id) «\(text(n))»")
    }

    private func finish(how: String) {
        guard let n = showing else { return }
        showing = nil
        if let i = queue.firstIndex(of: n) { queue.remove(at: i) }
        sim.clearBubble()
        sim.standOut = .docked
        switch n {
        case .morning: book.morningShown = iso(PlanNotice.chilkDay(now(), calendar: .current))
        case .evening(let day, _): book.eveningOffered = iso(day)
        }
        save()
        log("plan notice seen: \(n.id) (\(how))")
        onDone()
    }

    /// A click on him while a plan notice is up: seen; the morning opens today's sheet, the evening its review.
    func clicked() -> Bool {
        guard let n = showing else { return false }
        _ = display.clicked()
        finish(how: "click")
        switch n {
        case .morning: openSheet(Calendar.current.startOfDay(for: now()), false)
        case .evening(let day, _): openSheet(day, true)
        }
        return true
    }

    /// A button under his bubble: «Подвести», or «Давай» / «Не надо» of the offer. `false` — not ours.
    func pressedButton(_ index: Int) -> Bool {
        if let o = offerButtons {
            offerButtons = nil
            guard now() < o.until else { return false }
            log("plan: offer answered \(index == 0 ? "«Давай»" : "«Не надо»") (button)")
            if index == 0 { startPlan(o.day) } else { declineOffer() }
            return true
        }
        guard let n = showing else { return false }
        _ = display.clicked()
        finish(how: "button")
        switch n {
        case .morning(_, let review): if let review { openSheet(review, true) }
        case .evening(let day, _): openSheet(day, true)
        }
        return true
    }

    /// The conversation the offer started has ended: its buttons are gone with it.
    func conversationEnded() { offerButtons = nil }

    // MARK: Morning (decision 15)

    private func prepareMorning(force: Bool = false) {
        preparingMorning = true
        let cal = Calendar.current
        let today = cal.startOfDay(for: now())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        Task {
            defer { preparingMorning = false }
            guard let todays = try? await reminders.day(today), let yesterdays = try? await reminders.day(yesterday) else {
                log("plan: morning — Reminders not readable, no summary")
                book.morningShown = iso(today)
                save()
                return
            }
            let reviewed = book.reviewed.contains(iso(yesterday))
            guard let m = PlanNotice.morning(today: Self.things(todays), yesterday: Self.things(yesterdays), yesterdayReviewed: reviewed)
            else {
                log("plan: morning — nothing planned, no summary")
                book.morningShown = iso(today)
                save()
                return
            }
            guard !queue.contains(where: { $0.id == "plan-morning" }) else { return }
            queue.insert(.morning(text: PlanLines.morning(m, wish: PlanLines.wish()), review: m.reviewYesterday ? yesterday : nil), at: 0)
            log("plan: morning summary waits (\(m.total) today, \(m.timedCount) timed, review yesterday: \(m.reviewYesterday))\(force ? " [demo]" : "")")
        }
    }

    static func things(_ items: [ReminderInfo]) -> [PlanNotice.Thing] {
        items.map { PlanNotice.Thing(title: $0.title, time: $0.timed ? $0.due.map { PlanTime(of: $0, calendar: .current) } : nil,
                                     done: $0.done) }
    }

    // MARK: Evening (decision 17)

    /// «Конец дня» fired: once a day, when today had things and is not summed up yet. 9c calls it with the bedtime
    /// warning instead.
    func endOfDayFired() {
        let cal = Calendar.current
        let today = PlanNotice.chilkDay(now(), calendar: cal)
        guard enabled(), book.eveningOffered != iso(today), !book.reviewed.contains(iso(today)),
              !queue.contains(where: { if case .evening = $0 { true } else { false } }) else { return }
        guard cal.isDate(board.day, inSameDayAs: today), !board.items.isEmpty else {
            log("plan: end of day — nothing planned today, no review")
            return
        }
        let done = board.items.filter(\.done).count
        queue.append(.evening(day: today, text: PlanLines.evening(done: done, total: board.items.count)))
        log("plan: evening review waits (\(done) of \(board.items.count) done)")
    }

    /// «Готово» in the review: the day is summed up; he reacts when he is free.
    func reviewed(day: Date, done: Int, total: Int) {
        book.markReviewed(iso(day))
        save()
        let line = PlanLines.reaction(PlanNotice.result(done: done, total: total), done: done, total: total)
        log("plan: \(iso(day)) summed up, \(done) of \(total) done — «\(line)»")
        guard stageFree() else { return }
        if done == total, total > 0 { sim.perform(.cheer) }
        sim.say(line, duration: 5)
    }

    // MARK: The offer (decision 13)

    /// A single reminder's card was confirmed and written.
    func reminderWritten(due: Date, viaChat: Bool) {
        let cal = Calendar.current
        let day = cal.startOfDay(for: due)
        let offered = book.reminderWritten(day: iso(day), now: now(), today: iso(cal.startOfDay(for: now())))
        save()
        guard offered, enabled(), !collecting() else { return }
        offer = (day, viaChat, now())
        log("plan: a second reminder for \(iso(day)) within 30 min — offering to plan the day")
    }

    private func stepOffer() {
        guard let o = offer else { return }
        let age = now().timeIntervalSince(o.from)
        guard age >= 1.5 else { return }                                   // after the card's result line
        if age > 120 || collecting() { offer = nil; log("plan: the offer lapsed"); return }
        if o.viaChat {
            offer = nil
            onOffer(o.day)
            offerInChat(PlanLines.offer)
            log("plan: offer said in the chat")
            return
        }
        guard showing == nil, !resultPending(), stageFree() else { return }
        offer = nil
        onOffer(o.day)
        offerButtons = (o.day, now().addingTimeInterval(60))
        offerAtEdge(PlanLines.offer, [PlanLines.letsDo, PlanLines.noNeed])
        log("plan: offer shown at the edge")
    }

    // MARK: Acceptance

    /// The morning summary now — «Проверка ▸ Утренняя сводка» and the demo (not waiting for 05:00 or an active user; the
    /// display rule still applies).
    func demoMorning() {
        guard showing == nil, !preparingMorning, !queue.contains(where: { $0.id == "plan-morning" }) else { return }
        book.morningShown = nil
        prepareMorning(force: true)
    }

    /// The offer at the edge for tomorrow, as after a second reminder answered there.
    func demoOffer() {
        let cal = Calendar.current
        offer = (cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now()))!, false, now().addingTimeInterval(-2))
    }
}

extension PlanLines {
    static var sumUp: String { String(localized: "Подвести") }
    static var offer: String { String(localized: "Может, спланируем день целиком? Скажешь всё разом — сделаю одной карточкой") }
    static var letsDo: String { String(localized: "Давай") }
    static var noNeed: String { String(localized: "Не надо") }
    static var declined: String { String(localized: "Хорошо, не буду") }

    static func planning(_ day: Date) -> String {
        String(localized: "Планируем \(PlanDay.title(day, now: Date(), calendar: .current, accusative: true)). Что в планах?")
    }

    /// Decision 15: «Доброе утро! Сегодня 5 дел, 2 со временем: 11:00 — созвон, 15:00 — маме. Всё в Напоминаниях.
    /// {пожелание}»; yesterday left open — «Вчера не подвели итоги — подвести?» at the end, before its button.
    /// The first activity of his day may come late (a first launch at 17:00): the greeting follows the clock.
    static func morning(_ m: PlanNotice.Morning, wish: String, hour: Int = Calendar.current.component(.hour, from: Date())) -> String {
        var parts = [hour < 12 ? String(localized: "Доброе утро!") : hour < 18 ? String(localized: "Добрый день!")
                                                                             : String(localized: "Добрый вечер!")]
        if m.total > 0 {
            let things = RussianPlural.form(m.total, String(localized: "дело"), String(localized: "дела"), String(localized: "дел"))
            var today = String(localized: "Сегодня \(m.total) \(things)")
            if m.timedCount > 0 {
                let list = m.timed.map { "\($0.time!.text) — \($0.title)" }.joined(separator: ", ")
                today += ", " + String(localized: "\(m.timedCount) со временем: \(list)")
                if m.timedCount > m.timed.count { today += " " + String(localized: "и ещё \(m.timedCount - m.timed.count)") }
            }
            parts.append(today + ".")
            parts.append(String(localized: "Всё в Напоминаниях."))
        }
        parts.append(wish)
        if m.reviewYesterday { parts.append(String(localized: "Вчера не подвели итоги — подвести?")) }
        return parts.joined(separator: " ")
    }

    static func evening(done: Int, total: Int) -> String {
        String(localized: "Подведём день? Сделано \(done) из \(total)")
    }

    /// Until the Codex batch of 9e: a hand-written stock (decision 15 «без сети — ручной запас»).
    static func wish() -> String {
        [String(localized: "Пусть день будет лёгким ☀️"), String(localized: "Хорошего дня!"), String(localized: "Ты справишься 💪"),
         String(localized: "Не забывай про воду 💧"), String(localized: "Пусть всё получится!"),
         String(localized: "Шаг за шагом — и всё успеем."), String(localized: "Улыбнись — день только начался 🙂"),
         String(localized: "Я рядом, если что.")].randomElement()!
    }

    /// Decision 17: «4 из 5 — красота!» (a hand-written stock until 9e).
    static func reaction(_ r: PlanNotice.Result, done: Int, total: Int) -> String {
        let pool: [String] = switch r {
        case .all: [String(localized: "\(done) из \(total) — красота!"), String(localized: "Всё сделано! Горжусь 🌟"),
                    String(localized: "\(done) из \(total). Идеальный день!")]
        case .most: [String(localized: "\(done) из \(total) — красота!"), String(localized: "\(done) из \(total) — хороший день"),
                     String(localized: "\(done) из \(total). Остальное — потом")]
        case .some: [String(localized: "\(done) из \(total) — тоже движение"), String(localized: "\(done) из \(total). Продолжим"),
                     String(localized: "Неплохо: \(done) из \(total)")]
        case .none: [String(localized: "Бывает. Новый день — новые силы"), String(localized: "Ничего, перенесём — получится"),
                     String(localized: "Отдохни, потом наверстаем")]
        }
        return pool.randomElement()!
    }
}
