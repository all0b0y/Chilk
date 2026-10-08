import ChilkBrain
import EventKit
import Foundation

/// Apple Calendar through EventKit (SPEC «Срез 8», decision 11): Chilk's own «Чилк» calendar, created on the first
/// «Да» in the default calendar's account (iCloud → iPhone), else iCloud, else «On My Mac». Full access, because only
/// full access may read and change even Chilk's own events; Chilk keeps itself to its calendar here: reading asks only
/// that calendar, and a change or deletion first checks that the event lives in it. Access is asked on first use.
@MainActor
public final class EventKitCalendar: CalendarStore {
    private let store: EKEventStore
    private let defaults: UserDefaults
    private let status: () -> EKAuthorizationStatus
    private static let calendarKey = "eventsCalendarID"

    /// `status` and `defaults` are seams for tests (the real ones read TCC and the app's defaults).
    public init(store: EKEventStore = EKEventStore(), defaults: UserDefaults = .standard,
                status: @escaping () -> EKAuthorizationStatus = { EKEventStore.authorizationStatus(for: .event) }) {
        self.store = store
        self.defaults = defaults
        self.status = status
    }

    public func add(title: String, start: Date, end: Date, allDay: Bool) async throws -> EventInfo {
        try await ensureAccess()
        guard let calendar = try chilkCalendar(create: true) else { throw CalendarAccessError.unavailable }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.calendar = calendar
        event.isAllDay = allDay
        event.startDate = start
        event.endDate = allDay ? start : end                   // EventKit ends an all-day event with its day itself
        try store.save(event, span: .thisEvent, commit: true)
        return Self.info(event)
    }

    public func events(from: Date, to: Date) async throws -> [EventInfo] {
        try await ensureAccess()
        guard let calendar = try chilkCalendar(create: false) else { return [] }
        return fetch(store.predicateForEvents(withStart: from, end: to, calendars: [calendar]))
    }

    /// `events(matching:)` is synchronous: no callback on EventKit's queue to guard here (unlike `fetchReminders`).
    func fetch(_ predicate: NSPredicate) -> [EventInfo] { store.events(matching: predicate).map(Self.info) }

    public func event(id: String) async throws -> EventInfo {
        try await ensureAccess()
        return Self.info(try own(id))
    }

    public func update(id: String, title: String?, start: Date?, end: Date?) async throws -> EventInfo {
        try await ensureAccess()
        let event = try own(id)
        guard !event.hasRecurrenceRules else { throw CalendarAccessError.recurring }
        if let title { event.title = title }
        if let start { event.startDate = start }
        // An all-day end is exclusive here (or EventKit's own 23:59:59): EventKit wants a moment inside the last day.
        if let end { event.endDate = event.isAllDay ? max(event.startDate ?? end, end.addingTimeInterval(-1)) : end }
        try store.save(event, span: .thisEvent, commit: true)
        return Self.info(event)
    }

    public func delete(id: String) async throws {
        try await ensureAccess()
        let event = try own(id)
        guard !event.hasRecurrenceRules else { throw CalendarAccessError.recurring }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    /// The event with this id — only if it lives in Chilk's own calendar (other calendars are never touched).
    private func own(_ id: String) throws -> EKEvent {
        guard let calendar = try chilkCalendar(create: false), let event = store.event(withIdentifier: id),
              event.calendar?.calendarIdentifier == calendar.calendarIdentifier else { throw CalendarAccessError.notFound }
        return event
    }

    private static func info(_ e: EKEvent) -> EventInfo {
        let start: Date = e.startDate ?? Date()
        return EventInfo(id: e.eventIdentifier ?? "", title: e.title ?? "", start: start, end: e.endDate ?? start,
                         allDay: e.isAllDay, recurring: e.hasRecurrenceRules)
    }

    /// Write-only access cannot read or change even Chilk's own events, so it counts as no access.
    private func ensureAccess() async throws {
        switch status() {
        case .fullAccess: return
        case .notDetermined:
            guard await requestAccess() else { throw CalendarAccessError.denied }
        default: throw CalendarAccessError.denied
        }
    }

    /// The first-time access prompt. EventKit answers on its own queue; the SDK marks this completion `@Sendable`
    /// (unlike `fetchReminders`, slice 8a), and the closure stays `@Sendable` here so it never inherits MainActor.
    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { @Sendable granted, _ in continuation.resume(returning: granted) }
        }
    }

    /// The remembered calendar, else one titled «Чилк», else (when creating) a new one. Other calendars are never
    /// touched.
    private func chilkCalendar(create: Bool) throws -> EKCalendar? {
        if let id = defaults.string(forKey: Self.calendarKey), let calendar = store.calendar(withIdentifier: id),
           calendar.allowedEntityTypes.contains(.event), calendar.allowsContentModifications { return calendar }
        if let calendar = store.calendars(for: .event).first(where: {
            $0.title == ChilkCalendarExecutor.calendarTitle && $0.allowsContentModifications
        }) {
            defaults.set(calendar.calendarIdentifier, forKey: Self.calendarKey)
            return calendar
        }
        guard create else { return nil }
        // The default calendar's account first (iCloud reaches the iPhone), then iCloud, then «On My Mac»; an account
        // that takes no new calendars (Exchange, a subscription) refuses the save and the next one is tried.
        var sources: [EKSource] = []
        let candidates = [store.defaultCalendarForNewEvents?.source].compactMap { $0 }
            + store.sources.filter { $0.sourceType == .calDAV && $0.title == "iCloud" }
            + store.sources.filter { $0.sourceType == .local }
        for source in candidates where !sources.contains(where: { $0.sourceIdentifier == source.sourceIdentifier }) {
            sources.append(source)
        }
        for source in sources {
            let calendar = EKCalendar(for: .event, eventStore: store)
            calendar.title = ChilkCalendarExecutor.calendarTitle
            calendar.source = source
            do {
                try store.saveCalendar(calendar, commit: true)
                defaults.set(calendar.calendarIdentifier, forKey: Self.calendarKey)
                return calendar
            } catch {
                continue
            }
        }
        throw CalendarAccessError.unavailable
    }
}
