import ChilkBrain
import Foundation

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
