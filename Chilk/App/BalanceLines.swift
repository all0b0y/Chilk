import ChilkCore
import Foundation

/// Phrases for the balance ladder and breaks (В21, В23): kind, teasing, cheekier on stage 2. No shaming,
/// nothing about looks, weight or health problems. Hand-written library + the day's Codex batch (2026-10-05).
extension Lines {
    /// Today's Codex lines (`PhraseBatches`); `nil` = the hand-written library alone.
    @MainActor static var batch: PhraseBatch?

    static func name(_ n: Need) -> String {
        switch n {
        case .water: String(localized: "Вода")
        case .stretch: String(localized: "Размяться")
        case .eyes: String(localized: "Глаза")
        case .walk: String(localized: "Прогулка")
        case .endOfDay: String(localized: "Конец дня")
        }
    }

    @MainActor static func ask(_ n: Need, stage: Int, again: Bool) -> String {
        if again { return againLines[n]!.randomElement()! }
        let library = stage >= 2 ? insist[n]! : polite[n]!
        return (library + (batch?.lines(for: n, stage: stage) ?? [])).randomElement()!
    }

    static func button(_ r: Reaction, for n: Need) -> String {
        switch (r, n) {
        case (.done, .water): String(localized: "Попил")
        case (.done, _): String(localized: "Сделал")
        case (.going, .walk): String(localized: "Иду гулять")
        case (.going, .eyes): String(localized: "Давай гимнастику")
        case (.going, .endOfDay): String(localized: "Заканчиваю")
        case (.going, _): String(localized: "Иду")
        case (.snooze, .endOfDay): String(localized: "Ещё 10 мин")
        case (.snooze, _): String(localized: "Через 10 мин")
        case (.busy, _): String(localized: "Я занят")
        }
    }

    private static let polite: [Need: [String]] = [
        .water: [
            String(localized: "Эй, ты давно не пил. Глоток воды?"),
            String(localized: "Кажется, кто-то забыл про воду 💧"),
            String(localized: "Тук-тук, это вода. Она тебя ждёт"),
        ],
        .stretch: [
            String(localized: "Давно сидим. Разомнёмся пару минут?"),
            String(localized: "Спина шепчет: «встань». Я передаю"),
            String(localized: "Потянемся? Я уже начал"),
        ],
        .eyes: [
            String(localized: "Глазам пора отдохнуть. Гимнастика для глаз?"),
            String(localized: "Посмотрим вдаль вместе? 👀"),
            String(localized: "Экран никуда не денется. Глазкам — передышка"),
        ],
        .walk: [
            String(localized: "Пора проветриться. Прогуляемся?"),
            String(localized: "Как насчёт выйти на свежий воздух?"),
            String(localized: "Кажется, на улице что-то интересное. Сходим?"),
        ],
        .endOfDay: [
            String(localized: "Рабочий день всё. Закругляемся?"),
            String(localized: "Ты сегодня много сделал. Пора отдыхать 🌙"),
            String(localized: "Ноутбук тоже хочет спать"),
        ],
    ]

    private static let insist: [Need: [String]] = [
        .water: [
            String(localized: "Я всё ещё жду, когда ты попьёшь 💧"),
            String(localized: "Вода не кусается. Ну правда"),
            String(localized: "Мой листик уже вянет за тебя. Попей!"),
        ],
        .stretch: [
            String(localized: "Я не отстану: встань и потянись 🙃"),
            String(localized: "Твой стул устал от тебя. Дай ему отдохнуть"),
            String(localized: "Ну встань, а? Три минутки"),
        ],
        .eyes: [
            String(localized: "Глазки просят пощады 🥺 Гимнастика?"),
            String(localized: "Я серьёзно: полминуты для глаз"),
            String(localized: "Моргни мне, если слышишь. А потом — в окно"),
        ],
        .walk: [
            String(localized: "Я уже надел шапку. Ты идёшь?"),
            String(localized: "Прогулка сама себя не прогуляет"),
            String(localized: "Мир за окном скучает по тебе"),
        ],
        .endOfDay: [
            String(localized: "Я собрал рюкзак. Заканчивай, а?"),
            String(localized: "Работа подождёт до завтра. Честно"),
            String(localized: "«Ещё чуть-чуть» — это уже не первый раз 🙃"),
        ],
    ]

    private static let againLines: [Need: [String]] = [
        .water: [String(localized: "Снова я 🙂 Вода всё ещё ждёт")],
        .stretch: [String(localized: "Ты же собирался размяться 🙃"), String(localized: "Эй, мы договаривались потянуться!")],
        .eyes: [String(localized: "Я про глазки не забыл 👀")],
        .walk: [String(localized: "Шапка надета, а мы всё ещё тут 🙃"), String(localized: "Прогулка всё ещё в силе?")],
        .endOfDay: [String(localized: "Мы же договорились заканчивать 🌙")],
    ]

    static let stretchTips: [String] = [
        String(localized: "Потянись вверх и покрути плечами. Засчитаю, когда отойдёшь на 3 минуты 🙂"),
        String(localized: "Встань, наклонись, покрути головой. Я подожду"),
        String(localized: "Пройдись до окна и обратно — это уже победа"),
    ]

    static let endOfDayBye: [String] = [
        String(localized: "До завтра! Я посторожу экран 🌙"),
        String(localized: "Отличный день. Отдыхай 🌿"),
    ]

    static func thanks(_ n: Need) -> String {
        switch n {
        case .water: [String(localized: "Ура, вода! 💧"), String(localized: "Буль-буль 💧 Спасибо!"), String(localized: "Вот это я понимаю!")].randomElement()!
        case .stretch: [String(localized: "Хорошо размялся? 🙂"), String(localized: "Спина говорит спасибо!")].randomElement()!
        case .walk: [String(localized: "Как прогулка? 🌿"), String(localized: "С возвращением! Свежий воздух тебе к лицу")].randomElement()!
        case .eyes: String(localized: "Глазки отдохнули ✨")
        case .endOfDay: String(localized: "Доброй ночи 🌙")
        }
    }

    // MARK: Strict mode: stage 3 «мешает», stage 4 the pause, the emergency exit (slice 4, 2026-10-05)

    /// Stage 3: he has walked to the middle of the screen and the light is going down.
    static func disturb(_ n: Need) -> String {
        let lines: [String] = switch n {
        case .stretch: [String(localized: "Я вышел на середину. Свет гаснет, пока ты не встанешь"),
                        String(localized: "Встаёшь сам или мне погасить свет совсем?")]
        case .walk: [String(localized: "Я встал посреди экрана. Прогулка, пока свет не погас"),
                     String(localized: "Темнеет. Самое время выйти на улицу")]
        case .endOfDay: [String(localized: "Темнеет не только за окном. Закругляйся"),
                         String(localized: "Я выключаю свет. Рабочий день закончился")]
        case .water, .eyes: [String(localized: "Ну правда, пора")]
        }
        return lines.randomElement()!
    }

    /// Stage 4: the pause is up; the countdown and the emergency exit are under him.
    static func pause(_ n: Need) -> String {
        switch n {
        case .stretch: String(localized: "Пауза. Встань, потянись, отойди от Mac")
        case .walk: String(localized: "Пауза. Иди гулять, я посторожу экран")
        case .endOfDay: String(localized: "Пауза. На сегодня всё, правда")
        case .water, .eyes: String(localized: "Пауза")
        }
    }

    static let exitMinutes = [15, 30, 60]
    static func minutesLabel(_ m: Int) -> String { String(localized: "\(m) мин") }
    static let exitReasonPlaceholder = String(localized: "Причина выхода (обязательно)")
    static let exitBack = String(localized: "Назад")
    static let exitConfirm = String(localized: "Отпусти меня")
    static let exitHold = String(localized: "Удерживай 10 секунд")
    static let exitsSpent = String(localized: "Выходы закончились, они вернутся после прогулки. Удерживай кнопку, я подожду")

    static func exitButton(left: Int) -> String {
        left > 0 ? String(localized: "Экстренный выход · осталось \(left)") : String(localized: "Экстренный выход · выходов не осталось")
    }

    static func pauseStart(minutes: Int) -> String {
        String(localized: "Отойди от Mac на \(minutes) мин, и я засчитаю отдых")
    }

    static func pauseCountdown(seconds: Int) -> String {
        let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return String(localized: "Засчитаю через \(time). Клавиатура и мышь начинают отсчёт заново")
    }

    static func released(_ minutes: Int) -> String {
        String(localized: "Ладно, отпускаю на \(minutes) мин. Потом вернусь")
    }

    static func modeName(_ m: BalanceMode) -> String {
        switch m {
        case .strict: String(localized: "Строгий")
        case .soft: String(localized: "Мягкий")
        case .silent: String(localized: "Тишина")
        }
    }

    static func modeSet(_ m: BalanceMode) -> String {
        switch m {
        case .strict: String(localized: "Строгий режим. Если не послушаешь, затемню экран, а потом поставлю на паузу")
        case .soft: String(localized: "Мягкий режим. Буду только просить")
        case .silent: String(localized: "Тишина. Только намекаю, без слов")
        }
    }

    static let modeRefused = String(localized: "Сейчас смягчить нельзя: мы договорились. Выйти можно только экстренным выходом")

    static let snoozed: [String] = [
        String(localized: "Ладно, через 10 минут напомню ⏰"),
        String(localized: "Договорились. Но я засёк время"),
    ]

    static let busyHowLong = String(localized: "Понял. Через сколько вернуться?")

    static func deferred(_ minutes: Int) -> String {
        [String(localized: "Хорошо, вернусь через \(minutes) мин"),
         String(localized: "Не мешаю. Через \(minutes) мин я снова тут 📒")].randomElement()!
    }

    static let tooSoonWater = String(localized: "Ты же только что пил 🙂 Засчитаю чуть позже")

    // MARK: Persuasion and focus (slice 4b)

    /// The request in a chat chip: «Отложил «размяться» · 30 мин».
    static func requestName(_ n: Need) -> String {
        switch n {
        case .water: String(localized: "попить")
        case .stretch: String(localized: "размяться")
        case .eyes: String(localized: "глаза")
        case .walk: String(localized: "прогулку")
        case .endOfDay: String(localized: "конец дня")
        }
    }

    static func focusOn(until: String) -> String {
        String(localized: "Фокус до \(until). Не мешаю — только тихонько напомню")
    }

    static let focusEnded: [String] = [
        String(localized: "Фокус всё. Теперь моя очередь — кое-что набралось"),
        String(localized: "Фокус закончился. Я снова слежу всерьёз"),
    ]

    static let jokes: [String] = [
        String(localized: "Знаешь, почему у меня листик? Я расту над собой 🌱"),
        String(localized: "Я сегодня пробежал 0 километров. Зато красиво сидел у края"),
        String(localized: "Если что, я тут. Просто сижу. Профессионально"),
        String(localized: "Кстати, ты сегодня молодец. Просто так говорю"),
        String(localized: "Мой любимый спорт — моргание. Я в нём чемпион"),
        String(localized: "Листики не пьют кофе. Поэтому я такой спокойный"),
        String(localized: "Я видел, сколько у тебя вкладок. Я не осуждаю. Почти 🙃"),
        String(localized: "Сделаем вид, что это не я съел последнюю печеньку"),
    ]

    /// «Чем заняться вне экрана» (В18) by time of day: the library + today's Codex ideas (no weather, 2026-10-05).
    @MainActor static func idea(hour: Int) -> String {
        let morning = [
            String(localized: "Идея: выйди за кофе в ближайшую кофейню ☕️"),
            String(localized: "Идея: пять минут на солнце — и мозг включится"),
            String(localized: "Идея: пройдись до соседнего квартала и обратно"),
        ]
        let day = [
            String(localized: "Идея: сходи за фруктами 🍎"),
            String(localized: "Идея: найди по дороге самое красивое дерево"),
            String(localized: "Идея: погуляй 10 минут без телефона"),
        ]
        let evening = [
            String(localized: "Идея: посмотри на закат 🌇"),
            String(localized: "Идея: позвони кому-нибудь, пока гуляешь"),
            String(localized: "Идея: пройди домой новым маршрутом"),
        ]
        let night = [
            String(localized: "Идея: выйди на балкон, подыши ночным воздухом"),
            String(localized: "Идея: просто постой у окна и посмотри на огни"),
        ]
        let list = switch hour {
        case 5..<11: morning
        case 11..<17: day
        case 17..<23: evening
        default: night
        }
        return (list + (batch?.ideas(hour: hour) ?? [])).randomElement()!
    }

    static let gymFollow = String(localized: "Следи за мной глазами 👀")
    static func lookFar(_ seconds: Int) -> String { String(localized: "А теперь посмотри вдаль, в окно… \(seconds)") }
    static let inhale = String(localized: "Вдох…")
    static let exhale = String(localized: "Выдох…")
    static let enough = String(localized: "Хватит")
    static let breathedWell = String(localized: "Хорошо подышали 🌿")
}
