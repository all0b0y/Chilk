import EventKit
import ObjectiveC

/// Slice 8e: a store with Chilk's «Чилк» calendar in iCloud and the user's «Работа» in another account, plus made-up
/// events. It answers lookups, reading and writes from memory and records the writes; no real data, no access request.
public final class OwnCalendarStore: EKEventStore {
    public let icloud = MadeUpSource.make(id: "src-icloud", title: "iCloud", type: .calDAV)
    public let exchange = MadeUpSource.make(id: "src-work", title: "Работа", type: .exchange)
    public let local = MadeUpSource.make(id: "src-local", title: "На этом Mac", type: .local)
    /// Accounts (source ids) that take no new calendars: their `saveCalendar` throws.
    public var refuse: Set<String> = []
    public lazy var chilk = MadeUpCalendar.make(id: "cal-chilk", title: "Чилк", source: icloud)
    public lazy var work = MadeUpCalendar.make(id: "cal-work", title: "Работа", source: exchange)
    /// A «Чилк» calendar of another account (shared or made by hand there): never Chilk's own.
    public lazy var foreignChilk = MadeUpCalendar.make(id: "cal-foreign", title: "Чилк", source: exchange)
    /// The calendars EventKit lists (default: «Работа» and «Чилк»).
    public var listed: [EKCalendar]?
    public var items: [EKEvent] = []
    /// «save <title> in <calendar>», «remove <title>», «calendar <title> in <account>», «refused <title> in <account>»,
    /// «reset».
    public var writes: [String] = []
    /// The calendars the last reading asked for (`nil` = every calendar, as in EventKit).
    public var lastCalendars: [EKCalendar]?

    public func addEvent(id: String, title: String, in calendar: EKCalendar, start: Date = Date(timeIntervalSince1970: 1_791_450_000),
                         minutes: Double = 60, allDay: Bool = false, recurring: Bool = false) {
        items.append(MadeUpEvent.make(id: id, title: title, calendar: calendar, start: start,
                                      end: start.addingTimeInterval(minutes * 60), allDay: allDay, recurring: recurring))
    }

    public override var sources: [EKSource] { [icloud, exchange, local] }
    public override func source(withIdentifier identifier: String) -> EKSource? {
        sources.first { $0.sourceIdentifier == identifier }
    }
    public override var defaultCalendarForNewEvents: EKCalendar? { nil }
    public override func calendars(for entityType: EKEntityType) -> [EKCalendar] { listed ?? [work, chilk] }
    public override func calendar(withIdentifier identifier: String) -> EKCalendar? {
        (listed ?? [work, chilk]).first { $0.calendarIdentifier == identifier }
    }
    public override func event(withIdentifier identifier: String) -> EKEvent? { items.first { $0.eventIdentifier == identifier } }
    public override func predicateForEvents(withStart startDate: Date, end endDate: Date, calendars: [EKCalendar]?) -> NSPredicate {
        lastCalendars = calendars
        return NSPredicate(value: true)
    }
    public override func events(matching predicate: NSPredicate) -> [EKEvent] {
        guard let only = lastCalendars else { return items }
        let ids = Set(only.map(\.calendarIdentifier))
        return items.filter { ids.contains($0.calendar?.calendarIdentifier ?? "") }
    }
    public override func save(_ event: EKEvent, span: EKSpan, commit: Bool) throws {
        writes.append("save \(event.title ?? "") in \(event.calendar?.title ?? "?")")
    }
    public override func remove(_ event: EKEvent, span: EKSpan, commit: Bool) throws { writes.append("remove \(event.title ?? "")") }
    public override func saveCalendar(_ calendar: EKCalendar, commit: Bool) throws {
        let account = calendar.source?.title ?? "?"
        if let id = calendar.source?.sourceIdentifier, refuse.contains(id) {
            writes.append("refused \(calendar.title) in \(account)")
            throw NSError(domain: "OwnCalendarStore", code: 18)        // EKErrorSourceDoesNotAllowCalendarAddDelete
        }
        writes.append("calendar \(calendar.title) in \(account)")
    }
    public override func reset() { writes.append("reset") }
}

private var madeUpKey: UInt8 = 0

/// Values of an object allocated without EventKit's initialiser (no store, no account behind it).
extension NSObject {
    fileprivate var madeUp: [String: Any] {
        get { objc_getAssociatedObject(self, &madeUpKey) as? [String: Any] ?? [:] }
        set { objc_setAssociatedObject(self, &madeUpKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

public final class MadeUpSource: EKSource {
    public override var sourceIdentifier: String { madeUp["id"] as? String ?? "" }
    public override var title: String { madeUp["title"] as? String ?? "" }
    public override var sourceType: EKSourceType { madeUp["type"] as? EKSourceType ?? .local }

    static func make(id: String, title: String, type: EKSourceType) -> EKSource {
        let s = class_createInstance(MadeUpSource.self, 0) as! MadeUpSource
        s.madeUp = ["id": id, "title": title, "type": type]
        return s
    }
}

public final class MadeUpCalendar: EKCalendar {
    public override var calendarIdentifier: String { madeUp["id"] as? String ?? "" }
    public override var title: String {
        get { madeUp["title"] as? String ?? "" }
        set { madeUp["title"] = newValue }
    }
    public override var source: EKSource! {
        get { madeUp["source"] as? EKSource }
        set { madeUp["source"] = newValue }
    }
    public override var allowsContentModifications: Bool { true }
    public override var isSubscribed: Bool { false }
    public override var allowedEntityTypes: EKEntityMask { .event }

    static func make(id: String, title: String, source: EKSource) -> EKCalendar {
        let c = class_createInstance(MadeUpCalendar.self, 0) as! MadeUpCalendar
        c.madeUp = ["id": id, "title": title, "source": source]
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
