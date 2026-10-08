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

    // MARK: Slice 8e — events of Chilk's own «Чилк» calendar

    @Test func anEventCardSaysTheSlotAndTheCalendar() {
        let card = ActionCard(kind: .event(title: "Встреча с Сашей", start: at(9, 15), end: at(9, 16), allDay: false))
        #expect(card.lines(now: now, calendar: cal) == ["📅 Событие: Встреча с Сашей", "Пт, 9 окт., 15:00–16:00",
                                                        "«Календарь» → «Чилк»"])
        #expect(card.editable && card.when == at(9, 15) && !card.expired(now: now, calendar: cal))
        let guessed = ActionCard(kind: .event(title: "Йога", start: at(8, 15), end: at(8, 16, 30), allDay: false),
                                 guessedPart: true, guessedDay: true)
        #expect(guessed.lines(now: now, calendar: cal)[1] == "Завтра (Чт, 8 окт.)?, 15:00–16:30 · день?")
        let overMidnight = ActionCard(kind: .event(title: "Поезд", start: at(9, 23), end: at(10, 1), allDay: false))
        #expect(overMidnight.lines(now: now, calendar: cal)[1] == "Пт, 9 окт., 23:00 – Сб, 10 окт., 01:00")
        let untilMidnight = ActionCard(kind: .event(title: "Кино", start: at(9, 22), end: at(10, 0), allDay: false))
        #expect(untilMidnight.lines(now: now, calendar: cal)[1] == "Пт, 9 окт., 22:00–00:00")
    }

    @Test func anAllDayEventLastsItsWholeDay() {
        let dacha = ActionCard(kind: .event(title: "Дача", start: at(10, 0), end: at(11, 0), allDay: true))
        #expect(dacha.lines(now: now, calendar: cal) == ["📅 Событие: Дача", "Сб, 10 окт. · весь день", "«Календарь» → «Чилк»"])
        let today = ActionCard(kind: .event(title: "Отгул", start: at(7, 0), end: at(8, 0), allDay: true))
        #expect(today.lines(now: now, calendar: cal)[1] == "Сегодня (Ср, 7 окт.) · весь день")
        #expect(!today.expired(now: now, calendar: cal))                       // 21:00 — the day is not over yet
        #expect(today.expired(now: at(8, 0), calendar: cal))
        let guessedDay = ActionCard(kind: .event(title: "Отгул", start: at(8, 0), end: at(9, 0), allDay: true), guessedDay: true)
        #expect(guessedDay.lines(now: now, calendar: cal)[1] == "Завтра (Чт, 8 окт.)? · весь день")
        // A trip made by hand: several days. EventKit ends an all-day event at 23:59:59 of its last day.
        let trip = ActionCard(kind: .eventDelete(id: "e9", title: "Отпуск", start: at(10, 0), end: at(12, 23, 59).addingTimeInterval(59),
                                                 allDay: true))
        #expect(trip.lines(now: now, calendar: cal)[1] == "Сб, 10 окт. – Пн, 12 окт. · весь день")
        #expect(ActionCard(kind: .event(title: "Отпуск", start: at(10, 0), end: at(13, 0), allDay: true))
                    .lines(now: now, calendar: cal)[1] == "Сб, 10 окт. – Пн, 12 окт. · весь день")
    }

    @Test func eventChangesShowBeforeAndAfterAndOnlyANewStartExpires() {
        let move = ActionCard(kind: .eventChange(id: "e1", oldTitle: "Встреча", oldStart: at(9, 15), oldEnd: at(9, 16), allDay: false,
                                                 title: "Встреча", start: at(9, 16), end: at(9, 17)))
        #expect(move.lines(now: now, calendar: cal) == ["✏️ Изменить событие «Встреча»", "Было: Пт, 9 окт., 15:00–16:00",
                                                        "Станет: Пт, 9 окт., 16:00–17:00", "«Календарь» → «Чилк»"])
        #expect(move.when == at(9, 16) && move.editable)
        let rename = ActionCard(kind: .eventChange(id: "e1", oldTitle: "Встреча", oldStart: at(7, 10), oldEnd: at(7, 11), allDay: false,
                                                   title: "Созвон", start: at(7, 10), end: at(7, 11)))
        #expect(rename.lines(now: now, calendar: cal) == ["✏️ Изменить событие «Встреча»", "Название: Созвон", "«Календарь» → «Чилк»"])
        #expect(rename.when == nil && !rename.expired(now: now, calendar: cal))   // a rename of a past event is fine
        let longer = ActionCard(kind: .eventChange(id: "e1", oldTitle: "Встреча", oldStart: at(7, 20), oldEnd: at(7, 21), allDay: false,
                                                   title: "Встреча", start: at(7, 20), end: at(7, 22)))
        #expect(longer.lines(now: now, calendar: cal)[2] == "Станет: Сегодня (Ср, 7 окт.), 20:00–22:00")
        #expect(!longer.expired(now: now, calendar: cal))                      // only the end moved
        let delete = ActionCard(kind: .eventDelete(id: "e1", title: "Встреча", start: at(7, 10), end: at(7, 11), allDay: false))
        #expect(delete.lines(now: now, calendar: cal) == ["🗑 Удалить событие: Встреча", "Сегодня (Ср, 7 окт.), 10:00–11:00",
                                                          "«Календарь» → «Чилк»"])
        #expect(!delete.editable && !delete.expired(now: now, calendar: cal))
        let movedDay = ActionCard(kind: .eventChange(id: "e2", oldTitle: "Дача", oldStart: at(10, 0), oldEnd: at(11, 0), allDay: true,
                                                     title: "Дача", start: at(7, 0), end: at(8, 0)))
        #expect(!movedDay.expired(now: now, calendar: cal) && movedDay.expired(now: at(8, 9), calendar: cal))
    }

    @Test func aPassedEventStartCannotBeConfirmed() {
        let card = ActionCard(kind: .event(title: "Созвон", start: at(7, 20), end: at(7, 21), allDay: false))
        #expect(card.expired(now: now, calendar: cal))
        #expect(card.lines(now: now, calendar: cal).last == "Время уже прошло — измени его")
    }

    @Test func theModelAndTheResultLineSeeTheEventItWouldWrite() {
        let card = ActionCard(kind: .event(title: "Встреча", start: at(9, 15), end: at(9, 16), allDay: false), guessedPart: true)
        #expect(card.summary(calendar: cal) == "new calendar event «Встреча» 2026-10-09T15:00:00+03:00 – 2026-10-09T16:00:00+03:00")
        #expect(card.spanText(start: at(9, 15), end: at(9, 16), allDay: false, now: now, calendar: cal) == "Пт, 9 окт., 15:00–16:00")
        let day = ActionCard(kind: .event(title: "Дача", start: at(10, 0), end: at(11, 0), allDay: true))
        #expect(day.summary(calendar: cal) == "new all-day calendar event «Дача» on 2026-10-10")
        #expect(ActionCard(kind: .eventDelete(id: "e1", title: "Дача", start: at(10, 0), end: at(11, 0), allDay: true))
                    .summary(calendar: cal) == "delete calendar event «Дача»")
        #expect(ActionCard(kind: .eventChange(id: "e1", oldTitle: "А", oldStart: at(9, 15), oldEnd: at(9, 16), allDay: false,
                                              title: "Б", start: at(9, 15), end: at(9, 16))).summary(calendar: cal)
                == "change calendar event «А» → «Б» 2026-10-09T15:00:00+03:00 – 2026-10-09T16:00:00+03:00")
    }

    @Test func anAllDaySlotMovesByWholeDays() {
        let one = ActionCard.allDaySlot(movedTo: at(9, 14), start: at(9, 14), end: at(9, 14), calendar: cal)
        #expect(one.start == at(9, 0) && one.end == at(10, 0))
        // EventKit's three-day trip (it ends at 23:59:59 of its last day) moved to the 20th stays three days.
        let trip = ActionCard.allDaySlot(movedTo: at(20, 12), start: at(10, 0), end: at(12, 23, 59).addingTimeInterval(59), calendar: cal)
        #expect(trip.start == at(20, 0) && trip.end == at(23, 0))
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
