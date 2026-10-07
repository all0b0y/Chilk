import ChilkBrain
import Foundation

/// Acceptance runs (CHILK_FAKE_REMINDERS): the real Codex and tool path without touching the user's Reminders.
/// Every created reminder is appended to `reminders-fake.json` in CHILK_STATE_DIR.
actor FakeReminders: ReminderStore {
    private var items: [ReminderInfo] = []
    private let file = AppState.directory.appendingPathComponent("reminders-fake.json")

    private var done: [ReminderInfo] = []

    func add(title: String, due: Date) async throws -> ReminderInfo {
        let info = ReminderInfo(title: title, due: due, id: "fake-\(UUID().uuidString.prefix(8))")
        items.append(info)
        try save()
        return info
    }

    func open() async throws -> [ReminderInfo] { items }

    func update(id: String, title: String?, due: Date?) async throws -> ReminderInfo {
        guard let i = items.firstIndex(where: { $0.id == id }) else { throw ReminderAccessError.notFound }
        items[i] = ReminderInfo(title: title ?? items[i].title, due: due ?? items[i].due, id: id)
        try save()
        return items[i]
    }

    func complete(id: String) async throws {
        guard let i = items.firstIndex(where: { $0.id == id }) else { throw ReminderAccessError.notFound }
        done.append(items.remove(at: i))
        try save()
    }

    func delete(id: String) async throws {
        guard items.contains(where: { $0.id == id }) else { throw ReminderAccessError.notFound }
        items.removeAll { $0.id == id }
        try save()
    }

    private func save() throws {
        let f = ISO8601DateFormatter()
        func row(_ r: ReminderInfo, _ state: String) -> [String: String] {
            ["id": r.id ?? "", "title": r.title, "at": r.due.map { f.string(from: $0) } ?? "", "state": state]
        }
        let rows = items.map { row($0, "open") } + done.map { row($0, "done") }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]).write(to: file, options: .atomic)
    }
}
