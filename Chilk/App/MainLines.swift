import ChilkCore
import Foundation

/// Slice 5c: the main window (SPEC «Срез 5», decisions 16–21).
extension Lines {
    static let mainTitle = String(localized: "Чилк")

    static func sectionName(_ s: MainSection) -> String {
        switch s {
        case .today: String(localized: "Сегодня")
        case .week: String(localized: "Неделя")
        case .memory: String(localized: "Память")
        case .tools: String(localized: "Инструменты")
        case .settings: String(localized: "Настройки")
        }
    }

    static func sectionIcon(_ s: MainSection) -> String {
        switch s {
        case .today: "sun.max"
        case .week: "chart.bar"
        case .memory: "brain"
        case .tools: "switch.2"
        case .settings: "gearshape"
        }
    }

    /// «3 ч 10 мин», «42 мин», «0 мин».
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return String(localized: "\(m) мин") }
        if m == 0 { return String(localized: "\(h) ч") }
        return String(localized: "\(h) ч \(m) мин")
    }

    // MARK: Сегодня / Неделя

    static let todayStreak = String(localized: "Без перерыва")
    static let todayActive = String(localized: "За день")
    static let todayLeft = String(localized: "Остаток дня")
    static let todayOver = String(localized: "Сверх бюджета")
    static let byNeed = String(localized: "По потребностям")
    static func tally(credited: Int, pushed: Int) -> String {
        String(localized: "засчитано \(credited) · дожимал \(pushed)")
    }
    static let tallyHelp = String(localized: "«Дожимал» — просьба дошла до «настаивает» или снята экстренным выходом.")
    static let deferrals = String(localized: "Отсрочки")
    static let exitsTitle = String(localized: "Экстренные выходы")
    static let noExitsToday = String(localized: "Сегодня не было")
    static let noExitsWeek = String(localized: "За неделю не было")
    static func exitLine(_ e: EmergencyExit) -> String {
        String(localized: "\(name(e.need)) · \(e.minutes) мин")
    }
    static let exitHeld = String(localized: "удержанием")
    static let weekHours = String(localized: "Часы")
    static let weekDay = String(localized: "День")
    static let weekBudget = String(localized: "Бюджет")
    static let weekCaption = String(localized: "Столбик — активное время за Mac, черта — бюджет дня.")
    static let weekTotals = String(localized: "За 7 дней")

    // MARK: Настройки

    static let settingsMode = String(localized: "Режим")
    static let modeHelp = String(localized: "Строгий — до паузы на весь экран, Мягкий — до «настаивает», Тишина — только пантомима.")
    static let care = String(localized: "Забота")
    static let every = String(localized: "Каждые")
    static let minutesOfSitting = String(localized: "мин сидения")
    static let budgetWeekday = String(localized: "Бюджет дня в будни")
    static let budgetWeekend = String(localized: "Бюджет дня в выходные")
    static func hours(_ h: Int) -> String { String(localized: "\(h) ч") }
    static let locked = String(localized: "Сейчас нельзя — сначала отдохни или экстренный выход")
    static let contractHelp = String(localized: "Договор с собой: пока просьба на ступени 3–4, смягчить нельзя, ужесточить — всегда.")

    static let apps = String(localized: "Приложения")
    static let appsHelp = String(localized: "Недавние приложения. Созвон — Чилк молчит, простой не отдых. Не трогать — молчит, пока приложение впереди.")
    static let appsEmpty = String(localized: "Список появится, когда поработаешь в других приложениях.")
    static func categoryName(_ c: AppCategory) -> String {
        switch c {
        case .work: String(localized: "Работа")
        case .leisure: String(localized: "Досуг")
        case .call: String(localized: "Созвон")
        case .untouchable: String(localized: "Не трогать")
        }
    }
    static func automatic(_ c: AppCategory) -> String { String(localized: "Авто (\(categoryName(c).lowercased()))") }

    static let hotkey = String(localized: "Горячая клавиша")
    static let hotkeyCall = String(localized: "Позвать Чилка")
    static let hotkeyChange = String(localized: "Изменить")
    static let hotkeyCancel = String(localized: "Отмена")
    static let hotkeyRecording = String(localized: "Нажми сочетание… (Esc — отмена)")
    static let hotkeyNeedsModifier = String(localized: "Нужен ⌘, ⌃ или ⌥")
    static let hotkeyRefused = String(localized: "Это сочетание занято — осталось прежнее")

    static let screen = String(localized: "Экран")
    static let edgeTitle = String(localized: "Край")
    static let edgeLeft = String(localized: "Левый")
    static let edgeRight = String(localized: "Правый")
    static let monitor = String(localized: "Монитор")
    /// Slice 6f-2: Settings → Приложения, the app's sound counts as music for the disco.
    static let musicApp = String(localized: "Это музыка (для диско)")
    static let followActive = String(localized: "Следовать за активным экраном")
    static func pinnedTo(_ name: String) -> String { String(localized: "Закрепить: \(name)") }
    static func notConnected(_ name: String) -> String { String(localized: "\(name) (не подключён)") }

    static let callMe = String(localized: "Как тебя называть")
    static let save = String(localized: "Сохранить")
    static let nameSaved = String(localized: "Запомнил")
    static let nameCleared = String(localized: "Буду без имени")

    static let chats = String(localized: "Чаты")
    static let deleteInactive = String(localized: "Удалять неактивные")
    static func days(_ d: Int) -> String { String(localized: "через \(d) дн.") }
    static let never = String(localized: "Не удалять")

    static let launchTitle = String(localized: "Запуск")
    static let launchAtLogin = String(localized: "Запускать при входе в систему")
    static let launchNeedsApproval = String(localized: "Нужно разрешить в Системных настройках → Объекты входа")
    static let openLoginItems = String(localized: "Открыть объекты входа")

    static let permissions = String(localized: "Разрешения")
    static func permissionName(_ k: Permissions.Kind) -> String {
        switch k {
        case .microphone: String(localized: "Микрофон")
        case .speech: String(localized: "Распознавание речи")
        case .reminders: String(localized: "Напоминания")
        }
    }
    static func permissionState(_ s: Permissions.State) -> String {
        switch s {
        case .granted: String(localized: "разрешено")
        case .denied: String(localized: "запрещено")
        case .notAsked: String(localized: "ещё не спрашивал")
        }
    }
    static let permissionsHelp = String(localized: "Чилк спрашивает разрешение, когда оно впервые нужно.")
    static let openSystemSettings = String(localized: "Открыть")
}
