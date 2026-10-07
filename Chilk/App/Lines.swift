import ChilkCore
import Foundation

/// Hand-written fallback lines (slice 3 adds Codex-generated batches on top).
enum Lines {
    static let called: [String] = [
        String(localized: "Звал? 👀"),
        String(localized: "Я тут! Слушаю"),
        String(localized: "М? Чем помочь?"),
        String(localized: "Чилк на связи ✨"),
    ]

    static let goodMorning: [String] = [
        String(localized: "Доброе утро! Начнём со стакана воды?"),
        String(localized: "Утречко! Я выспался, а ты?"),
        String(localized: "О, ты пришёл! Доброе утро ☀️"),
    ]

    static let welcomeBack: [String] = [
        String(localized: "С возвращением!"),
        String(localized: "О, ты вернулся! Я чуть-чуть вздремнул"),
        String(localized: "Ура, ты тут! Я скучал"),
    ]

    /// Slice 8a (decision 15): after a real crash, once.
    static func crashed(_ when: CrashNotice.When) -> String {
        switch when {
        case .today(let time): String(localized: "Я упал в \(time) — уже снова тут")
        case .yesterday(let time): String(localized: "Я вчера упал в \(time) — уже снова тут")
        }
    }
}
