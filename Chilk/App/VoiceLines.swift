import Foundation
import ChilkCore

/// Phrases for talking to Чилк (slice 3a).
extension Lines {
    static let listening = String(localized: "Слушаю… 👂")
    static let didntHear = String(localized: "Не расслышал 🙈 Позови ещё раз")
    static let okNevermind = String(localized: "Ладно, проехали 🙂")
    /// Under a long answer's bubble (decision 2026-10-05): opens the panel with all of it.
    static let more = String(localized: "Подробнее")
    static let noMicrophone = String(localized: "Мне нужен микрофон: Настройки → Конфиденциальность → Микрофон → Чилк")
    static let earsFailed = String(localized: "Уши барахлят 😕 Не получилось включить распознавание речи")
    @MainActor static var earsBroken: String {
        String(localized: "Слух сломался 😕 Нажми \(Hotkey.defaultKey.label) или включи уши заново в Dock")
    }
    static let brainSignedOut = String(localized: "Я ещё не подключён к Codex. Меню Dock → «Войти в Codex»")
    static let brainMissing = String(localized: "Не нашёл Codex на этом Mac 😕")
    static let brainFailed = String(localized: "Codex сейчас не отвечает 😕 Попробуй чуть позже")

    /// A due local timer (slice 3c.2): Chilk's own line, so the alarm clock is allowed.
    static func timerDue(_ title: String) -> String { String(localized: "⏰ Время: \(title)") }

    /// [контекст] for Codex: only time and sitting time (В24), nothing about apps or windows.
    static func context(sittingMinutes: Int, now: Date = Date()) -> String {
        VoiceContext.text(sittingMinutes: sittingMinutes, now: now)
    }
}
