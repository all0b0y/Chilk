import Foundation

// MARK: - Slice 8c (SPEC «Срез 8», decisions 3–8): the confirmation card

/// What a card would write, built by the app from the values that will really be written — never from the model's
/// words. Nothing is created, changed or deleted before «Да».
public struct ActionCard: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// A new Apple Reminders reminder in Chilk's own list.
        case reminder(title: String, due: Date)
        /// A prepared message Chilk says at `at` («скажи мне в 17:00…»).
        case message(title: String, text: String, at: Date)
        /// An existing reminder of Chilk's list: moved and/or renamed (`title` / `due` = the new values).
        case reminderChange(id: String, oldTitle: String, oldDue: Date?, title: String, due: Date?)
        case reminderComplete(id: String, title: String, due: Date?)
        case reminderDelete(id: String, title: String, due: Date?)
        /// Slice 8d (decision 9): a timer in Apple's Clock app, counted from «Да». Clock's timer has no name: Chilk says
        /// the title when it is set.
        case timer(title: String, seconds: Int)
        /// Slice 8e (decisions 3–7, 11): an event in Chilk's own «Чилк» calendar. `end` is exclusive; an all-day event
        /// covers the days from `start` up to `end`.
        case event(title: String, start: Date, end: Date, allDay: Bool)
        /// One of Chilk's events, moved and/or renamed (`title` / `start` / `end` = the new values).
        case eventChange(id: String, oldTitle: String, oldStart: Date, oldEnd: Date, allDay: Bool, title: String,
                         start: Date, end: Date)
        case eventDelete(id: String, title: String, start: Date, end: Date, allDay: Bool)
        /// Slice 8f (decisions 3–7, 10): a new note in Chilk's own «Чилк» folder of Apple Notes. A note has no time: the
        /// card never expires.
        case note(title: String, text: String)
        /// Lines added at the end of one of Chilk's notes; the rest of it stays.
        case noteAppend(id: String, title: String, text: String)
        /// One of Chilk's notes rewritten: the new title and the whole new text (`oldText`: what it replaces).
        case noteRewrite(id: String, oldTitle: String, oldText: String, title: String, text: String)
        case noteDelete(id: String, title: String)
        /// Slice 9b (decisions 9–12): a whole day's plan — one reminder of the «Чилк» list per item, with a time or on the
        /// date only. `already`: titles that are in the plan for that day already (shown, not created again).
        case plan(day: Date, items: [PlanItem], already: [String])
    }

    public let id: UUID
    public var kind: Kind
    /// Decision 8: the part of day was guessed (an hour said without утра / дня / вечера / ночи).
    public var guessedPart: Bool
    /// Decision 8: «завтра» said after midnight — the date is a guess.
    public var guessedDay: Bool

    /// Slice 10: a card that deletes something («удали» answers it with yes).
    public var deletes: Bool {
        switch kind {
        case .reminderDelete, .eventDelete, .noteDelete: true
        default: false
        }
    }

    public init(id: UUID = UUID(), kind: Kind, guessedPart: Bool = false, guessedDay: Bool = false) {
        self.id = id
        self.kind = kind
        self.guessedPart = guessedPart
        self.guessedDay = guessedDay
    }

    /// The time the card sets (nil: it sets none — completing / deleting, a rename, a change of the end only).
    public var when: Date? {
        switch kind {
        case .reminder(_, let due): due
        case .message(_, _, let at): at
        case .reminderChange(_, _, let oldDue, _, let due): due != oldDue ? due : nil
        case .event(_, let start, _, _): start
        case .eventChange(_, _, let oldStart, _, _, _, let start, _): start != oldStart ? start : nil
        case .reminderComplete, .reminderDelete, .timer, .eventDelete, .note, .noteAppend, .noteRewrite, .noteDelete, .plan: nil
        }
    }

    /// A time that has already passed cannot be confirmed («Да» is not offered). An all-day event lasts its whole day.
    public func expired(now: Date, calendar: Calendar = .current) -> Bool {
        func dayOver(_ day: Date) -> Bool { calendar.startOfDay(for: now) > calendar.startOfDay(for: day) }
        switch kind {
        case .event(_, let start, _, true): return dayOver(start)
        case .eventChange(_, _, let oldStart, _, true, _, let start, _): return start != oldStart && dayOver(start)
        case .plan(let day, _, _): return dayOver(day)            // a plan of today stands until the day is over
        default: return (when.map { $0 <= now }) ?? false
        }
    }

    /// Can be edited in the «Изменить» panel (decision 5): title and date/time; completing or deleting cannot.
    public var editable: Bool {
        switch kind {
        case .reminder, .message, .reminderChange, .timer, .event, .eventChange, .note, .noteAppend, .noteRewrite, .plan: true
        case .reminderComplete, .reminderDelete, .eventDelete, .noteDelete: false
        }
    }

    /// The card's lines, in Russian: what, when (weekday, date, 24-hour time), where.
    public func lines(now: Date, calendar: Calendar = .current) -> [String] {
        let fmt = CardFormat(calendar: calendar, now: now)
        func when(_ d: Date) -> String { fmt.when(d, guessedPart: guessedPart, guessedDay: guessedDay) }
        let place = "«Напоминания» → «Чилк»"
        let calendarPlace = "«Календарь» → «Чилк»"
        let notesPlace = "«Заметки» → «Чилк»"
        var out: [String]
        switch kind {
        case .reminder(let title, let due):
            out = ["📝 Напоминание: \(title)", when(due), place]
        case .message(_, let text, let at):
            out = ["💬 Скажу тебе: «\(text)»", when(at), "У меня, если я запущен"]
        case .reminderChange(_, let oldTitle, let oldDue, let title, let due):
            out = ["✏️ Изменить напоминание «\(oldTitle)»"]
            if title != oldTitle { out.append("Название: \(title)") }
            if let due, due != oldDue {
                out.append("Было: " + (oldDue.map { fmt.when($0, guessedPart: false, guessedDay: false) } ?? "без срока"))
                out.append("Станет: " + when(due))
            }
            out.append(place)
        case .reminderComplete(_, let title, let due):
            out = ["✅ Отметить выполненным: \(title)"] + (due.map { [fmt.when($0, guessedPart: false, guessedDay: false)] } ?? [])
                + [place]
        case .reminderDelete(_, let title, let due):
            out = ["🗑 Удалить напоминание: \(title)"] + (due.map { [fmt.when($0, guessedPart: false, guessedDay: false)] } ?? [])
                + [place]
        case .timer(let title, let seconds):
            // Counted from «Да»: the ring time shown is «if you say yes now».
            out = ["⏱ Таймер: \(title)", Self.duration(seconds) + " — до " + fmt.time(now.addingTimeInterval(Double(seconds))),
                   "«Часы»"]
        case .event(let title, let start, let end, let allDay):
            out = ["📅 Событие: \(title)", fmt.span(start, end, allDay: allDay, guessedPart: guessedPart, guessedDay: guessedDay),
                   calendarPlace]
        case .eventChange(_, let oldTitle, let oldStart, let oldEnd, let allDay, let title, let start, let end):
            out = ["✏️ Изменить событие «\(oldTitle)»"]
            if title != oldTitle { out.append("Название: \(title)") }
            if start != oldStart || end != oldEnd {
                out.append("Было: " + fmt.span(oldStart, oldEnd, allDay: allDay, guessedPart: false, guessedDay: false))
                out.append("Станет: " + fmt.span(start, end, allDay: allDay, guessedPart: guessedPart, guessedDay: guessedDay))
            }
            out.append(calendarPlace)
        case .eventDelete(_, let title, let start, let end, let allDay):
            out = ["🗑 Удалить событие: \(title)", fmt.span(start, end, allDay: allDay, guessedPart: false, guessedDay: false),
                   calendarPlace]
        case .note(let title, let text):
            out = ["🗒 Заметка: \(title)"] + Self.excerpt(text) + [notesPlace]
        case .noteAppend(_, let title, let text):
            out = ["➕ Дописать в заметку «\(title)»"] + Self.excerpt(text) + [notesPlace]
        case .noteRewrite(_, let oldTitle, let oldText, let title, let text):
            out = ["✏️ Изменить заметку «\(oldTitle)»"] + (title != oldTitle ? ["Название: \(title)"] : [])
                + Self.excerpt(oldText, prefix: "Было: ", limit: 120) + Self.excerpt(text, prefix: "Станет: ") + [notesPlace]
        case .noteDelete(_, let title):
            out = ["🗑 Удалить заметку: \(title)", notesPlace + " · останется в «Недавно удалённых»"]
        case .plan(let day, let items, let already):
            out = Self.planLines(day: day, items: items, already: already, now: now, calendar: calendar) + [place]
        }
        if expired(now: now, calendar: calendar) { out.append("Время уже прошло — измени его") }
        return out
    }

    /// «Завтра (Чт, 8 окт.), 10:00» — without the guess marks (the result line after «Да»).
    public func whenText(_ d: Date, now: Date, calendar: Calendar = .current) -> String {
        CardFormat(calendar: calendar, now: now).when(d, guessedPart: false, guessedDay: false)
    }

    /// An event's slot without the guess marks (the result line after «Да»): «Пт, 9 окт., 15:00–16:00»,
    /// «Сб, 10 окт. · весь день».
    public func spanText(start: Date, end: Date, allDay: Bool, now: Date, calendar: Calendar = .current) -> String {
        CardFormat(calendar: calendar, now: now).span(start, end, allDay: allDay, guessedPart: false, guessedDay: false)
    }

    /// Slice 8e: an all-day slot moved to `day` — as many whole days as `start` … `end` covered (`end` exclusive, or
    /// EventKit's 23:59:59 of the last day); the new `end` is exclusive.
    public static func allDaySlot(movedTo day: Date, start: Date, end: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let s = calendar.startOfDay(for: day)
        let days = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: end.addingTimeInterval(1)).day ?? 1)
        return (s, calendar.date(byAdding: .day, value: days, to: s) ?? s.addingTimeInterval(Double(days) * 86400))
    }

    /// Slice 8e: an event moved to `to` (the day, or the moment the user meant): the length stays unless `minutes` is
    /// said; a whole day moves by whole days; `dayOnly` (a bare date, «перенеси на пятницу») keeps an event's time of
    /// day. nil — the new start lies in the past; the same start is fine (lengthening an event that is on now).
    public static func movedSlot(start: Date, end: Date, allDay: Bool, to: Date, minutes: Int?, now: Date, dayOnly: Bool = false,
                                 calendar: Calendar = .current) -> (start: Date, end: Date)? {
        var to = to
        if dayOnly && !allDay {
            let t = calendar.dateComponents([.hour, .minute, .second], from: start)
            to = calendar.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: t.second ?? 0, of: to) ?? to
        }
        if allDay {
            let slot = allDaySlot(movedTo: to, start: start, end: end, calendar: calendar)
            let same = slot.start == calendar.startOfDay(for: start)
            return same || slot.start >= calendar.startOfDay(for: now) ? slot : nil
        }
        guard to == start || to > now.addingTimeInterval(30) else { return nil }
        return (to, to.addingTimeInterval(minutes.map { Double($0) * 60 } ?? end.timeIntervalSince(start)))
    }

    /// For the model (English, like other tool results): what the card shows.
    public func summary(calendar: Calendar = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = calendar.timeZone
        let day = ISO8601DateFormatter()
        day.timeZone = calendar.timeZone
        day.formatOptions = [.withFullDate]
        switch kind {
        case .reminder(let title, let due): return "new reminder «\(title)» at \(f.string(from: due))"
        case .message(_, let text, let at): return "Chilk says «\(text)» at \(f.string(from: at))"
        case .reminderChange(_, let oldTitle, _, let title, let due):
            return "change reminder «\(oldTitle)» → «\(title)»" + (due.map { " at \(f.string(from: $0))" } ?? "")
        case .reminderComplete(_, let title, _): return "mark reminder «\(title)» done"
        case .reminderDelete(_, let title, _): return "delete reminder «\(title)»"
        case .timer(let title, let seconds): return "Clock timer «\(title)» for \(seconds) s"
        case .event(let title, let start, let end, let allDay):
            return allDay ? "new all-day calendar event «\(title)» on \(day.string(from: start))"
                          : "new calendar event «\(title)» \(f.string(from: start)) – \(f.string(from: end))"
        case .eventChange(_, let oldTitle, _, _, let allDay, let title, let start, let end):
            return "change calendar event «\(oldTitle)» → «\(title)» "
                + (allDay ? "on \(day.string(from: start))" : "\(f.string(from: start)) – \(f.string(from: end))")
        case .eventDelete(_, let title, _, _, _): return "delete calendar event «\(title)»"
        // The text too: a correction turn sees the card as it is now, edits in «Изменить» included.
        case .note(let title, let text): return "new note «\(title)» in Notes → «Чилк»: «\(text)»"
        case .noteAppend(_, let title, let text): return "append to note «\(title)»: «\(text)»"
        case .noteRewrite(_, let oldTitle, _, let title, let text): return "rewrite note «\(oldTitle)» → «\(title)»: «\(text)»"
        case .noteDelete(_, let title): return "delete note «\(title)»"
        case .plan(let day, let items, let already):
            let (timed, untimed) = PlanDay.ordered(items)
            var parts = timed.map { "\($0.time!.text) «\($0.title)»" + ($0.guessed ? " (guessed time)" : "") }
            parts += untimed.map { "no time «\($0.title)»" }
            return "day plan for \(PlanDay.iso(day, calendar: calendar)) (\(PlanDay.title(day, now: Date(), calendar: calendar))): "
                + parts.joined(separator: "; ") + (already.isEmpty ? "" : "; already in the plan: " + already.map { "«\($0)»" }.joined(separator: ", "))
        }
    }

    /// Decision 12: «🗓 План на четверг, 9 октября», the timed items by time (guesses marked), «Без времени: …»,
    /// «Уже в плане: …». A time of today that has passed is written without a time — the card says so.
    static func planLines(day: Date, items: [PlanItem], already: [String], now: Date, calendar: Calendar) -> [String] {
        var out = ["🗓 План на " + PlanDay.title(day, now: now, calendar: calendar, accusative: true)]
        let (timed, untimed) = PlanDay.ordered(items)
        for item in timed.prefix(PlanDay.cardTimedLines) {
            let t = item.time!
            var line = t.text + (item.guessed ? " · " + CardFormat.part(t.hour) + "?" : "") + " — " + item.title
            if PlanDay.passed(item, day: day, now: now, calendar: calendar) { line += " · уже прошло, без времени" }
            out.append(line)
        }
        if timed.count > PlanDay.cardTimedLines { out.append("…и ещё \(timed.count - PlanDay.cardTimedLines) со временем") }
        if !untimed.isEmpty { out.append("Без времени: " + untimed.map(\.title).joined(separator: ", ")) }
        if !already.isEmpty { out.append("Уже в плане: " + already.joined(separator: ", ")) }
        return out
    }

    /// Slice 8f: a note's text on the card — its lines joined by « / », at most `limit` characters («…» when cut; the
    /// whole text is in «Изменить»). An empty text shows no line.
    static func excerpt(_ text: String, prefix: String = "", limit: Int = 240) -> [String] {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }
        let joined = lines.joined(separator: " / ")
        guard joined.count > limit else { return [prefix + joined] }
        return [prefix + String(joined.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"]
    }

    /// «45 с», «5 мин», «1 ч 30 мин», «2 ч», «1 д 2 ч».
    public static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s) с" }
        let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60, sec = s % 60
        var parts: [String] = []
        if d > 0 { parts.append("\(d) д") }
        if h > 0 { parts.append("\(h) ч") }
        if m > 0 { parts.append("\(m) мин") }
        if sec > 0, d == 0, h == 0 { parts.append("\(sec) с") }
        return parts.joined(separator: " ")
    }
}

/// «Пт, 9 окт., 10:00», «сегодня, 17:30», «завтра, 10:00 · утро?».
struct CardFormat {
    let calendar: Calendar
    let now: Date

    private func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = format
        return f
    }

    private func hm(_ d: Date) -> String { formatter("HH:mm").string(from: d) }

    /// «Пт, 9 окт.», «Сегодня (Ср, 7 окт.)», «Завтра (Чт, 8 окт.)»; another year — «Пт, 9 окт. 2027».
    private func day(_ d: Date) -> String {
        var date = formatter(calendar.isDate(d, equalTo: now, toGranularity: .year) ? "EEEEEE, d MMM" : "EEEEEE, d MMM yyyy")
            .string(from: d)
        date = date.prefix(1).uppercased() + date.dropFirst()
        if calendar.isDate(d, inSameDayAs: now) { return "Сегодня (\(date))" }
        if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(d, inSameDayAs: t) { return "Завтра (\(date))" }
        return date
    }

    /// «23:52», «01:10 завтра», further — «Пт, 9 окт., 10:00».
    func time(_ d: Date) -> String {
        if calendar.isDate(d, inSameDayAs: now) { return hm(d) }
        if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(d, inSameDayAs: t) {
            return hm(d) + " завтра"
        }
        return when(d, guessedPart: false, guessedDay: false)
    }

    func when(_ d: Date, guessedPart: Bool, guessedDay: Bool) -> String {
        var text = day(d) + (guessedDay ? "?" : "") + ", " + hm(d)
        if guessedPart { text += " · " + Self.part(calendar.component(.hour, from: d)) + "?" }
        return text
    }

    /// Slice 8e: an event's slot — «Пт, 9 окт., 15:00–16:00», over midnight «Пт, 9 окт., 23:00 – Сб, 10 окт., 01:00»,
    /// all day «Сб, 10 окт. · весь день» (several days: «Сб, 10 окт. – Пн, 12 окт. · весь день»). `end` is exclusive.
    func span(_ start: Date, _ end: Date, allDay: Bool, guessedPart: Bool, guessedDay: Bool) -> String {
        let mark = guessedDay ? "?" : ""
        if allDay {
            let last = end > start ? end.addingTimeInterval(-1) : start
            let days = calendar.isDate(last, inSameDayAs: start) ? day(start) + mark : day(start) + mark + " – " + day(last)
            return days + " · весь день"
        }
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))
        var text = day(start) + mark + ", " + hm(start)
        if calendar.isDate(end, inSameDayAs: start) || end == midnight { text += "–" + hm(end) }
        else { text += " – " + day(end) + ", " + hm(end) }
        if guessedPart { text += " · " + Self.part(calendar.component(.hour, from: start)) + "?" }
        return text
    }

    static func part(_ hour: Int) -> String {
        switch hour {
        case 5..<12: "утро"
        case 12..<17: "день"
        case 17..<23: "вечер"
        default: "ночь"
        }
    }
}

/// Decision 4: a spoken or typed answer while a card is on screen.
public enum CardAnswer: Equatable, Sendable {
    case yes
    case no
    /// Anything else is a correction: a new model turn with the card in [контекст].
    case correction(String)

    private static let yesWords: Set<String> = ["да", "ставь", "давай", "ага", "угу", "конечно", "подтверждаю",
                                                "подтверди", "ок", "окей", "хорошо", "верно", "точно", "ладно",
                                                "го", "yes", "ok", "okay", "сохраняй", "записывай", "делай", "удаляй",
                                                "меняй", "отмечай", "переноси", "согласен", "согласна", "именно"]
    private static let noWords: Set<String> = ["нет", "отмена", "отмени", "отбой", "неа", "передумал", "передумала",
                                               "no", "забудь", "стоп"]
    /// Only right after «не»: «не надо», «не нужно», «не ставь» («нет, надо» is not a «нет»).
    private static let afterNot: Set<String> = ["надо", "нужно", "ставь", "делай", "записывай"]
    /// Words that do not change the meaning: the address, politeness, fillers.
    private static let neutral: Set<String> = ["чилк", "чилка", "эй", "пожалуйста", "спасибо", "ну", "а", "так",
                                               "вот", "всё", "все", "уж"]

    /// Slice 10, decision 10: an assent verb in any imperative or the infinitive — «запиши», «записать», «пиши», «сохрани»,
    /// «поставь», «записывай»… — by its stem plus such an ending («пишут», «ставка», «записал», «удалось» are not assent).
    /// «удал-» says yes only to a card that deletes.
    private static let yesStems: [String] = ["пиш", "напиш", "запиш", "допиш", "запис", "сохран", "добав", "став",
                                             "постав", "отправ", "перенес", "перенос", "отмеч", "отмет", "сдела", "созда"]
    private static let deleteStems: [String] = ["удал"]
    private static let endings: [String] = ["и", "ите", "й", "йте", "ть", "ь", "ьте"]
    private static let yesExtra: Set<String> = ["можно", "валяй", "вперед", "разрешаю", "разрешаем", "погнали"]
    /// Slice 10: the words that only point at the card («запиши её», «да, сохрани заметку»).
    private static let pointers: Set<String> = ["я", "это", "ее", "его", "их", "заметку", "напоминание", "дело", "дела",
                                                "план", "событие", "таймер"]

    static func isYes(_ word: String, deleting: Bool = false) -> Bool {
        if yesWords.contains(word) || yesExtra.contains(word) { return true }
        guard endings.contains(where: { word.hasSuffix($0) }) else { return false }
        return (deleting ? yesStems + deleteStems : yesStems).contains { word.hasPrefix($0) }
    }

    /// `deleting`: the card on screen deletes something («удали» then says yes).
    public static func parse(_ text: String, deleting: Bool = false) -> CardAnswer {
        // A question is not an answer («точно?», «да?»): the model explains, the card stays.
        if text.contains("?") { return .correction(text) }
        let words = text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let meaningful = words.filter { !neutral.contains($0) && !pointers.contains($0) }
        guard !meaningful.isEmpty else { return .correction(text) }
        if isNo(meaningful) { return .no }
        return meaningful.allSatisfy { isYes($0, deleting: deleting) } ? .yes : .correction(text)
    }

    /// Every word says «no»: a «нет» word, or «не» followed by «надо / нужно / ставь…».
    private static func isNo(_ words: [String]) -> Bool {
        var i = 0
        while i < words.count {
            if noWords.contains(words[i]) { i += 1; continue }
            // «не надо», «не ставь», and (slice 10) «не сохраняй», «не пиши» — «не» before an assent verb.
            if words[i] == "не", i + 1 < words.count, afterNot.contains(words[i + 1]) || isYes(words[i + 1], deleting: true) {
                i += 2; continue
            }
            return false
        }
        return true
    }
}

/// Decision «несколько карточек — по очереди»: the first is shown; a correction's card takes its place.
public struct CardQueue: Equatable, Sendable {
    public private(set) var cards: [ActionCard] = []
    public init() {}

    public var current: ActionCard? { cards.first }
    public var isEmpty: Bool { cards.isEmpty }

    /// A new card. `replacingCurrent`: a correction of the card on screen (its place in the queue).
    public mutating func add(_ card: ActionCard, replacingCurrent: Bool) {
        if replacingCurrent, !cards.isEmpty { cards[0] = card } else { cards.append(card) }
    }

    /// The current card was answered (or edited into another): it leaves; returns the next one.
    @discardableResult
    public mutating func settle(_ id: UUID) -> ActionCard? {
        cards.removeAll { $0.id == id }
        return cards.first
    }

    public mutating func replace(_ id: UUID, with card: ActionCard) {
        if let i = cards.firstIndex(where: { $0.id == id }) { cards[i] = card }
    }
}
