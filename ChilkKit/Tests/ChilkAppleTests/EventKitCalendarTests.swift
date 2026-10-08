@testable import ChilkApple
import ChilkBrain
import EventKit
import EventKitFakes
import Foundation
import Testing

/// Slice 8e (SPEC «Срез 8», decisions 11, 12): the «Чилк» calendar adapter. The fake stores answer from memory and
/// `status` stands in for TCC — no prompt, no real data.
@MainActor
struct EventKitCalendarTests {
    private func calendar(_ store: EKEventStore, _ status: EKAuthorizationStatus = .fullAccess) -> EventKitCalendar {
        let defaults = UserDefaults(suiteName: "dev.all0b0y.chilk.tests")!
        defaults.removeObject(forKey: "eventsCalendarID")
        return EventKitCalendar(store: store, defaults: defaults, status: { status })
    }

    /// Decision 12: EventKit answers the access prompt on its own queue (8a's crash came from such a callback).
    @Test func theAccessAnswerOnEventKitsQueueDoesNotCrash() async {
        #expect(await calendar(QueueEventStore(), .notDetermined).requestAccess())
    }

    /// Decision 11: «границы держит Чилк» — an event of another calendar is not found, so it is neither changed nor deleted.
    @Test func onlyEventsOfTheChilkCalendarAreFoundChangedOrDeleted() async throws {
        let store = OwnCalendarStore()
        store.addEvent(id: "own", title: "Йога", in: store.chilk)
        store.addEvent(id: "theirs", title: "Йога", in: store.work)
        let cal = calendar(store)
        #expect(try await cal.event(id: "own").title == "Йога")
        await #expect(throws: CalendarAccessError.notFound) { try await cal.event(id: "theirs") }
        await #expect(throws: CalendarAccessError.notFound) { try await cal.update(id: "theirs", title: "Х", start: nil, end: nil) }
        await #expect(throws: CalendarAccessError.notFound) { try await cal.delete(id: "theirs") }
        #expect(store.writes.isEmpty)
        let moved = Date(timeIntervalSince1970: 1_791_500_000)
        let changed = try await cal.update(id: "own", title: "Растяжка", start: moved, end: moved.addingTimeInterval(1800))
        #expect(changed.title == "Растяжка" && changed.start == moved && changed.end == moved.addingTimeInterval(1800))
        try await cal.delete(id: "own")
        #expect(store.writes == ["save Растяжка", "remove Растяжка"])
    }

    @Test func aRepeatingEventIsNeitherChangedNorDeleted() async throws {
        let store = OwnCalendarStore()
        store.addEvent(id: "rep", title: "Планёрка", in: store.chilk, recurring: true)
        let cal = calendar(store)
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
            let cal = calendar(store, status)
            await #expect(throws: CalendarAccessError.denied) { try await cal.events(from: .distantPast, to: .distantFuture) }
            await #expect(throws: CalendarAccessError.denied) { try await cal.delete(id: "own") }
            #expect(store.writes.isEmpty)
        }
    }

    @Test func readingMapsWhatEventKitReturns() {
        let store = OwnCalendarStore()
        let start = Date(timeIntervalSince1970: 1_791_450_000)
        store.addEvent(id: "a", title: "Йога", in: store.chilk, start: start)
        store.addEvent(id: "b", title: "Дача", in: store.chilk, start: start, minutes: 1439, allDay: true)
        let items = calendar(store).fetch(NSPredicate(value: true))
        #expect(items.map(\.id) == ["a", "b"] && items[0].end == start.addingTimeInterval(3600) && items[1].allDay && !items[0].recurring)
    }

    /// A new event goes into the «Чилк» calendar found by its title; no second calendar is made.
    @Test func aNewEventGoesIntoTheChilkCalendar() async throws {
        let store = OwnCalendarStore()
        let start = Date(timeIntervalSince1970: 1_791_500_000)
        let made = try await calendar(store).add(title: "Встреча", start: start, end: start.addingTimeInterval(3600), allDay: false)
        #expect(store.writes == ["save Встреча"])
        #expect(made.title == "Встреча" && made.start == start && made.end == start.addingTimeInterval(3600) && !made.allDay)
    }
}
