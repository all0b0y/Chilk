import ChilkBrain
import Foundation

/// Acceptance runs (CHILK_FAKE_CALENDAR=1 | seed): the real Codex and card path without the user's Calendar. Every write
/// lands in `calendar-fake.json` in CHILK_STATE_DIR. `seed` starts with a single «Йога» tomorrow 10:00–11:00 and a
/// repeating «Планёрка» tomorrow 09:30–09:45 (the refusal path).
actor FakeCalendar: CalendarStore {
    private var items: [EventInfo] = []
    private var deleted: [EventInfo] = []
    private var made = 0
    private let file = AppState.directory.appendingPathComponent("calendar-fake.json")

    init(seed: Bool) {
        guard seed else { return }
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        items = [
            EventInfo(id: "fake-yoga", title: "Йога", start: tomorrow.addingTimeInterval(10 * 3600),
                      end: tomorrow.addingTimeInterval(11 * 3600), allDay: false, recurring: false),
            EventInfo(id: "fake-standup", title: "Планёрка", start: tomorrow.addingTimeInterval(9.5 * 3600),
                      end: tomorrow.addingTimeInterval(9.75 * 3600), allDay: false, recurring: true),
        ]
    }

    func add(title: String, start: Date, end: Date, allDay: Bool) async throws -> EventInfo {
        made += 1
        let info = EventInfo(id: "fake-\(made)", title: title, start: start, end: end, allDay: allDay, recurring: false)
        items.append(info)
        try save()
        return info
    }

    func events(from: Date, to: Date) async throws -> [EventInfo] { items.filter { $0.end > from && $0.start < to } }

    func event(id: String) async throws -> EventInfo {
        guard let e = items.first(where: { $0.id == id }) else { throw CalendarAccessError.notFound }
        return e
    }

    func update(id: String, title: String?, start: Date?, end: Date?) async throws -> EventInfo {
        guard let i = items.firstIndex(where: { $0.id == id }) else { throw CalendarAccessError.notFound }
        guard !items[i].recurring else { throw CalendarAccessError.recurring }
        let e = items[i]
        items[i] = EventInfo(id: id, title: title ?? e.title, start: start ?? e.start, end: end ?? e.end, allDay: e.allDay,
                             recurring: false)
        try save()
        return items[i]
    }

    func delete(id: String) async throws {
        guard let i = items.firstIndex(where: { $0.id == id }) else { throw CalendarAccessError.notFound }
        guard !items[i].recurring else { throw CalendarAccessError.recurring }
        deleted.append(items.remove(at: i))
        try save()
    }

    private func save() throws {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        func row(_ e: EventInfo, _ state: String) -> [String: Any] {
            ["id": e.id, "title": e.title, "start": f.string(from: e.start), "end": f.string(from: e.end), "allDay": e.allDay,
             "recurring": e.recurring, "state": state]
        }
        let rows = items.map { row($0, "open") } + deleted.map { row($0, "deleted") }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }
}
