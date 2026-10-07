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

    static func make() -> EKReminder { class_createInstance(MadeUpReminder.self, 0) as! EKReminder }
}
