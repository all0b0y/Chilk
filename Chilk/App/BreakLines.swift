import Foundation
import ChilkCore

/// Guided breaks (decisions 2026-10-05): the hand-written emergency library and Chilk's lines around them.
extension Lines {
    /// The fallback when Codex has nothing ready: body 8, eyes 4, breath 3, mind 5. Safe at a desk, no loads.
    static let warmupLibrary: [Exercise] = [
        Exercise(.body, String(localized: "Потянись руками вверх, будто достаёшь до верхней полки"), move: .stretch),
        Exercise(.body, String(localized: "Медленно покрути плечами назад, потом вперёд"), move: .stretch),
        Exercise(.body, String(localized: "Наклони голову к одному плечу, потом к другому, без рывков"), move: .stretch),
        Exercise(.body, String(localized: "Встань и потянись в стороны, руки на поясе"), move: .stretch),
        Exercise(.body, String(localized: "Сцепи пальцы и вытяни руки перед собой, спина круглая"), move: .stretch),
        Exercise(.body, String(localized: "Повращай кистями и стопами в одну и в другую сторону"), move: .wave),
        Exercise(.body, String(localized: "Встань, перекатись с пяток на носки и обратно"), move: .stretch),
        Exercise(.body, String(localized: "Сведи лопатки вместе, задержи на пару секунд и отпусти"), move: .stretch),
        Exercise(.eyes, String(localized: "Посмотри в окно на самую дальнюю точку и задержи на ней взгляд"), move: .lookFar),
        Exercise(.eyes, String(localized: "Нарисуй глазами большую восьмёрку, медленно, голова на месте"), move: .lookFar),
        Exercise(.eyes, String(localized: "Закрой глаза ладонями и посиди в мягкой темноте"), move: .still),
        Exercise(.eyes, String(localized: "Поморгай быстро-быстро, потом закрой глаза и расслабь лицо"), move: .still),
        Exercise(.breath, String(localized: "Вдох на четыре счёта, выдох на шесть, плечи опускаются"), move: .breathe),
        Exercise(.breath, String(localized: "Положи ладонь на живот и дыши так, чтобы она поднималась"), move: .breathe),
        Exercise(.breath, String(localized: "Квадрат: вдох на четыре, пауза, выдох на четыре, пауза"), move: .breathe),
        Exercise(.mind, String(localized: "Вспомни три хорошие вещи за сегодня, даже совсем маленькие"), move: .still),
        Exercise(.mind, String(localized: "Найди вокруг пять предметов одного цвета"), move: .still),
        Exercise(.mind, String(localized: "Послушай: какие три звука слышно прямо сейчас?"), move: .still),
        Exercise(.mind, String(localized: "Подумай, чем порадуешь себя вечером"), move: .breathe),
        Exercise(.mind, String(localized: "Опусти плечи, разожми челюсть и отпусти лоб"), move: .breathe),
    ]

    static let warmupStart = String(localized: "Разминаемся пять минут. Я показываю, ты повторяешь")
    static func warmupCaption(step: Int, of total: Int) -> String { String(localized: "Шаг \(step) из \(total)") }
    static func warmupStep(_ text: String, left: String) -> String { "\(text) · \(left)" }
    static func walkCountdown(_ idea: String, left: String) -> String { "\(idea) · \(left)" }
    static let walkCaption = String(localized: "Прогулка 15 минут. Компьютер подождёт")
    static let guideStop = String(localized: "Прервать")
    static let warmupDone = String(localized: "Размялись! Так держать 💪")
    static let walkDone = String(localized: "Как прогулка? 🌿")
    static let guideStopped = String(localized: "Ладно, остановились. В другой раз доделаем")

    /// After «Иду» on «размяться» (user decision «2»).
    static let stretchHow = String(localized: "Как разомнёмся?")
    static let warmupWithMe = String(localized: "Разминка со мной")
    static let onMyOwn = String(localized: "Сам")
    /// On the stage-4 pause.
    static let startWarmup = String(localized: "Начать разминку")
    static let goWalk = String(localized: "Иду гулять")
}
