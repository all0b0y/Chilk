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
    }

    public let id: UUID
    public var kind: Kind
    /// Decision 8: the part of day was guessed (an hour said without утра / дня / вечера / ночи).
    public var guessedPart: Bool
    /// Decision 8: «завтра» said after midnight — the date is a guess.
    public var guessedDay: Bool

    public init(id: UUID = UUID(), kind: Kind, guessedPart: Bool = false, guessedDay: Bool = false) {
        self.id = id
        self.kind = kind
        self.guessedPart = guessedPart
        self.guessedDay = guessedDay
    }

    /// The time the card sets (nil: it sets none — completing / deleting).
    public var when: Date? {
        switch kind {
        case .reminder(_, let due): due
        case .message(_, _, let at): at
        case .reminderChange(_, _, let oldDue, _, let due): due != oldDue ? due : nil
        case .reminderComplete, .reminderDelete, .timer: nil
        }
    }

    /// A time that has already passed cannot be confirmed («Да» is not offered).
    public func expired(now: Date) -> Bool { (when.map { $0 <= now }) ?? false }

    /// Can be edited in the «Изменить» panel (decision 5): title and date/time; completing or deleting cannot.
    public var editable: Bool {
        switch kind {
        case .reminder, .message, .reminderChange, .timer: true
        case .reminderComplete, .reminderDelete: false
        }
    }

    /// The card's lines, in Russian: what, when (weekday, date, 24-hour time), where.
    public func lines(now: Date, calendar: Calendar = .current) -> [String] {
        let fmt = CardFormat(calendar: calendar, now: now)
        func when(_ d: Date) -> String { fmt.when(d, guessedPart: guessedPart, guessedDay: guessedDay) }
        let place = "«Напоминания» → «Чилк»"
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
        }
        if expired(now: now) { out.append("Время уже прошло — измени его") }
        return out
    }

    /// «Завтра (Чт, 8 окт.), 10:00» — without the guess marks (the result line after «Да»).
    public func whenText(_ d: Date, now: Date, calendar: Calendar = .current) -> String {
        CardFormat(calendar: calendar, now: now).when(d, guessedPart: false, guessedDay: false)
    }

    /// For the model (English, like other tool results): what the card shows.
    public func summary(calendar: Calendar = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = calendar.timeZone
        switch kind {
        case .reminder(let title, let due): return "new reminder «\(title)» at \(f.string(from: due))"
        case .message(_, let text, let at): return "Chilk says «\(text)» at \(f.string(from: at))"
        case .reminderChange(_, let oldTitle, _, let title, let due):
            return "change reminder «\(oldTitle)» → «\(title)»" + (due.map { " at \(f.string(from: $0))" } ?? "")
        case .reminderComplete(_, let title, _): return "mark reminder «\(title)» done"
        case .reminderDelete(_, let title, _): return "delete reminder «\(title)»"
        case .timer(let title, let seconds): return "Clock timer «\(title)» for \(seconds) s"
        }
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

    /// «23:52», «01:10 завтра», further — «Пт, 9 окт., 10:00».
    func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "HH:mm"
        if calendar.isDate(d, inSameDayAs: now) { return f.string(from: d) }
        if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(d, inSameDayAs: t) {
            return f.string(from: d) + " завтра"
        }
        return when(d, guessedPart: false, guessedDay: false)
    }

    func when(_ d: Date, guessedPart: Bool, guessedDay: Bool) -> String {
        let time = DateFormatter()
        time.locale = Locale(identifier: "ru_RU")
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.dateFormat = "HH:mm"
        let day = DateFormatter()
        day.locale = Locale(identifier: "ru_RU")
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.dateFormat = calendar.isDate(d, equalTo: now, toGranularity: .year) ? "EEEEEE, d MMM" : "EEEEEE, d MMM yyyy"
        var date = day.string(from: d)
        date = date.prefix(1).uppercased() + date.dropFirst()
        if calendar.isDate(d, inSameDayAs: now) { date = "Сегодня (\(date))" }
        else if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(d, inSameDayAs: t) { date = "Завтра (\(date))" }
        var text = (guessedDay ? date + "?" : date) + ", " + time.string(from: d)
        if guessedPart { text += " · " + Self.part(calendar.component(.hour, from: d)) + "?" }
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

    public static func parse(_ text: String) -> CardAnswer {
        // A question is not an answer («точно?», «да?»): the model explains, the card stays.
        if text.contains("?") { return .correction(text) }
        let words = text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let meaningful = words.filter { !neutral.contains($0) }
        guard !meaningful.isEmpty else { return .correction(text) }
        if isNo(meaningful) { return .no }
        return meaningful.allSatisfy(yesWords.contains) ? .yes : .correction(text)
    }

    /// Every word says «no»: a «нет» word, or «не» followed by «надо / нужно / ставь…».
    private static func isNo(_ words: [String]) -> Bool {
        var i = 0
        while i < words.count {
            if noWords.contains(words[i]) { i += 1; continue }
            if words[i] == "не", i + 1 < words.count, afterNot.contains(words[i + 1]) { i += 2; continue }
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
