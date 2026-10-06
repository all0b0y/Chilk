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
        String(localized: "Слух сломался 😕 Нажми \(Hotkey.label) или включи уши заново в трее")
    }
    static let brainSignedOut = String(localized: "Я ещё не подключён к Codex. Нажми на меня в трее наверху → «Войти в Codex»")
    static let brainMissing = String(localized: "Не нашёл Codex на этом Mac 😕")
    static let brainFailed = String(localized: "Codex сейчас не отвечает 😕 Попробуй чуть позже")

    /// A due local timer (slice 3c.2): Chilk's own line, so the alarm clock is allowed.
    static func timerDue(_ title: String) -> String { String(localized: "⏰ Время: \(title)") }

    /// Chilk asks for a folder the user named (decision 2026-10-05). The folder is the real, resolved one; the
    /// reason is model-written, so it is cleaned and shortened.
    static func mayILook(_ folder: String, reason: String) -> String {
        var why = Dialogue.plain(reason)
        if why.count > 100 { why = String(why.prefix(100)) + "…" }
        if let first = why.first { why = first.uppercased() + why.dropFirst() }
        return String(localized: "Можно я загляну в «\(folder)»? \(why)")
    }
    static let yes = String(localized: "Да")
    static let no = String(localized: "Нет")

    /// [контекст] for Codex: only time, sitting time and the name the user gave him (В24), nothing about apps or windows.
    /// Slice 4b: plus the request on screen, its limits and the focus (`BalanceEngine.brief`), so Codex can judge.
    static func context(sittingMinutes: Int, name: String? = nil, balance: BalanceBrief? = nil, now: Date = Date()) -> String {
        VoiceContext.text(sittingMinutes: sittingMinutes, now: now, name: name, balance: balance)
    }
}
