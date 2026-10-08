import Foundation
import ChilkCore

/// Slice 5a: the tray popover, the tools and the first meeting (SPEC «Срез 5»).
extension Lines {
    /// Decision 22, the user's own wording (typos and punctuation fixed, split under the 240-character bubble limit).
    static let greeting: [String] = [
        String(localized: "Привет! Меня зовут Чилк."),
        String(localized: "Я умею… ну, ты сам посмотришь — там, наверху ↑. Но самое главное: я буду следить, чтобы ты пил воду, не засиживался и иногда отрывался от работы."),
        String(localized: "Надеюсь, буду тебе помогать. Я не супер навороченный — я для малых задач."),
        String(localized: "Ой, что я всё про себя да про себя. Давай, скажи, как тебя зовут?"),
    ]
    /// The name field sits in the bubble in place of this blank button; its width is the field's width.
    static let nameFieldSlot = String(repeating: "\u{2003}", count: 11)
    static let nameDone = String(localized: "Готово")
    static let nameLater = String(localized: "Позже")
    static let namePlaceholder = String(localized: "Твоё имя")
    static func niceToMeet(_ name: String) -> String { String(localized: "Приятно познакомиться, \(name)!") }
    static let nameRefused = String(localized: "Хм, такое имя я не запомню. Попробуй покороче, без скобок")

    /// Decision 7: his place on the hero card while he is busy at the edge.
    static let heroBusy = String(localized: "Чилк помогает тебе — он не успевает быть везде")

    static let statNames: [Need: String] = [
        .water: String(localized: "Вода"), .stretch: String(localized: "Бодрость"), .eyes: String(localized: "Глаза"),
        .walk: String(localized: "Прогулка"), .endOfDay: String(localized: "Запас дня"),
    ]

    static let statOff = String(localized: "выкл")
    static let softerRefused = String(localized: "Сейчас нельзя — сначала отдохни или экстренный выход")

    // Slice 4b: the focus mode in the popover — «Не беспокоить» since slice 9 (decision 7).
    static let focusMenu = String(localized: "Не беспокоить…")
    static func focusRow(_ until: String) -> String { String(localized: "Не беспокою до \(until)") }
    static let focusEnd = String(localized: "Закончить")
    static func focusHours(_ h: Int) -> String {
        switch h {
        case 1: String(localized: "1 час")
        case 2: String(localized: "2 часа")
        default: String(localized: "3 часа")
        }
    }
    static let focusNotSaved = String(localized: "Не получилось сохранить — режим не включён")
    static let focusSpent = String(localized: "«Не беспокоить» на сегодня кончилось — 4 часа уже были")
    static let focusHelp = String(localized: "Пока включено «Не беспокоить», Чилк только напоминает, не настаивает. Потом всё набравшееся вернётся настойчивее")

    // Slice 9f, decision 37: the chosen model left Codex's list — said by voice / in the chat, and a popover row.
    static func modelUnavailable(_ name: String) -> String {
        String(localized: "Модель «\(name)» недоступна — выбери другую в Настройках → Мозг")
    }
    static let modelUnavailableRow = String(localized: "Модель недоступна")
    static let modelPickAnother = String(localized: "Выбрать другую")

    static func abilityName(_ a: ChilkAbility) -> String {
        switch a {
        case .webSearch: String(localized: "Поиск в интернете")
        case .timers: String(localized: "«Скажи мне в 17:00»")
        case .clock: String(localized: "Таймеры («Часы»)")
        case .reminders: String(localized: "Напоминания Apple")
        case .calendar: String(localized: "Календарь Apple")
        case .notes: String(localized: "Заметки Apple")
        case .files: String(localized: "Файлы")
        case .obsidian: String(localized: "Obsidian")
        case .phrases: String(localized: "Свежие фразы от Codex")
        }
    }
}
