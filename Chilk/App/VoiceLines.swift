import Foundation
import ChilkCore

/// Phrases for talking to Чилк (slice 3a).
extension Lines {
    static let listening = String(localized: "Слушаю… 👂")
    static let didntHear = String(localized: "Не расслышал 🙈 Позови ещё раз")
    static let okNevermind = String(localized: "Ладно, проехали 🙂")
    static let noMicrophone = String(localized: "Мне нужен микрофон: Настройки → Конфиденциальность → Микрофон → Чилк")
    static let earsFailed = String(localized: "Уши барахлят 😕 Не получилось включить распознавание речи")
    static let brainSignedOut = String(localized: "Я ещё не подключён к Codex. Меню Dock → «Войти в Codex»")
    static let brainMissing = String(localized: "Не нашёл Codex на этом Mac 😕")
    static let brainFailed = String(localized: "Codex сейчас не отвечает 😕 Попробуй чуть позже")

    /// [контекст] for Codex: only time and sitting time (В24), nothing about apps or windows.
    static func context(sittingMinutes: Int, now: Date = Date()) -> String {
        VoiceContext.text(sittingMinutes: sittingMinutes, now: now)
    }
}
