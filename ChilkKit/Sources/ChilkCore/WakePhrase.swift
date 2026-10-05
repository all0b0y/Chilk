import Foundation

/// Strict wake rule from spike 003. Never accept Apple's fuzzy «чел/чилл»: those are ordinary speech.
public enum WakePhrase {
    private static let names: Set<String> = ["чилк", "чилка", "чилку", "чилки"]

    public static func matches(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }.prefix(4).flatMap { spelled(String($0)) }.prefix(3).map { $0 }
        guard let first = words.first else { return false }
        if names.contains(first) { return true }
        if first == "эй", words.count > 1 { return names.contains(words[1]) }
        return words.count == 3 && words[0] == "и" && words[1] == "эй" && names.contains(words[2])
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
