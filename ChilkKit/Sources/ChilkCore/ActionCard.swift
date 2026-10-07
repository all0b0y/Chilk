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
        case .reminderComplete, .reminderDelete: nil
        }
    }

    /// A time that has already passed cannot be confirmed («Да» is not offered).
    public func expired(now: Date) -> Bool { (when.map { $0 <= now }) ?? false }

    /// Can be edited in the «Изменить» panel (decision 5): title and date/time; completing or deleting cannot.
    public var editable: Bool {
        switch kind {
        case .reminder, .message, .reminderChange: true
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
        }
        if expired(now: now) { out.append("Время уже прошло — измени его") }
        return out
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
        }
    }
}

/// «Пт, 9 окт., 10:00», «сегодня, 17:30», «завтра, 10:00 · утро?».
struct CardFormat {
    let calendar: Calendar
    let now: Date

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
        if calendar.isDateInToday(d) || calendar.isDate(d, inSameDayAs: now) { date = "Сегодня (\(date))" }
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
    private static let noWords: Set<String> = ["нет", "не", "надо", "нужно", "отмена", "отмени", "отбой", "неа",
                                               "ставь", "передумал", "передумала", "no", "забудь", "стоп"]
    /// Words that do not change the meaning: the address, politeness, fillers.
    private static let neutral: Set<String> = ["чилк", "чилка", "эй", "пожалуйста", "спасибо", "ну", "а", "так",
                                               "вот", "всё", "все", "давай", "уж"]

    public static func parse(_ text: String) -> CardAnswer {
        let words = text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let meaningful = words.filter { !neutral.contains($0) || $0 == "давай" }
        guard !meaningful.isEmpty else { return .correction(text) }
        if meaningful.first == "нет" || meaningful.first == "отмена" || meaningful.first == "отбой"
            || meaningful.first == "неа" || meaningful.first == "отмени" || meaningful.first == "передумал"
            || meaningful.first == "передумала" || meaningful.first == "забудь" || meaningful.first == "no"
            || meaningful.starts(with: ["не", "надо"]) || meaningful.starts(with: ["не", "нужно"])
            || meaningful.starts(with: ["не", "ставь"]) {
            return meaningful.allSatisfy(noWords.contains) ? .no : .correction(text)
        }
        return meaningful.allSatisfy(yesWords.contains) ? .yes : .correction(text)
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
