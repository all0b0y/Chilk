import EventKit
import ObjectiveC

/// A store that answers `fetchReminders` the way EventKit does — later, on a private serial queue named like
/// EventKit's — with `count` made-up reminders. No real data, no access request.
public final class QueueEventStore: EKEventStore {
    public var count = 0
    private let queue = DispatchQueue(label: "com.apple.eventkit.reminders.search")

    public override func fetchReminders(matching predicate: NSPredicate,
                                        completion: @escaping ([EKReminder]?) -> Void) -> Any {
        let n = count
        queue.async { completion((0..<n).map { _ in MadeUpReminder.make() }) }
        return NSObject()
    }

    /// The access prompt answered «allowed» on the same queue — no system prompt, no TCC.
    public override func requestFullAccessToReminders(completion: @escaping EKEventStoreRequestAccessCompletionHandler) {
        queue.async { completion(true, nil) }
    }

    /// Slice 8e: the Calendar access prompt, answered the same way.
    public override func requestFullAccessToEvents(completion: @escaping EKEventStoreRequestAccessCompletionHandler) {
        queue.async { completion(true, nil) }
    }
}

/// An `EKReminder` allocated without EventKit's initialiser (no store, no account).
final class MadeUpReminder: EKReminder {
    override var title: String! {
        get { "Проверить почту" }
        set {}
    }
    override var dueDateComponents: DateComponents? {
        get { DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 9, hour: 10, minute: 0) }
        set {}
    }

    /// Slice 9b: the app reads «done» too.
    override var isCompleted: Bool {
        get { false }
        set {}
    }

    static func make() -> EKReminder { class_createInstance(MadeUpReminder.self, 0) as! EKReminder }
}
