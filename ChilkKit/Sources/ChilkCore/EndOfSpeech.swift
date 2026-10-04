import Foundation

/// When to stop listening after «Чилк» / the hotkey (В30): a pause after speech, nothing said at all, or too long.
/// Driven by transcript changes (the dictation keeps refining words for a moment after the voice stops).
public struct EndOfSpeech: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case keepListening
        case done
        case nothingHeard
        case tooLong
    }

    public var pauseAfterSpeech: TimeInterval = 1.5
    public var nothingHeardAfter: TimeInterval = 7
    public var maxDuration: TimeInterval = 25
    public private(set) var started: TimeInterval
    public private(set) var lastChange: TimeInterval?
    public private(set) var text = ""
    public private(set) var finalSeen = false

    public init(start: TimeInterval) {
        self.started = start
    }

    public mutating func heard(_ text: String, isFinal: Bool, at t: TimeInterval) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean != self.text {
            self.text = clean
            lastChange = t
        }
        if isFinal { finalSeen = true }
    }

    public func verdict(at t: TimeInterval) -> Verdict {
        if t - started >= maxDuration { return text.isEmpty ? .nothingHeard : .tooLong }
        guard let last = lastChange, !text.isEmpty else {
            return t - started >= nothingHeardAfter ? .nothingHeard : .keepListening
        }
        // A final segment lets him answer a bit sooner; volatile text may still be revised.
        let pause = finalSeen ? pauseAfterSpeech * 0.7 : pauseAfterSpeech
        return t - last >= pause ? .done : .keepListening
    }

    /// «Чилк, …» / «Эй, Чилк, …» at the start is an address, not part of the request. Apple dictation often
    /// mishears the name (spike 003: «Чел», «Чил»), so those count too — but only as a whole first word.
    public static let addressWords: Set<String> = ["чилк", "чилка", "чил", "чилл", "чел", "чек"]

    public static func stripAddress(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func dropWord(_ allowed: Set<String>) -> Bool {
            let word = s.prefix { $0.isLetter }.lowercased()
            let rest = s.dropFirst(word.count)
            guard allowed.contains(word), rest.first.map({ !$0.isLetter }) ?? false else { return false }
            let remainder = String(rest.drop { ",.!?: —-".contains($0) || $0 == " " })
            guard !remainder.isEmpty else { return false }
            s = remainder
            return true
        }
        let hadHey = dropWord(["эй", "хей"])
        if !dropWord(addressWords), hadHey { s = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
