import ChilkBrain
import EventKit
import Foundation

/// Apple Reminders through EventKit (decision 2026-10-05): Chilk's own «Чилк» list, created on first use in the
/// default reminders account (iCloud → iPhone/Watch). Access is asked on the first reminder request, never at launch.
/// Create and read only.
@MainActor
final class EventKitReminders: ReminderStore {
    private let store = EKEventStore()
    private static let listKey = "remindersListID"

    func add(title: String, due: Date) async throws -> ReminderInfo {
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

    func open() async throws -> [ReminderInfo] {
        try await ensureAccess()
        guard let list = try chilkList(create: false) else { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list])
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
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
            let granted: Bool = await withCheckedContinuation { continuation in
                store.requestFullAccessToReminders { granted, _ in continuation.resume(returning: granted) }
            }
            guard granted else { throw ReminderAccessError.denied }
        default: throw ReminderAccessError.denied
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

/// Acceptance runs (CHILK_FAKE_REMINDERS): the real Codex and tool path without touching the user's Reminders.
/// Every created reminder is appended to `reminders-fake.json` in CHILK_STATE_DIR.
actor FakeReminders: ReminderStore {
    private var items: [ReminderInfo] = []
    private let file = AppState.directory.appendingPathComponent("reminders-fake.json")

    func add(title: String, due: Date) async throws -> ReminderInfo {
        let info = ReminderInfo(title: title, due: due)
        items.append(info)
        let rows = items.map { ["title": $0.title, "at": $0.due.map { ISO8601DateFormatter().string(from: $0) } ?? ""] }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]).write(to: file, options: .atomic)
        return info
    }

    func open() async throws -> [ReminderInfo] { items }
}
