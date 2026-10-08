import ChilkBrain
import Foundation

/// Acceptance runs (CHILK_FAKE_REMINDERS=1 | seed): the real Codex and tool path without touching the user's Reminders.
/// The list lives in `reminders-fake.json` in CHILK_STATE_DIR (read back at launch, so a run can be continued).
/// Slice 9b: `seed` starts with three things planned for tomorrow (one done), for «На … уже 3 дела — добавим?»;
/// `seed-today` — the same three for today (the popover's «План: 1 из 3», «Сегодня»); `seed-yesterday` — for
/// yesterday (the morning's «Вчера не подвели итоги — подвести?»).
actor FakeReminders: ReminderStore {
    private struct Row: Codable {
        var id: String
        var title: String
        var at: String
        var timed: Bool?
        var state: String
    }

    private var items: [ReminderInfo] = []
    private let file = AppState.directory.appendingPathComponent("reminders-fake.json")

    init(seedDay: Int? = nil) {
        let f = ISO8601DateFormatter()
        if let data = try? Data(contentsOf: file), let rows = try? JSONDecoder().decode([Row].self, from: data) {
            items = rows.map { r in
                ReminderInfo(title: r.title, due: r.at.isEmpty ? nil : f.date(from: r.at), id: r.id, timed: r.timed ?? true,
                             done: r.state == "done")
            }
        } else if let seedDay {
            let cal = Calendar.current
            let tomorrow = cal.date(byAdding: .day, value: seedDay, to: cal.startOfDay(for: Date()))!
            items = [ReminderInfo(title: "зал", due: tomorrow.addingTimeInterval(8 * 3600), id: "fake-seed-1"),
                     ReminderInfo(title: "стирка", due: tomorrow, id: "fake-seed-2", timed: false),
                     ReminderInfo(title: "почта", due: tomorrow, id: "fake-seed-3", timed: false, done: true)]
        }
    }

    func add(title: String, due: Date, timed: Bool) async throws -> ReminderInfo {
        let day = timed ? due : Calendar.current.startOfDay(for: due)
        let info = ReminderInfo(title: title, due: day, id: "fake-\(UUID().uuidString.prefix(8))", timed: timed)
        items.append(info)
        try save()
        return info
    }

    func open() async throws -> [ReminderInfo] { items.filter { !$0.done } }

    func update(id: String, title: String?, due: Date?, timed: Bool) async throws -> ReminderInfo {
        guard let i = items.firstIndex(where: { $0.id == id }) else { throw ReminderAccessError.notFound }
        let old = items[i]
        let newDue = due.map { timed ? $0 : Calendar.current.startOfDay(for: $0) } ?? old.due
        items[i] = ReminderInfo(title: title ?? old.title, due: newDue, id: id, timed: due == nil ? old.timed : timed, done: old.done)
        try save()
        return items[i]
    }

    func setDone(id: String, done: Bool) async throws {
        guard let i = items.firstIndex(where: { $0.id == id }) else { throw ReminderAccessError.notFound }
        let r = items[i]
        items[i] = ReminderInfo(title: r.title, due: r.due, id: id, timed: r.timed, done: done)
        try save()
    }

    func delete(id: String) async throws {
        guard items.contains(where: { $0.id == id }) else { throw ReminderAccessError.notFound }
        items.removeAll { $0.id == id }
        try save()
    }

    func day(_ day: Date) async throws -> [ReminderInfo] {
        items.filter { $0.due.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false }
    }

    private func save() throws {
        let f = ISO8601DateFormatter()
        let rows = items.map { r in
            Row(id: r.id ?? "", title: r.title, at: r.due.map { f.string(from: $0) } ?? "", timed: r.timed, state: r.done ? "done" : "open")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(rows).write(to: file, options: .atomic)
    }
}
