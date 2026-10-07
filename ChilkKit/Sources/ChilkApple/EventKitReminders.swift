import ChilkBrain
import EventKit
import Foundation

/// Apple Reminders through EventKit (decision 2026-10-05): Chilk's own «Чилк» list, created on first use in the
/// default reminders account (iCloud → iPhone/Watch). Access is asked on the first reminder request, never at launch.
/// Create and read only. Slice 8a: moved into the package so the real call's thread is tested; the store is injected.
@MainActor
public final class EventKitReminders: ReminderStore {
    private let store: EKEventStore
    private static let listKey = "remindersListID"

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    public func add(title: String, due: Date) async throws -> ReminderInfo {
        try await ensureAccess()
        guard let list = try chilkList(create: true) else { throw ReminderAccessError.unavailable }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        var parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        parts.timeZone = .current
        reminder.dueDateComponents = parts
        reminder.addAlarm(EKAlarm(absoluteDate: due))                // the notification itself, on every device
        try store.save(reminder, commit: true)
        return ReminderInfo(title: title, due: due)
    }

    public func open() async throws -> [ReminderInfo] {
        try await ensureAccess()
        guard let list = try chilkList(create: false) else { return [] }
        return await fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list]))
    }

    /// EventKit calls back on its own queue (`com.apple.eventkit.reminders.search`) and the SDK does not mark the
    /// completion `@Sendable`: inside this `@MainActor` class the closure would inherit MainActor, and Swift 6's runtime
    /// check crashed the app on the first open reminder (slice 8a, `_dispatch_assert_queue_fail`). The completion is
    /// `@Sendable` and turns the reminders into values right there.
    func fetch(_ predicate: NSPredicate) async -> [ReminderInfo] {
        await withCheckedContinuation { continuation in
            _ = store.fetchReminders(matching: predicate) { @Sendable reminders in
                let items = (reminders ?? []).map { r in
                    ReminderInfo(title: r.title ?? "", due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) })
                }
                continuation.resume(returning: items)
            }
        }
    }

    private func ensureAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return
        case .notDetermined:
            guard await requestAccess() else { throw ReminderAccessError.denied }
        default: throw ReminderAccessError.denied
        }
    }

    /// The first-time access prompt; its answer arrives on EventKit's queue too (`@Sendable`, as in `fetch`).
    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            store.requestFullAccessToReminders { @Sendable granted, _ in continuation.resume(returning: granted) }
        }
    }

    /// The remembered list, else one titled «Чилк», else (when creating) a new one. Other lists are never touched.
    private func chilkList(create: Bool) throws -> EKCalendar? {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: Self.listKey), let list = store.calendar(withIdentifier: id),
           list.allowsContentModifications { return list }
        if let list = store.calendars(for: .reminder).first(where: {
            $0.title == ChilkReminderExecutor.listTitle && $0.allowsContentModifications
        }) {
            defaults.set(list.calendarIdentifier, forKey: Self.listKey)
            return list
        }
        guard create else { return nil }
        guard let source = store.defaultCalendarForNewReminders()?.source
                ?? store.sources.first(where: { $0.sourceType == .local }) else { throw ReminderAccessError.unavailable }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = ChilkReminderExecutor.listTitle
        list.source = source
        try store.saveCalendar(list, commit: true)
        defaults.set(list.calendarIdentifier, forKey: Self.listKey)
        return list
    }
}
