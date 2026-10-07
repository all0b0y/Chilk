import Foundation

/// Slice 6d+ (SPEC Т1–Т4): the user's words about time that leave it open — an hour 1–12 without a part of day
/// («в 3»: 03:00 or 15:00?) and «завтра» said after midnight (today after sleep, or the day after?). Chilk asks first;
/// the app refuses a reminder on such an hour until the user has answered.
public enum ClockWords {
    public enum Conflict: Equatable, Sendable {
        /// The hour the user named without a part of day (1…12).
        case hour(Int)
        /// «завтра» between 00:00 and 04:59.
        case day
    }

    /// Hours 1…12 named without «утра / дня / вечера / ночи» nearby (in order, once each).
    public static func ambiguousHours(in text: String) -> [Int] {
        let t = tokens(text)
        var found: [Int] = []
        for (i, word) in t.enumerated() where prepositions.contains(word) && i + 1 < t.count {
            guard let (hour, last) = hour(after: i, in: t) else { continue }
            let window = t[max(0, i - 3)...min(t.count - 1, last + 3)]
            if window.contains(where: partsOfDay.contains) { continue }
            if !found.contains(hour) { found.append(hour) }
        }
        return found
    }

    /// Does a reminder at `date` (local) take a side the user left open? `question` is the user's latest words.
    public static func conflict(question: String, at date: Date, now: Date, zone: TimeZone) -> Conflict? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return conflict(question: question, hour: cal.component(.hour, from: date), now: now, zone: zone)
    }

    /// The same for the local hour of a tool's timestamp (taken loosely: the model may send one the tool refuses).
    public static func conflict(question: String, hour h: Int, now: Date, zone: TimeZone) -> Conflict? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        if let open = ambiguousHours(in: question).first(where: { $0 % 12 == h % 12 }) { return .hour(open) }
        if cal.component(.hour, from: now) < 5, tokens(question).contains("завтра") { return .day }
        return nil
    }

    /// The local hour of an ISO-8601-ish timestamp: with «Z» or an offset converted to `zone`, without one as written.
    public static func localHour(ofTimestamp text: String, zone: TimeZone) -> Int? {
        let f = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            f.formatOptions = options
            if let d = f.date(from: text) {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = zone
                return cal.component(.hour, from: d)
            }
        }
        guard let r = text.range(of: "T[0-9]{2}:", options: .regularExpression) else { return nil }
        return Int(text[r].dropFirst().prefix(2))
    }

    /// The question back for an open hour (Т1): «В 3 ночи или в 15:00?», «В 8 утра или в 20:00?».
    public static func askBack(hour h: Int) -> String {
        let am = h % 12
        if am == 0 { return "В 12 дня или в 00:00?" }
        return "В \(am) \(am <= 4 ? "ночи" : "утра") или в \(am + 12):00?"
    }

    /// A note for [контекст], or nil.
    /// `dayOpen: false` — the user is answering the «which date» question already (Т4): no day note again.
    public static func hint(for question: String, now: Date, zone: TimeZone, dayOpen: Bool = true) -> String? {
        var notes: [String] = []
        let hours = ambiguousHours(in: question)
        if !hours.isEmpty {
            let pairs = hours.map { h in String(format: "%d — %02d:00 или %02d:00", h, h % 12, h % 12 + 12) }
            notes.append("в словах пользователя час без части суток (\(pairs.joined(separator: "; "))): не спрашивай — возьми вероятное по смыслу и времени сейчас; карточка подтверждения покажет догадку")
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        if dayOpen, cal.component(.hour, from: now) < 5, tokens(question).contains("завтра"),
           let next = cal.date(byAdding: .day, value: 1, to: now) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ru_RU")
            f.timeZone = zone
            f.dateFormat = "d MMMM"
            notes.append("сейчас ночь после полуночи: «завтра» может значить \(f.string(from: now)) (после сна) или \(f.string(from: next)) — не спрашивай, возьми вероятное (обычно \(f.string(from: now))); карточка покажет дату")
        }
        return notes.isEmpty ? nil : notes.joined(separator: "; ")
    }

    /// Slice 8c: dictation glues words («напомнив три» for «напомни в три») — an hour 1…12 anywhere in words that name
    /// no part of day and no 24-hour time still leaves the part of day open (the card marks it, nothing is refused).
    public static func looseOpenHour(in text: String, hour h: Int) -> Bool {
        let t = tokens(text)
        if t.contains(where: partsOfDay.contains) { return false }
        for (i, w) in t.enumerated() {
            let next = i + 1 < t.count ? t[i + 1] : ""
            if unitPrefixes.contains(where: { next.hasPrefix($0) }) || ordinalEnds.contains(next) { continue }
            if let n = clockNumber(w), (1...12).contains(n), n % 12 == h % 12 { return true }
            if let n = hourWords[w], n % 12 == h % 12 { return true }
            for (word, n) in hourWords where w.hasSuffix(word) && w.count > word.count + 2 && n % 12 == h % 12 { return true }
        }
        return false
    }

    /// «завтра» said between 00:00 and 04:59: the date is a guess (slice 8c, decision 8).
    public static func dayOpen(question: String, now: Date, zone: TimeZone) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.component(.hour, from: now) < 5 && tokens(question).contains("завтра")
    }

    // MARK: Words

    private static let prepositions: Set<String> = ["в", "во", "к", "ко", "до", "после", "около", "с", "со", "at", "by", "around"]
    private static let partsOfDay: Set<String> = [
        "утра", "утром", "утро", "дня", "днём", "днем", "вечера", "вечером", "вечер", "ночи", "ночью", "ночь",
        "пополудни", "am", "pm", "morning", "afternoon", "evening", "night", "tonight",
    ]
    private static let hourWords: [String: Int] = [
        "час": 1, "один": 1, "одного": 1, "два": 2, "двух": 2, "двум": 2, "три": 3, "трёх": 3, "трех": 3, "трём": 3,
        "трем": 3, "четыре": 4, "четырёх": 4, "четырех": 4, "четырём": 4, "четырем": 4, "пять": 5, "пяти": 5,
        "шесть": 6, "шести": 6, "семь": 7, "семи": 7, "восемь": 8, "восьми": 8, "девять": 9, "девяти": 9,
        "десять": 10, "десяти": 10, "одиннадцать": 11, "одиннадцати": 11, "двенадцать": 12, "двенадцати": 12,
    ]
    /// «половина третьего» = 2:30: the ordinal names the next hour.
    private static let halfOrdinals: [String: Int] = [
        "первого": 12, "второго": 1, "третьего": 2, "четвёртого": 3, "четвертого": 3, "пятого": 4, "шестого": 5,
        "седьмого": 6, "восьмого": 7, "девятого": 8, "десятого": 9, "одиннадцатого": 10, "двенадцатого": 11,
    ]
    /// A number followed by these is an amount, not a clock time («в 2 раза», «в 3 минуты»).
    private static let unitPrefixes = ["минут", "мин", "секунд", "сек", "раз", "дней", "день", "недел", "месяц", "год",
                                       "лет", "процент", "км", "метр", "кг", "штук", "человек", "серии", "серий",
                                       "minute", "time", "day", "week",
                                       // a date, not a clock time («до 10 октября», «к 8-му числу»)
                                       "январ", "феврал", "март", "апрел", "мая", "июн", "июл", "август", "сентябр",
                                       "октябр", "ноябр", "декабр", "числ"]
    /// «к 8-му», «в 5-й»: an ordinal ending split off by the hyphen.
    private static let ordinalEnds: Set<String> = ["го", "му", "е", "ое", "ого", "ому", "м", "й", "ой", "ый", "я", "ая"]

    /// The open hour named right after the preposition at `i`, and the index of its last word.
    private static func hour(after i: Int, in t: [String]) -> (Int, Int)? {
        let w = t[i + 1]
        let next = i + 2 < t.count ? t[i + 2] : ""
        if unitPrefixes.contains(where: { next.hasPrefix($0) }) || ordinalEnds.contains(next) { return nil }
        if let h = clockNumber(w) { return (1...12).contains(h) ? (h, i + 1) : nil }
        if let h = hourWords[w] { return (h, i + 1) }
        if w.hasPrefix("пол"), let h = halfOrdinals[String(w.dropFirst(3))] { return (h, i + 1) }
        if w.hasPrefix("половин"), let h = halfOrdinals[next] { return (h, i + 2) }
        return nil
    }

    /// «3», «3:30» → 3; «03», «03:00», «15» → nil for 1…12 (a leading zero or 0/13–23 is already explicit).
    private static func clockNumber(_ w: String) -> Int? {
        let head = w.split(separator: ":", maxSplits: 1).first.map(String.init) ?? w
        guard !head.isEmpty, head.count <= 2, head.allSatisfy(\.isASCII), let h = Int(head) else { return nil }
        if head.count == 2, head.hasPrefix("0") { return 0 }        // «03:00» — written as 24-hour time
        return h
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == ":") })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ":")) }
            .filter { !$0.isEmpty }
    }
}
