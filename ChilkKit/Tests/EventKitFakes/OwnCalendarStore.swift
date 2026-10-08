import EventKit
import ObjectiveC

/// Slice 8e: a store with two calendars — Chilk's «Чилк» and the user's «Работа» — and made-up events in them. It answers
/// lookups, reading and writes from memory and records the writes; no real data, no access request.
public final class OwnCalendarStore: EKEventStore {
    public let chilk = MadeUpCalendar.make(id: "cal-chilk", title: "Чилк")
    public let work = MadeUpCalendar.make(id: "cal-work", title: "Работа")
    public var items: [EKEvent] = []
    /// «save <title>», «remove <title>», «calendar <title>».
    public var writes: [String] = []

    public func addEvent(id: String, title: String, in calendar: EKCalendar, start: Date = Date(timeIntervalSince1970: 1_791_450_000),
                         minutes: Double = 60, allDay: Bool = false, recurring: Bool = false) {
        items.append(MadeUpEvent.make(id: id, title: title, calendar: calendar, start: start,
                                      end: start.addingTimeInterval(minutes * 60), allDay: allDay, recurring: recurring))
    }

    public override func calendars(for entityType: EKEntityType) -> [EKCalendar] { [work, chilk] }
    public override func calendar(withIdentifier identifier: String) -> EKCalendar? {
        [work, chilk].first { $0.calendarIdentifier == identifier }
    }
    public override func event(withIdentifier identifier: String) -> EKEvent? { items.first { $0.eventIdentifier == identifier } }
    public override func events(matching predicate: NSPredicate) -> [EKEvent] { items }
    public override func save(_ event: EKEvent, span: EKSpan, commit: Bool) throws { writes.append("save \(event.title ?? "")") }
    public override func remove(_ event: EKEvent, span: EKSpan, commit: Bool) throws { writes.append("remove \(event.title ?? "")") }
    public override func saveCalendar(_ calendar: EKCalendar, commit: Bool) throws { writes.append("calendar \(calendar.title)") }
}

private var madeUpKey: UInt8 = 0

/// Values of an object allocated without EventKit's initialiser (no store, no account behind it).
extension NSObject {
    fileprivate var madeUp: [String: Any] {
        get { objc_getAssociatedObject(self, &madeUpKey) as? [String: Any] ?? [:] }
        set { objc_setAssociatedObject(self, &madeUpKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

public final class MadeUpCalendar: EKCalendar {
    public override var calendarIdentifier: String { madeUp["id"] as? String ?? "" }
    public override var title: String {
        get { madeUp["title"] as? String ?? "" }
        set { madeUp["title"] = newValue }
    }
    public override var allowsContentModifications: Bool { true }
    public override var allowedEntityTypes: EKEntityMask { .event }

    static func make(id: String, title: String) -> EKCalendar {
        let c = class_createInstance(MadeUpCalendar.self, 0) as! MadeUpCalendar
        c.madeUp = ["id": id, "title": title]
        return c
    }
}

final class MadeUpEvent: EKEvent {
    override var eventIdentifier: String! { madeUp["id"] as? String }
    override var title: String! {
        get { madeUp["title"] as? String }
        set { madeUp["title"] = newValue }
    }
    override var startDate: Date! {
        get { madeUp["start"] as? Date }
        set { madeUp["start"] = newValue }
    }
    override var endDate: Date! {
        get { madeUp["end"] as? Date }
        set { madeUp["end"] = newValue }
    }
    override var isAllDay: Bool {
        get { madeUp["allDay"] as? Bool ?? false }
        set { madeUp["allDay"] = newValue }
    }
    override var calendar: EKCalendar! {
        get { madeUp["calendar"] as? EKCalendar }
        set { madeUp["calendar"] = newValue }
    }
    override var hasRecurrenceRules: Bool { madeUp["recurring"] as? Bool ?? false }

    static func make(id: String, title: String, calendar: EKCalendar, start: Date, end: Date, allDay: Bool,
                     recurring: Bool) -> EKEvent {
        let e = class_createInstance(MadeUpEvent.self, 0) as! MadeUpEvent
        e.madeUp = ["id": id, "title": title, "calendar": calendar, "start": start, "end": end, "allDay": allDay,
                    "recurring": recurring]
        return e
    }
}
