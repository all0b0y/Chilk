@testable import ChilkApple
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

    @Test func theAccessAnswerOnEventKitsQueueDoesNotCrash() async {
        let granted = await EventKitReminders(store: QueueEventStore()).requestAccess()
        #expect(granted)
    }
}
