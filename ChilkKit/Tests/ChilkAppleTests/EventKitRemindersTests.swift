@testable import ChilkApple
import EventKitFakes
import Foundation
import Testing

/// Slice 8a: the crash on «какие у меня напоминания?» — EventKit's callback on its own queue inside a `@MainActor`
/// class. Empty, one and three open reminders (one or more was the crashing case).
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
}
