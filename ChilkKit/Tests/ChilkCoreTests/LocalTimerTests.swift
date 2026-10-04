import Foundation
import Testing
@testable import ChilkCore

@Suite("Local timers")
struct LocalTimerTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func anInvalidDeadlineCannotEnterTheQueue() throws {
        var timers = LocalTimers()
        #expect(throws: LocalTimers.TimerError.invalidDeadline) {
            try timers.schedule(id: "past", title: "Чай", message: "Пора", at: now, now: now)
        }
        #expect(timers.entries.isEmpty)
    }

    @Test(arguments: [Double.infinity, 367.0 * 24 * 60 * 60])
    func unboundedDeadlinesAreRejected(seconds: Double) throws {
        var timers = LocalTimers()
        #expect(throws: LocalTimers.TimerError.self) {
            try timers.schedule(title: "Чай", message: "Пора", at: now.addingTimeInterval(seconds), now: now)
        }
        #expect(timers.entries.isEmpty)
    }

    @Test(arguments: ["", String(repeating: "ч", count: 81), "чай\nкофе"])
    func invalidTitlesAreRejected(title: String) throws {
        var timers = LocalTimers()
        #expect(throws: LocalTimers.TimerError.self) {
            try timers.schedule(title: title, message: "Пора", at: now.addingTimeInterval(30), now: now)
        }
        #expect(timers.entries.isEmpty)
    }

    @Test func duplicateIDsAndExcessiveQueueSizeCannotAccumulate() throws {
        var timers = LocalTimers()
        let date = now.addingTimeInterval(30)
        try timers.schedule(id: "same", title: "Чай", message: "Пора", at: date, now: now)
        #expect(throws: LocalTimers.TimerError.self) {
            try timers.schedule(id: "same", title: "Чай", message: "Пора", at: date, now: now)
        }
        for n in 1..<32 { try timers.schedule(id: "\(n)", title: "Чай", message: "Пора", at: date, now: now) }
        #expect(throws: LocalTimers.TimerError.self) {
            try timers.schedule(id: "extra", title: "Чай", message: "Пора", at: date, now: now)
        }
        #expect(timers.entries.count == 32)
    }

    @Test func aTimerBecomesDueAtItsDeadlineNotBefore() throws {
        var timers = LocalTimers()
        let alarm = try timers.schedule(id: "tea", title: "Чай", message: "Чай готов",
                                        at: now.addingTimeInterval(30), now: now)
        #expect(timers.entries == [alarm])
        #expect(timers.collectDue(at: now.addingTimeInterval(29)).isEmpty)
        #expect(timers.collectDue(at: now.addingTimeInterval(30)).map(\.id) == ["tea"])
        #expect(timers.ready.map(\.id) == ["tea"])
        #expect(timers.collectDue(at: now.addingTimeInterval(31)).isEmpty)
    }
}
