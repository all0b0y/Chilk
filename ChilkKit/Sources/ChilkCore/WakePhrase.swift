import Foundation

/// Strict wake rule from spike 003. Never accept Apple's fuzzy «чел/чилл»: those are ordinary speech.
public enum WakePhrase {
    private static let names: Set<String> = ["чилк", "чилка", "чилку", "чилки"]

    public static func matches(_ text: String) -> Bool {
        request(in: text) != nil
    }

    /// The text after the address («Чилк, …», «Эй, Чилк! …», «И эйчилк, …»); nil = not addressed to him.
    /// Decision 2026-10-05 (MVP): after a wake in background speech this is the request (Whisper heard it right,
    /// Apple dictation replayed from the clip start hears the background before the name).
    public static func request(in text: String) -> String? {
        var tokens: [String] = []
        var cursor = text.startIndex
        while tokens.count < 3, let start = text[cursor...].firstIndex(where: \.isLetter) {
            let end = text[start...].firstIndex { !$0.isLetter } ?? text.endIndex
            tokens += spelled(text[start..<end].lowercased())
            cursor = end
            if isAddress(tokens) { return String(text[end...].drop { !$0.isLetter && !$0.isNumber }) }
        }
        return nil
    }

    private static func isAddress(_ t: [String]) -> Bool {
        switch t.count {
        case 1: names.contains(t[0])
        case 2: t[0] == "эй" && names.contains(t[1])
        case 3: t[0] == "и" && t[1] == "эй" && names.contains(t[2])
        default: false
        }
    }

    /// The request of a voice wake: `heardInCheck` (Whisper's text after the name, continuous speech only) + what
    /// Apple dictated afterwards. Without it Apple replayed the whole phrase, so the address is stripped from it.
    public static func request(heardInCheck: String?, dictated: String) -> String {
        let heard = heardInCheck?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rest = heard.isEmpty ? EndOfSpeech.stripAddress(dictated, allowNameOnly: true)
                                 : dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        let joined = [heard, rest].filter { !$0.isEmpty }.joined(separator: " ")
        guard let first = joined.first else { return "" }
        return first.uppercased() + joined.dropFirst()
    }

    /// Spelling only, never a new sound (bench 3c): Whisper sometimes doubles a letter («Чиллк») or glues the
    /// greeting on («Эйчилк»). Only a word that becomes exactly a name changes; «чилл», «эйчел» stay as they are.
    static func spelled(_ word: String) -> [String] {
        var collapsed = ""
        for c in word where c != collapsed.last { collapsed.append(c) }
        if names.contains(collapsed) { return [collapsed] }
        if collapsed.hasPrefix("эй"), names.contains(String(collapsed.dropFirst(2))) { return ["эй", String(collapsed.dropFirst(2))] }
        return [word]
    }
}
