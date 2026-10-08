@testable import ChilkApple
import EventKit
import EventKitFakes
import Foundation
import Testing

/// Slice 8a: the crash on «какие у меня напоминания?» — EventKit's callback on its own queue inside a `@MainActor`
/// class. A regression does not fail a test: it kills the test process (signal 5, `_dispatch_assert_queue_fail`), as
/// it killed the app. `open()` itself also asks TCC (`authorizationStatus`), so the test goes through the two seams
/// that receive EventKit's callbacks: `fetch` and `requestAccess`.
@MainActor
struct EventKitRemindersTests {
    @Test(arguments: [0, 1, 3])
    func readingTheListOnEventKitsQueueDoesNotCrash(count: Int) async {
        let store = QueueEventStore()
        store.count = count
        let reminders = EventKitReminders(store: store)
        let items = await reminders.fetch(NSPredicate(value: true))
        #expect(items.count == count)
        #expect(items.allSatisfy { $0.title == "Проверить почту" && $0.due != nil })
    }

    /// Slice 9b (decision 9; review 9b): a thing on a date only has no alarm (it does not ring), a timed one has its
    /// alarm; moving a timed one to a date only («→ Завтра» in the review) takes the alarm away; done is read back.
    @Test func aDateOnlyThingHasNoAlarmAndATimedOneHasIt() {
        let r = EKReminder(eventStore: EKEventStore())
        let due = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 15, minute: 30))!
        EventKitReminders.setDue(r, due, timed: true)
        #expect(r.dueDateComponents?.hour == 15)
        #expect(r.alarms?.count == 1)
        #expect(r.alarms?.first?.absoluteDate == due)
        #expect(EventKitReminders.info(r).timed)
        EventKitReminders.setDue(r, due, timed: false)
        #expect(r.dueDateComponents?.hour == nil)
        #expect(r.alarms?.isEmpty ?? true)
        let info = EventKitReminders.info(r)
        #expect(!info.timed)
        #expect(info.due == Calendar.current.startOfDay(for: due))
        r.isCompleted = true
        #expect(EventKitReminders.info(r).done)
    }

    @Test func theAccessAnswerOnEventKitsQueueDoesNotCrash() async {
        let granted = await EventKitReminders(store: QueueEventStore()).requestAccess()
        #expect(granted)
    }
}
