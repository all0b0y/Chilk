import Foundation
import Testing
@testable import ChilkCore

// Slice 6d+ (SPEC Т1–Т4, 2026-10-06): an hour without a part of day, «завтра» after midnight.

struct ClockWordsTests {
    let zone = TimeZone(identifier: "Europe/Moscow")!

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 10, day, hour, minute)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: c)!
    }

    @Test func anHourWithoutAPartOfDayIsAmbiguous() {
        let cases: [(String, [Int])] = [
            ("напомни в 3 позвонить маме", [3]),
            ("напомни в три часа позвонить маме", [3]),
            ("к семи надо быть дома", [7]),
            ("напомни завтра в 8:30 про отчёт", [8]),
            ("напомни в полтретьего", [2]),
            ("в половине восьмого созвон", [7]),
            ("в 12 обед", [12]),
            ("в час позвонить Пете", [1]),
            ("до пяти закончить", [5]),
            ("remind me at 3 to call", [3]),
            ("в 3 и в 5", [3, 5]),
        ]
        for (text, hours) in cases { #expect(ClockWords.ambiguousHours(in: text) == hours, "\(text)") }
    }

    @Test func aPartOfDayOrTwentyFourHoursIsClear() {
        for text in ["напомни в 3 ночи", "в 3 часа дня", "в три часа ночи", "утром в 9", "сегодня вечером в 7",
                     "в 15:00", "в 03:00", "в 0:30", "в 23", "в полдень", "в полночь", "через 3 часа", "через час",
                     "на 3 дня", "в 2 раза больше", "в 3 минуты", "at 3pm", "в 7 утра и в 8 вечера", "позвони маме"] {
            #expect(ClockWords.ambiguousHours(in: text).isEmpty, "\(text)")
        }
    }

    @Test func theToolIsRefusedOnlyForTheHourTheUserLeftOpen() {
        let q = "напомни в 3 позвонить маме"
        #expect(ClockWords.conflict(question: q, at: at(7, 3), now: at(6, 14), zone: zone) == .hour(3))
        #expect(ClockWords.conflict(question: q, at: at(6, 15), now: at(6, 14), zone: zone) == .hour(3))
        #expect(ClockWords.conflict(question: q, at: at(6, 16), now: at(6, 14), zone: zone) == nil)
        #expect(ClockWords.conflict(question: "в 12 обед", at: at(7, 0), now: at(6, 14), zone: zone) == .hour(12))
        // The answer is the next question: «ночи» leaves nothing open.
        #expect(ClockWords.conflict(question: "ночи", at: at(7, 3), now: at(6, 14), zone: zone) == nil)
    }

    @Test func tomorrowAfterMidnightNeedsADate() {
        // The model's timestamp is read loosely: with an offset, in UTC, or without a zone (as written).
        #expect(ClockWords.localHour(ofTimestamp: "2026-10-07T03:00:00+03:00", zone: zone) == 3)
        #expect(ClockWords.localHour(ofTimestamp: "2026-10-07T00:00:00Z", zone: zone) == 3)
        #expect(ClockWords.localHour(ofTimestamp: "2026-10-06T15:00:00", zone: zone) == 15)
        #expect(ClockWords.localHour(ofTimestamp: "в три", zone: zone) == nil)
        let q = "напомни завтра в 15:00 про отчёт"
        #expect(ClockWords.conflict(question: q, at: at(7, 15), now: at(7, 1, 20), zone: zone) == .day)
        #expect(ClockWords.conflict(question: q, at: at(7, 15), now: at(7, 4, 59), zone: zone) == .day)
        #expect(ClockWords.conflict(question: q, at: at(8, 15), now: at(7, 5), zone: zone) == nil)
        #expect(ClockWords.conflict(question: q, at: at(7, 15), now: at(6, 23, 50), zone: zone) == nil)
        #expect(ClockWords.conflict(question: "напомни сегодня в 15:00", at: at(7, 15), now: at(7, 1), zone: zone) == nil)
    }

    @Test func codexGetsAHintInTheContext() {
        let hours = ClockWords.hint(for: "напомни в 3 позвонить маме", now: at(6, 14), zone: zone)
        #expect(hours?.contains("03:00 или 15:00") == true)
        let day = ClockWords.hint(for: "напомни завтра в 15:00", now: at(7, 1), zone: zone)
        #expect(day?.contains("7 октября") == true && day?.contains("8 октября") == true)
        #expect(ClockWords.hint(for: "напомни в 15:00", now: at(6, 14), zone: zone) == nil)
        let context = VoiceContext.text(sittingMinutes: 5, now: at(6, 14), zone: zone)
        let added = VoiceContext.adding("заметка", to: context)
        #expect(added.hasSuffix("; заметка]\n") && added.hasPrefix("[контекст: "))
    }
}
