import ChilkCore
import Foundation
import Testing

@Suite("Day plan notices: book and rules (slice 9b, decisions 13, 15, 17)")
struct PlanBookTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return c
    }()

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func chilksDayTurnsAtFive() {
        #expect(PlanDay.iso(PlanNotice.chilkDay(at(9, 4, 59), calendar: cal), calendar: cal) == "2026-10-08")
        #expect(PlanDay.iso(PlanNotice.chilkDay(at(9, 5), calendar: cal), calendar: cal) == "2026-10-09")
    }

    @Test func morningIsDueAtTheFirstActivityAfterFiveOnly() {
        var book = PlanBook()
        #expect(!PlanNotice.morningDue(now: at(9, 4, 30), idle: 1, locked: false, book: book, calendar: cal))
        #expect(PlanNotice.morningDue(now: at(9, 7), idle: 2, locked: false, book: book, calendar: cal))
        #expect(!PlanNotice.morningDue(now: at(9, 7), idle: 600, locked: false, book: book, calendar: cal))   // away
        #expect(!PlanNotice.morningDue(now: at(9, 7), idle: 1, locked: true, book: book, calendar: cal))
        book.morningShown = "2026-10-09"
        #expect(!PlanNotice.morningDue(now: at(9, 7), idle: 1, locked: false, book: book, calendar: cal))
        #expect(PlanNotice.morningDue(now: at(10, 6), idle: 1, locked: false, book: book, calendar: cal))
    }

    @Test func morningSaysNothingWithoutThingsOrAnOpenYesterday() {
        let doneYesterday = [PlanNotice.Thing(title: "почта", done: true)]
        #expect(PlanNotice.morning(today: [], yesterday: [], yesterdayReviewed: false) == nil)
        #expect(PlanNotice.morning(today: [], yesterday: doneYesterday, yesterdayReviewed: false) == nil)
        let open = [PlanNotice.Thing(title: "стирка")]
        #expect(PlanNotice.morning(today: [], yesterday: open, yesterdayReviewed: true) == nil)
        let review = PlanNotice.morning(today: [], yesterday: open, yesterdayReviewed: false)
        #expect(review?.reviewYesterday == true)
        #expect(review?.total == 0)
    }

    @Test func morningListsTheFirstThreeTimedByTime() {
        let things = [PlanNotice.Thing(title: "маме", time: PlanTime(hour: 15, minute: 0)),
                      PlanNotice.Thing(title: "хлеб"),
                      PlanNotice.Thing(title: "созвон", time: PlanTime(hour: 11, minute: 0)),
                      PlanNotice.Thing(title: "зал", time: PlanTime(hour: 8, minute: 30)),
                      PlanNotice.Thing(title: "кино", time: PlanTime(hour: 20, minute: 0))]
        let m = PlanNotice.morning(today: things, yesterday: [], yesterdayReviewed: false)
        #expect(m?.total == 5)
        #expect(m?.timedCount == 4)
        #expect(m?.timed.map(\.title) == ["зал", "созвон", "маме"])
        #expect(m?.reviewYesterday == false)
    }

    @Test func reactionTiers() {
        #expect(PlanNotice.result(done: 5, total: 5) == .all)
        #expect(PlanNotice.result(done: 4, total: 5) == .most)
        #expect(PlanNotice.result(done: 3, total: 5) == .most)
        #expect(PlanNotice.result(done: 2, total: 5) == .some)
        #expect(PlanNotice.result(done: 0, total: 5) == .none)
        #expect(PlanNotice.result(done: 0, total: 0) == .none)
    }

    @Test func theSecondReminderForTheSameDayWithinHalfAnHourOffersOnceADay() {
        var book = PlanBook()
        // `#expect` cannot hold a mutating call: through a local function.
        func written(_ day: String, _ now: Date, today: String = "2026-10-08") -> Bool {
            book.reminderWritten(day: day, now: now, today: today)
        }
        #expect(!written("2026-10-09", at(8, 8, 10)))
        #expect(!written("2026-10-10", at(8, 8, 11)))       // another day
        #expect(written("2026-10-09", at(8, 8, 39)))        // 29 min after the first
        #expect(book.offered == nil)                        // spent only once it is shown
        #expect(written("2026-10-09", at(8, 8, 39)))        // not shown (lapsed, Reminders off): may come again
        book.markOffered("2026-10-08")
        #expect(!written("2026-10-09", at(8, 8, 40)))       // once a day
        #expect(!written("2026-10-10", at(8, 8, 41)))
        // The next day it may come again; 32 minutes apart is not «in a row».
        #expect(!written("2026-10-12", at(9, 9, 9), today: "2026-10-09"))
        #expect(!written("2026-10-12", at(9, 9, 41), today: "2026-10-09"))
        #expect(written("2026-10-12", at(9, 9, 50), today: "2026-10-09"))
    }

    @Test func theReviewWritesWhatChangedThenMovesOrDropsTheRest() {
        typealias Row = PlanNotice.ReviewRow
        let rows = [Row(id: "a", title: "зал", done: true),        // ticked in the review
                    Row(id: "b", title: "стирка", done: false),    // left open: moves (the default)
                    Row(id: "c", title: "почта", done: true),      // done before: nothing
                    Row(id: "d", title: "кино", done: false),      // dropped
                    Row(id: "e", title: "хлеб", done: false)]      // unticked, then dropped: only the drop
        let ops = PlanNotice.reviewOps(rows, original: ["a": false, "b": false, "c": true, "d": false, "e": true],
                                       choices: ["d": .drop, "e": .drop])
        #expect(ops == [.setDone("a", true), .move("b", title: "стирка"), .drop("d"), .drop("e")])
        let undone = PlanNotice.reviewOps([Row(id: "x", title: "зал", done: false)], original: ["x": true], choices: [:])
        #expect(undone == [.setDone("x", false), .move("x", title: "зал")])
    }

    @Test func reviewedKeepsTheLastFourteenDaysOnce() {
        var book = PlanBook()
        for d in 1...20 { book.markReviewed(String(format: "2026-10-%02d", d)) }
        book.markReviewed("2026-10-15")
        #expect(book.reviewed.count == PlanBook.keep)
        #expect(book.reviewed.last == "2026-10-15")
        #expect(book.reviewed.filter { $0 == "2026-10-15" }.count == 1)
        #expect(!book.reviewed.contains("2026-10-06"))
    }

    @Test func everyFieldDecodesOnItsOwn() throws {
        var book = PlanBook()
        book.morningShown = "2026-10-08"
        book.markReviewed("2026-10-07")
        let offered = book.reminderWritten(day: "2026-10-09", now: at(8, 8, 10), today: "2026-10-08")
        #expect(!offered)
        let back = try JSONDecoder().decode(PlanBook.self, from: try JSONEncoder().encode(book))
        #expect(back == book)
        #expect(try JSONDecoder().decode(PlanBook.self, from: Data("{}".utf8)) == PlanBook())
        let broken = try JSONDecoder().decode(PlanBook.self, from: Data(#"{"reviewed": 5, "morningShown": "2026-10-08"}"#.utf8))
        #expect(broken.reviewed.isEmpty)
        #expect(broken.morningShown == "2026-10-08")
    }
}
