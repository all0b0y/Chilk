@testable import ChilkApple
import ChilkBrain
import EventKit
import EventKitFakes
import Foundation
import Testing

/// Slice 8e (SPEC «Срез 8», decisions 11, 12): the «Чилк» calendar adapter. The fake stores answer from memory and
/// `status` stands in for TCC — no prompt, no real data. Each test has its own defaults domain.
@MainActor
struct EventKitCalendarTests {
    private func calendar(_ store: EKEventStore, _ status: EKAuthorizationStatus = .fullAccess,
                          defaults name: String = #function) -> (EventKitCalendar, UserDefaults) {
        let defaults = UserDefaults(suiteName: "dev.all0b0y.chilk.tests.\(name.prefix(40))")!
        defaults.removeObject(forKey: "eventsCalendarID")
        return (EventKitCalendar(store: store, defaults: defaults, status: { status }), defaults)
    }

    /// Decision 12: EventKit answers the access prompt on its own queue (8a's crash came from such a callback).
    @Test func theAccessAnswerOnEventKitsQueueDoesNotCrash() async {
        #expect(await calendar(QueueEventStore(), .notDetermined).0.requestAccess())
    }

    /// Decision 11: «границы держит Чилк» — an event of another calendar is not found, so it is neither changed nor deleted.
    @Test func onlyEventsOfTheChilkCalendarAreFoundChangedOrDeleted() async throws {
        let store = OwnCalendarStore()
        store.addEvent(id: "own", title: "Йога", in: store.chilk)
        store.addEvent(id: "theirs", title: "Йога", in: store.work)
        let (cal, _) = calendar(store)
        #expect(try await cal.event(id: "own").title == "Йога")
        await #expect(throws: CalendarAccessError.notFound) { try await cal.event(id: "theirs") }
        await #expect(throws: CalendarAccessError.notFound) { try await cal.update(id: "theirs", title: "Х", start: nil, end: nil) }
        await #expect(throws: CalendarAccessError.notFound) { try await cal.delete(id: "theirs") }
        #expect(store.writes.isEmpty)
        let moved = Date(timeIntervalSince1970: 1_791_500_000)
        let changed = try await cal.update(id: "own", title: "Растяжка", start: moved, end: moved.addingTimeInterval(1800))
        #expect(changed.title == "Растяжка" && changed.start == moved && changed.end == moved.addingTimeInterval(1800))
        try await cal.delete(id: "own")
        #expect(store.writes == ["save Растяжка in Чилк", "remove Растяжка"])
    }

    @Test func readingAsksOnlyTheChilkCalendar() async throws {
        let store = OwnCalendarStore()
        store.addEvent(id: "own", title: "Йога", in: store.chilk)
        store.addEvent(id: "theirs", title: "Планёрка", in: store.work)
        let found = try await calendar(store).0.events(from: .distantPast, to: .distantFuture)
        #expect(found.map(\.id) == ["own"])
        #expect(store.lastCalendars?.map(\.calendarIdentifier) == ["cal-chilk"])
    }

    /// A «Чилк» calendar of another account (shared, or made by hand at work) is never taken for Chilk's own.
    @Test func aChilkCalendarOfAnotherAccountIsNeverTaken() async throws {
        let store = OwnCalendarStore()
        store.listed = [store.work, store.foreignChilk]
        store.addEvent(id: "x", title: "Совещание", in: store.foreignChilk)
        let (cal, defaults) = calendar(store)
        #expect(try await cal.events(from: .distantPast, to: .distantFuture).isEmpty)
        await #expect(throws: CalendarAccessError.notFound) { try await cal.delete(id: "x") }
        #expect(store.writes.isEmpty && defaults.string(forKey: "eventsCalendarID") == nil)
    }

    @Test func aRepeatingEventIsNeitherChangedNorDeleted() async throws {
        let store = OwnCalendarStore()
        store.addEvent(id: "rep", title: "Планёрка", in: store.chilk, recurring: true)
        let (cal, _) = calendar(store)
        #expect(try await cal.event(id: "rep").recurring)
        await #expect(throws: CalendarAccessError.recurring) { try await cal.update(id: "rep", title: "Летучка", start: nil, end: nil) }
        await #expect(throws: CalendarAccessError.recurring) { try await cal.delete(id: "rep") }
        #expect(store.writes.isEmpty && store.items.first?.title == "Планёрка")
    }

    /// Write-only access cannot read or change even Chilk's own events: it counts as no access.
    @Test func withoutFullAccessNothingIsReadOrWritten() async {
        for status: EKAuthorizationStatus in [.denied, .restricted, .writeOnly] {
            let store = OwnCalendarStore()
            store.addEvent(id: "own", title: "Йога", in: store.chilk)
            let (cal, _) = calendar(store, status)
            await #expect(throws: CalendarAccessError.denied) { try await cal.events(from: .distantPast, to: .distantFuture) }
            await #expect(throws: CalendarAccessError.denied) { try await cal.delete(id: "own") }
            #expect(store.writes.isEmpty)
        }
    }

    /// EventKit ends an all-day event at 23:59:59 of its last day; the model and the cards get the next midnight.
    @Test func readingGivesAnAllDayEventAnExclusiveEnd() {
        let store = OwnCalendarStore()
        let start = Date(timeIntervalSince1970: 1_791_450_000)
        let day = Calendar.current.startOfDay(for: start)
        store.addEvent(id: "a", title: "Йога", in: store.chilk, start: start)
        store.addEvent(id: "b", title: "Дача", in: store.chilk, start: day, minutes: 1439 + 59.0 / 60, allDay: true)
        let items = calendar(store).0.fetch(NSPredicate(value: true))
        #expect(items.map(\.id) == ["a", "b"] && items[0].end == start.addingTimeInterval(3600) && !items[0].recurring)
        #expect(items[1].allDay && items[1].end == Calendar.current.date(byAdding: .day, value: 1, to: day))
    }

    /// No «Чилк» calendar yet: the first «Да» makes it in Chilk's own account; an account that takes no new calendars
    /// is skipped (iCloud → «На этом Mac»), and the new calendar is remembered.
    @Test func theFirstEventMakesTheCalendarInTheNextAccountThatTakesIt() async throws {
        let store = OwnCalendarStore()
        store.listed = [store.work]
        store.refuse = ["src-icloud"]
        let (cal, defaults) = calendar(store)
        let start = Date(timeIntervalSince1970: 1_791_500_000)
        _ = try await cal.add(title: "Встреча", start: start, end: start.addingTimeInterval(3600), allDay: false)
        #expect(store.writes == ["refused Чилк in iCloud", "reset", "calendar Чилк in На этом Mac", "save Встреча in Чилк"])
        #expect(defaults.string(forKey: "eventsCalendarID") != nil)
    }

    @Test func whenNoAccountTakesTheCalendarNothingIsSaved() async {
        let store = OwnCalendarStore()
        store.listed = [store.work]
        store.refuse = ["src-icloud", "src-local"]
        let (cal, defaults) = calendar(store)
        let start = Date(timeIntervalSince1970: 1_791_500_000)
        await #expect(throws: CalendarAccessError.unavailable) {
            try await cal.add(title: "Встреча", start: start, end: start.addingTimeInterval(3600), allDay: false)
        }
        #expect(!store.writes.contains { $0.hasPrefix("save") } && defaults.string(forKey: "eventsCalendarID") == nil)
    }

    /// An all-day event is written with a moment inside its last day (EventKit's way), whatever end the card had.
    @Test func anAllDayEventIsWrittenInsideItsDay() async throws {
        let store = OwnCalendarStore()
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_791_500_000))
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let made = try await calendar(store).0.add(title: "Дача", start: day, end: next, allDay: true)
        #expect(made.allDay && made.start == day && made.end == next)
    }

    /// A new event goes into the «Чилк» calendar found by its title in Chilk's own account, and it is remembered.
    @Test func aNewEventGoesIntoTheChilkCalendarAndItIsRemembered() async throws {
        let store = OwnCalendarStore()
        let start = Date(timeIntervalSince1970: 1_791_500_000)
        let (cal, defaults) = calendar(store)
        let made = try await cal.add(title: "Встреча", start: start, end: start.addingTimeInterval(3600), allDay: false)
        #expect(store.writes == ["save Встреча in Чилк"])
        #expect(made.title == "Встреча" && made.start == start && made.end == start.addingTimeInterval(3600) && !made.allDay)
        #expect(defaults.string(forKey: "eventsCalendarID") == "cal-chilk")
    }
}
