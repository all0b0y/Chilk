import ChilkCore
import Foundation

/// Words of the chat window and the memory panel (slice 5b).
extension Lines {
    static let chatTitle = String(localized: "Чат с Чилком")
    static let chatUntitled = String(localized: "Без названия")
    static let chatNoChats = String(localized: "Чатов пока нет")
    static let chatEmpty = String(localized: "Напиши Чилку или позови голосом — здесь будет вся переписка. Голос сохраняется только текстом.")
    static let chatPlaceholder = String(localized: "Написать Чилку…")
    static let chatListening = String(localized: "Слушаю… пауза — и отправлю")
    static let chatVoiceBusy = String(localized: "Чилк отвечает голосом…")
    static let chatThinking = String(localized: "Думаю…")
    static let chatFailed = String(localized: "Codex сейчас не ответил. Текст вернул в поле — попробуй ещё раз")
    static let chatMicFailed = String(localized: "Микрофон не включился — проверь доступ в Системных настройках")
    static let chatMicHelp = String(localized: "Сказать голосом: пауза ~1,5 с или повторное нажатие отправляет")
    static let chatViaVoice = String(localized: "Сказано голосом")
    static let chatDelete = String(localized: "Удалить чат")
    static let chatDeleteQuestion = String(localized: "Удалить этот чат?")
    static let chatDeleteNote = String(localized: "Переписка хранится только у Чилка — удалится насовсем.")

    static let memoryTitle = String(localized: "Память")
    static let memoryHelp = String(localized: "Что Чилк помнит о тебе между разговорами. Уходит в Codex в начале каждого нового разговора. Пароли и номера карт не сохраняются.")
    static let memoryEmpty = String(localized: "Пока ничего. Скажи «Чилк, запомни…»")
    static let memoryNew = String(localized: "Новый факт, например «пьёт чай без сахара»")
    static let memoryAdd = String(localized: "Добавить")
    static let memorySave = String(localized: "Сохранить")
    static let memoryEdit = String(localized: "Изменить")
    static let memoryForget = String(localized: "Забыть")
    static let memorySelfNoted = String(localized: "сам запомнил")

    /// Why a fact was not kept (`nil` = kept).
    static func memoryOutcome(_ o: MemoryBook.Outcome) -> String? {
        switch o {
        case .added: nil
        case .duplicate: String(localized: "Это я уже помню")
        case .full: String(localized: "Память полная — 50 фактов. Убери что-нибудь")
        case .tooLong: String(localized: "Слишком длинно — до 200 знаков")
        case .empty: String(localized: "Пусто")
        case .looksSecret: String(localized: "Похоже на пароль, код или номер — такое не храню")
        }
    }

    // MARK: Chips (decision 14)

    static func chipTitle(_ c: ChatChip) -> String {
        let s = c.subject ?? ""
        let title: String = switch c.kind {
        case .timer:
            if let m = c.minutes { s.isEmpty ? String(localized: "Таймер · \(m) мин") : String(localized: "Таймер «\(s)» · \(m) мин") }
            else if let at = c.at { String(localized: "Таймер «\(s)» · \(when(at))") }
            else { String(localized: "Таймер") }
        case .cancelTimer: String(localized: "Отменил сообщение")
        case .openClock: String(localized: "Открыл «Часы»")
        case .reminder:
            if let at = c.at { String(localized: "Напоминание «\(s)» · \(when(at))") } else { String(localized: "Напоминание") }
        case .event:
            if let at = c.at { String(localized: "Событие «\(s)» · \(when(at))") } else { String(localized: "Событие") }
        case .webSearch: String(localized: "Искал в интернете")
        case .findFiles: String(localized: "Искал файлы")
        case .readFile: s.isEmpty ? String(localized: "Читал файл") : String(localized: "Прочитал «\(s)»")
        case .requestFolder: s.isEmpty ? String(localized: "Попросил папку") : String(localized: "Попросил папку «\(s)»")
        case .mode: BalanceMode(rawValue: s).map { String(localized: "Режим: \(modeName($0))") } ?? String(localized: "Режим")
        case .water: String(localized: "Засчитал воду")
        case .takeBreak:
            switch s {
            case "eyeGym": String(localized: "Гимнастика для глаз")
            case "warmup": String(localized: "Разминка")
            case "walk": String(localized: "Прогулка")
            case "breathe": String(localized: "Подышать \(c.minutes ?? 1) мин")
            default: String(localized: "Перерыв")
            }
        case .remember: String(localized: "Запомнил")
        case .deferRequest:
            if let m = c.minutes, let need = Need(rawValue: s) { String(localized: "Отложил «\(requestName(need))» · \(m) мин") }
            else { String(localized: "Отсрочка") }
        case .focus:
            if let at = c.at { String(localized: "Фокус до \(at.formatted(date: .omitted, time: .shortened))") } else { String(localized: "Фокус") }
        case .endFocus: c.failed ? String(localized: "Закончить фокус") : String(localized: "Фокус закончен")
        case .game:
            c.failed ? String(localized: "Игра") : (GameKind(rawValue: s).map(GameLines.name) ?? String(localized: "Игра"))
        case .hide:
            s == "hidden"
                ? (c.failed ? String(localized: "Спрятаться") : String(localized: "Спрятался за край"))
                : (c.failed ? String(localized: "Выйти из-за края") : String(localized: "Вышел из-за края"))
        }
        return c.failed ? String(localized: "\(title) — не вышло") : title
    }

    static func chipIcon(_ c: ChatChip) -> String {
        switch c.kind {
        case .timer: "timer"
        case .cancelTimer: "xmark.circle"
        case .openClock: "timer"
        case .reminder: "checklist"
        case .event: "calendar"
        case .webSearch: "globe"
        case .findFiles: "magnifyingglass"
        case .readFile: "doc.text"
        case .requestFolder: "folder.badge.questionmark"
        case .mode: "dial.medium"
        case .water: "drop"
        case .takeBreak: "figure.cooldown"
        case .remember: "brain"
        case .deferRequest: "clock.arrow.circlepath"
        case .focus, .endFocus: "scope"
        case .hide: "rectangle.righthalf.inset.filled.arrow.right"
        case .game: "gamecontroller"
        }
    }

    /// «17:00» today, «пт, 9 окт., 15:00» otherwise.
    private static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}
