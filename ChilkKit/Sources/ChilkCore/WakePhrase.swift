import Foundation

/// Strict wake rule from spike 003. Never accept Apple's fuzzy «чел/чилл»: those are ordinary speech.
public enum WakePhrase {
    public static func matches(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }.prefix(3).map(String.init)
        let names: Set<String> = ["чилк", "чилка", "чилку", "чилки"]
        guard let first = words.first else { return false }
        if names.contains(first) { return true }
        if first == "эй", words.count > 1 { return names.contains(words[1]) }
        return words.count == 3 && words[0] == "и" && words[1] == "эй" && names.contains(words[2])
    }
}
