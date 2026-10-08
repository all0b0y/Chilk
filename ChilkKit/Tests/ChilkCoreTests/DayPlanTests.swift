import Foundation
import Testing
@testable import ChilkCore

/// Slice 9b (SPEC «Срез 9», decisions 9–12): the day plan's rules and its card.
struct DayPlanTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return c
    }()

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10, year: Int = 2026) -> Date {
        cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func day(_ d: Int, month: Int = 10, year: Int = 2026) -> Date { at(d, 0, month: month, year: year) }

    func t(_ text: String) -> PlanTime { PlanTime(text)! }

    @Test func timesAreHoursAndMinutes() {
        #expect(PlanTime("9:30") == PlanTime(hour: 9, minute: 30))
        #expect(PlanTime("09:30")?.text == "09:30")
        #expect(PlanTime("23:59") != nil)
        for bad in ["24:00", "9:3", "930", "ab:cd", "", "9:60", "-1:00", "09:30:00", "٩:٣٠"] { #expect(PlanTime(bad) == nil, "\(bad)") }
    }

    @Test func noDaySaidIsTodayUntilFiveInTheEveningThenTomorrow() {
        #expect(PlanDay.defaultDay(now: at(8, 10), calendar: cal) == day(8))
        #expect(PlanDay.defaultDay(now: at(8, 16, 59), calendar: cal) == day(8))
        #expect(PlanDay.defaultDay(now: at(8, 17), calendar: cal) == day(9))
        // At night the calendar today is the day after sleep.
        #expect(PlanDay.defaultDay(now: at(9, 2), calendar: cal) == day(9))
    }

    @Test func tomorrowSaidAtNightIsTheDayAfterSleep() {
        let night = at(9, 1, 30)
        let r = PlanDay.resolve(day(10), words: "давай спланируем завтра", now: night, calendar: cal)
        #expect(r.day == day(9) && r.nightTomorrow)
        // «послезавтра» is another word; by day «завтра» is the calendar tomorrow; a day said by date stays.
        #expect(PlanDay.resolve(day(10), words: "на послезавтра", now: night, calendar: cal) == (day(10), false))
        #expect(PlanDay.resolve(day(10), words: "спланируем завтра", now: at(9, 10), calendar: cal) == (day(10), false))
        #expect(PlanDay.resolve(day(12), words: "на завтра и на 12-е", now: night, calendar: cal) == (day(12), false))
        #expect(PlanDay.resolve(nil, words: "давай спланируем", now: at(8, 18), calendar: cal) == (day(9), false))
    }

    @Test func aPlanIsForTodayOrAYearAhead() {
        let now = at(8, 12)
        #expect(!PlanDay.inRange(day(7), now: now, calendar: cal))
        #expect(PlanDay.inRange(day(8), now: now, calendar: cal))
        #expect(PlanDay.inRange(cal.date(byAdding: .day, value: 366, to: day(8))!, now: now, calendar: cal))
        #expect(!PlanDay.inRange(cal.date(byAdding: .day, value: 367, to: day(8))!, now: now, calendar: cal))
    }

    @Test func theDayIsNamedWithItsWeekdayAndDate() {
        let now = at(8, 12)
        #expect(PlanDay.title(day(8), now: now, calendar: cal) == "четверг, 8 октября")
        #expect(PlanDay.title(day(9), now: now, calendar: cal) == "пятница, 9 октября")
        #expect(PlanDay.title(day(9), now: now, calendar: cal, accusative: true) == "пятницу, 9 октября")
        #expect(PlanDay.title(day(14), now: now, calendar: cal, accusative: true) == "среду, 14 октября")
        #expect(PlanDay.title(day(12), now: now, calendar: cal, accusative: true) == "понедельник, 12 октября")
        #expect(PlanDay.title(day(9, year: 2027), now: now, calendar: cal) == "суббота, 9 октября 2027")
        #expect(PlanDay.iso(day(9), calendar: cal) == "2026-10-09")
    }

    @Test func timedThingsGoByTimeAndTheRestKeepsTheOrderSaid() {
        let items = [PlanItem(title: "хлеб"), PlanItem(title: "маме", time: t("15:00")), PlanItem(title: "созвон", time: t("11:00")),
                     PlanItem(title: "отчёт"), PlanItem(title: "зал", time: t("15:00"))]
        let (timed, untimed) = PlanDay.ordered(items)
        #expect(timed.map(\.title) == ["созвон", "маме", "зал"])
        #expect(untimed.map(\.title) == ["хлеб", "отчёт"])
    }

    @Test func aGuessedNightHourIsADayHour() {
        #expect(PlanItem(title: "маме", time: t("03:00"), guessed: true).daytime.time == t("15:00"))
        #expect(PlanItem(title: "пробежка", time: t("05:30")).daytime.time == t("05:30"))       // «в 5:30 утра» — said
        #expect(PlanItem(title: "созвон", time: t("09:00"), guessed: true).daytime.time == t("09:00"))
        #expect(PlanItem(title: "хлеб", guessed: true).guessed == false)                         // no time — nothing to guess
    }

    @Test func aPassedTimeOfTodayIsWrittenWithoutATime() {
        let now = at(8, 12)
        let items = [PlanItem(title: "созвон", time: t("11:00")), PlanItem(title: "маме", time: t("15:00")), PlanItem(title: "хлеб")]
        let entries = PlanDay.entries(day: day(8), items: items, now: now, calendar: cal)
        #expect(entries == [PlanEntry(title: "созвон", due: day(8), timed: false),
                            PlanEntry(title: "маме", due: at(8, 15), timed: true),
                            PlanEntry(title: "хлеб", due: day(8), timed: false)])
        // Tomorrow nothing has passed.
        #expect(PlanDay.entries(day: day(9), items: items, now: now, calendar: cal).first == PlanEntry(title: "созвон", due: at(9, 11), timed: true))
    }

    @Test func theDraftTakesTheWholeListWithoutWhatIsAlreadyPlanned() {
        var draft = PlanDraft(day: day(9), already: ["Зал"])
        draft.update([PlanItem(title: "созвон", time: t("11:00")), PlanItem(title: "зал"), PlanItem(title: "маме", time: t("03:00"), guessed: true),
                      PlanItem(title: "Созвон", time: t("11:00")), PlanItem(title: "созвон", time: t("16:00"))])
        #expect(draft.items == [PlanItem(title: "созвон", time: t("11:00")), PlanItem(title: "маме", time: t("15:00"), guessed: true),
                                PlanItem(title: "созвон", time: t("16:00"))])
        // A correction is the whole list again: «хлеб убери» — it is gone.
        draft.update([PlanItem(title: "созвон", time: t("11:00"))])
        #expect(draft.items.map(\.title) == ["созвон"])
        #expect(PlanDraft(day: day(9), already: []).card() == nil)
        guard case .plan(let d, let items, let already)? = draft.card()?.kind else { Issue.record("no plan card"); return }
        #expect(d == day(9) && items.count == 1 && already == ["Зал"])
    }

    @Test func thePlanCardShowsTheDayTheTimesTheRestAndWhatIsThere() {
        let now = at(9, 12)
        let items = [PlanItem(title: "купить хлеб"), PlanItem(title: "маме", time: t("15:00"), guessed: true),
                     PlanItem(title: "созвон", time: t("11:00")), PlanItem(title: "отчёт")]
        let card = ActionCard(kind: .plan(day: day(9), items: items, already: ["зал", "стирка"]))
        #expect(card.lines(now: now, calendar: cal) == [
            "🗓 План на пятницу, 9 октября",
            "11:00 — созвон · уже прошло, без времени",
            "15:00 · день? — маме",
            "Без времени: купить хлеб, отчёт",
            "Уже в плане: зал, стирка",
            "«Напоминания» → «Чилк»",
        ])
        #expect(card.editable && card.when == nil)
        #expect(!card.expired(now: at(9, 23, 59), calendar: cal))
        #expect(card.expired(now: at(10, 0, 1), calendar: cal))
        #expect(card.summary(calendar: cal).hasPrefix("day plan for 2026-10-09 (пятница, 9 октября): 11:00 «созвон»; 15:00 «маме» (guessed time); no time «купить хлеб»"))
    }

    @Test func chilksOwnLineNeedsNoQuestionBeforeIt() {
        var log = ChatLog()
        let id = log.recordLocal(question: "", answer: "Это всё?", via: .text, continuing: nil, at: at(9, 12))
        #expect(log.session(id)?.turns.map(\.text) == ["Это всё?"])
        _ = log.recordLocal(question: "ещё молоко", answer: "Ага", via: .text, continuing: id, at: at(9, 12, 1))
        #expect(log.session(id)?.turns.count == 3)
    }

    @Test func aLongPlanShowsEightTimesOnTheCard() {
        let items = (0..<11).map { PlanItem(title: "дело \($0)", time: PlanTime(hour: 8 + $0, minute: 0)) }
        let lines = ActionCard(kind: .plan(day: day(10), items: items, already: [])).lines(now: at(9, 12), calendar: cal)
        #expect(lines.count == 1 + 8 + 1 + 1)
        #expect(lines[9] == "…и ещё 3 со временем")
    }
}
