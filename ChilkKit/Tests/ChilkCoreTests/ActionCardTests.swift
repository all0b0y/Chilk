import ChilkCore
import Foundation
import Testing

/// Slice 8c (decisions 3–8): the confirmation card.
struct ActionCardTests {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return c
    }()
    var now: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 21, minute: 0))! }
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func aReminderCardSaysWhatWhenAndWhere() {
        let card = ActionCard(kind: .reminder(title: "Купить хлеб", due: at(8, 10)))
        #expect(card.lines(now: now, calendar: cal) == ["📝 Напоминание: Купить хлеб", "Завтра (Чт, 8 окт.), 10:00",
                                                        "«Напоминания» → «Чилк»"])
    }

    @Test func aGuessedPartOfDayAndAGuessedDayAreMarked() {
        let card = ActionCard(kind: .reminder(title: "Позвонить маме", due: at(9, 15)), guessedPart: true, guessedDay: false)
        #expect(card.lines(now: now, calendar: cal)[1] == "Пт, 9 окт., 15:00 · день?")
        let night = ActionCard(kind: .reminder(title: "Таблетка", due: at(8, 3)), guessedPart: true, guessedDay: true)
        #expect(night.lines(now: now, calendar: cal)[1] == "Завтра (Чт, 8 окт.)?, 03:00 · ночь?")
    }

    @Test func aPassedTimeCannotBeConfirmed() {
        let card = ActionCard(kind: .message(title: "Перерыв", text: "Сделай перерыв", at: at(7, 20)))
        #expect(card.expired(now: now))
        #expect(card.lines(now: now, calendar: cal).last == "Время уже прошло — измени его")
        #expect(!ActionCard(kind: .reminderDelete(id: "x", title: "Хлеб", due: at(7, 20))).expired(now: now))
    }

    @Test func changesShowBeforeAndAfter() {
        let card = ActionCard(kind: .reminderChange(id: "1", oldTitle: "Хлеб", oldDue: at(8, 10), title: "Хлеб", due: at(9, 10)))
        #expect(card.lines(now: now, calendar: cal) == ["✏️ Изменить напоминание «Хлеб»", "Было: Завтра (Чт, 8 окт.), 10:00",
                                                        "Станет: Пт, 9 окт., 10:00", "«Напоминания» → «Чилк»"])
        #expect(!ActionCard(kind: .reminderComplete(id: "1", title: "Хлеб", due: nil)).editable)
    }

    @Test func answersAreYesNoOrACorrection() {
        for yes in ["да", "Да!", "ставь", "давай", "Чилк, да, пожалуйста", "ага", "подтверждаю", "ок"] {
            #expect(CardAnswer.parse(yes) == .yes, "\(yes)")
        }
        for no in ["нет", "Нет, не надо", "не надо", "отмена", "не ставь", "отбой"] {
            #expect(CardAnswer.parse(no) == .no, "\(no)")
        }
        for other in ["да, но в 11", "да 11", "нет, в пятницу", "перенеси на вечер", "а что с погодой?",
                      "нет, надо", "нет, ставь", "точно?", "да?", "да нет", "не знаю"] {
            #expect(CardAnswer.parse(other) == .correction(other), "\(other)")
        }
    }

    @Test func aClockTimerCardSaysTheLengthAndWhenItRings() {
        let card = ActionCard(kind: .timer(title: "Чай", seconds: 300))
        #expect(card.lines(now: now, calendar: cal) == ["⏱ Таймер: Чай", "5 мин — до 21:05", "«Часы»"])
        #expect(card.editable && !card.expired(now: now.addingTimeInterval(86400)))
        let late = ActionCard(kind: .timer(title: "Спать", seconds: 4 * 3600))
        #expect(late.lines(now: now, calendar: cal)[1] == "4 ч — до 01:00 завтра")
        #expect(ActionCard.duration(45) == "45 с")
        #expect(ActionCard.duration(90) == "1 мин 30 с")
        #expect(ActionCard.duration(5400) == "1 ч 30 мин")
        #expect(ActionCard.duration(93600) == "1 д 2 ч")
    }

    @Test func theResultLineHasNoGuessMarks() {
        let card = ActionCard(kind: .reminder(title: "Хлеб", due: at(8, 15)), guessedPart: true)
        #expect(card.lines(now: now, calendar: cal)[1].contains("день?"))
        #expect(card.whenText(at(8, 15), now: now, calendar: cal) == "Завтра (Чт, 8 окт.), 15:00")
        #expect(card.whenText(at(7, 23), now: now, calendar: cal) == "Сегодня (Ср, 7 окт.), 23:00")
    }

    @Test func theQueueShowsTheFirstAndACorrectionTakesItsPlace() {
        var q = CardQueue()
        let a = ActionCard(kind: .reminder(title: "A", due: at(8, 10)))
        let b = ActionCard(kind: .reminder(title: "B", due: at(8, 11)))
        let a2 = ActionCard(kind: .reminder(title: "A2", due: at(8, 12)))
        q.add(a, replacingCurrent: false)
        q.add(b, replacingCurrent: false)
        q.add(a2, replacingCurrent: true)
        #expect(q.current == a2 && q.cards.count == 2)
        #expect(q.settle(a2.id) == b)
        #expect(q.settle(b.id) == nil && q.isEmpty)
    }
}

struct LooseHourTests {
    @Test func aGluedPrepositionStillLeavesTheHourOpen() {
        #expect(ClockWords.looseOpenHour(in: "Напомнив три позвонить маме", hour: 15))
        #expect(ClockWords.looseOpenHour(in: "напомни 3 позвонить", hour: 3))
        #expect(!ClockWords.looseOpenHour(in: "напомни в три часа дня", hour: 15))
        #expect(!ClockWords.looseOpenHour(in: "напомни через 3 минуты", hour: 15))
        #expect(!ClockWords.looseOpenHour(in: "напомни в 15:00", hour: 15))
    }
}
