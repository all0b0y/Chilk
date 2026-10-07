import Foundation

/// When to stop listening after «Чилк» / the hotkey (В30): a pause after speech, nothing said at all, or too long.
/// Driven by transcript changes (the dictation keeps refining words for a moment after the voice stops).
///
/// Slice 8b (decision 1, «умная пауза»): a finished phrase ends after 2 s without new words (was 1.5 s, and 1.05 s
/// after a final segment — the speed-up is gone). A phrase that stops on a preposition or a conjunction («…на»,
/// «…о том что», «…и»), or a voice the microphone hears without new words («э-э-э»), waits up to 4 s. Any new word
/// starts the count again. A whole phrase may last 45 s (was 25).
public struct EndOfSpeech: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case keepListening
        case done
        case nothingHeard
        case tooLong
    }

    public var pauseAfterSpeech: TimeInterval = 2
    public var pauseWhenUnfinished: TimeInterval = 4
    public var nothingHeardAfter: TimeInterval = 7
    public var maxDuration: TimeInterval = 45
    public private(set) var started: TimeInterval
    public private(set) var lastChange: TimeInterval?
    public private(set) var text = ""
    /// The microphone heard a voice after the last new word (not the tail of that word: dictation lags ~0.3 s).
    public private(set) var voiceWithoutWords = false
    private static let lag: TimeInterval = 0.4

    public init(start: TimeInterval) {
        self.started = start
    }

    public mutating func heard(_ text: String, isFinal: Bool, at t: TimeInterval) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean != self.text {
            self.text = clean
            lastChange = t
            voiceWithoutWords = false
        }
    }

    /// The microphone hears a voice now (VAD), whatever the dictation makes of it.
    public mutating func voice(at t: TimeInterval) {
        guard let last = lastChange, !text.isEmpty, t - last >= Self.lag else { return }
        voiceWithoutWords = true
    }

    /// The silence he waits for now: longer after an unfinished phrase or a voice without words.
    public var pause: TimeInterval {
        voiceWithoutWords || Self.endsUnfinished(text) ? pauseWhenUnfinished : pauseAfterSpeech
    }

    public func verdict(at t: TimeInterval) -> Verdict {
        if t - started >= maxDuration { return text.isEmpty ? .nothingHeard : .tooLong }
        guard let last = lastChange, !text.isEmpty else {
            return t - started >= nothingHeardAfter ? .nothingHeard : .keepListening
        }
        return t - last >= pause ? .done : .keepListening
    }

    /// How far the current pause has gone, 0…1 (his ears droop while he waits); nil before any words.
    public func waited(at t: TimeInterval) -> Double? {
        guard let last = lastChange, !text.isEmpty else { return nil }
        return min(1, max(0, (t - last) / pause))
    }

    /// Words a Russian phrase does not end on: prepositions, conjunctions, «ну / типа / короче».
    static let unfinishedWords: Set<String> = [
        "в", "во", "на", "о", "об", "обо", "по", "к", "ко", "с", "со", "у", "за", "из", "от", "до", "для", "про", "при",
        "без", "над", "под", "через", "между", "перед", "после", "около", "возле", "вокруг", "среди", "насчёт", "насчет",
        "и", "а", "но", "или", "либо", "что", "чтобы", "если", "когда", "потому", "поэтому", "так", "как", "где", "куда",
        "пока", "хотя", "чем", "ни", "то", "ну", "типа", "короче", "значит", "это", "который", "которая", "которое",
        "которые", "мой", "моя", "моё", "мое", "мои", "мне", "меня",
    ]

    public static func endsUnfinished(_ text: String) -> Bool {
        let last = text.lowercased().split { !$0.isLetter }.last.map(String.init) ?? ""
        return unfinishedWords.contains(last) && !text.trimmingCharacters(in: .whitespaces).hasSuffix("?")
    }

    /// «Чилк, …» / «Эй, Чилк, …» at the start is an address, not part of the request. Apple dictation often
    /// mishears the name (spike 003: «Чел», «Чил»), so those count too — but only as a whole first word.
    public static let addressWords: Set<String> = ["чилк", "чилка", "чил", "чилл", "чел", "чек"]

    public static func stripAddress(_ text: String, allowNameOnly: Bool = false) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func dropWord(_ allowed: Set<String>) -> Bool {
            let word = s.prefix { $0.isLetter }.lowercased()
            let rest = s.dropFirst(word.count)
            guard allowed.contains(word), rest.first.map({ !$0.isLetter }) ?? allowNameOnly else { return false }
            let remainder = String(rest.drop { ",.!?: —-".contains($0) || $0 == " " })
            guard !remainder.isEmpty || allowNameOnly else { return false }
            s = remainder
            return true
        }
        if allowNameOnly, s.lowercased().hasPrefix("и эй") { _ = dropWord(["и"]) }
        let hadHey = dropWord(["эй", "хей"])
        let names = allowNameOnly ? addressWords.union(["чу", "училка", "чилки", "чилку", "чик"]) : addressWords
        if !dropWord(names), hadHey { s = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
