import Foundation
import Testing
@testable import ChilkBrain

/// Decision 2026-10-05: «напомни завтра утром…» goes to Apple Reminders, Chilk's own list, create and read only.
@Suite("Apple Reminders tools")
struct ChilkReminderTests {
    actor FakeStore: ReminderStore {
        var added: [ReminderInfo] = []
        var deny = false
        var items: [ReminderInfo] = []
        func setDeny(_ value: Bool) { deny = value }
        func setItems(_ value: [ReminderInfo]) { items = value }
        func add(title: String, due: Date, timed: Bool) async throws -> ReminderInfo {
            if deny { throw ReminderAccessError.denied }
            let info = ReminderInfo(title: title, due: due, timed: timed)
            added.append(info)
            return info
        }
        func open() async throws -> [ReminderInfo] {
            if deny { throw ReminderAccessError.denied }
            return items
        }
        var changed: [String] = []
        func update(id: String, title: String?, due: Date?, timed: Bool) async throws -> ReminderInfo {
            guard let r = items.first(where: { $0.id == id }) else { throw ReminderAccessError.notFound }
            changed.append("update \(id)")
            return ReminderInfo(title: title ?? r.title, due: due ?? r.due, id: id, timed: due == nil ? r.timed : timed)
        }
        func setDone(id: String, done: Bool) async throws {
            guard items.contains(where: { $0.id == id }) else { throw ReminderAccessError.notFound }
            changed.append(done ? "complete \(id)" : "reopen \(id)")
        }
        func day(_ day: Date) async throws -> [ReminderInfo] {
            if deny { throw ReminderAccessError.denied }
            return items.filter { $0.due.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false }
        }
        func delete(id: String) async throws {
            guard items.contains(where: { $0.id == id }) else { throw ReminderAccessError.notFound }
            changed.append("delete \(id)")
        }
    }

    let now = Date(timeIntervalSince1970: 1_700_000_000)              // 2023-11-14T22:13:20Z

    @Test func aReminderNeedsAFutureTimestampWithATimezoneAndATitle() throws {
        let at = Date(timeIntervalSince1970: 1_700_032_400)
        #expect(try ChilkToolCatalog.parse(name: "chilk_reminder", arguments: ["at": "2023-11-15T10:13:20+03:00", "title": " Позвонить маме "])
                == .reminder(title: "Позвонить маме", at: at))
        // Slice 8c: without a zone it is local time (the card shows what it became).
        #expect(try ChilkToolCatalog.parse(name: "chilk_reminder", arguments: ["at": "2023-11-15T10:13:20", "title": "Маме"])
                == .reminder(title: "Маме", at: ChilkToolCatalog.timestamp("2023-11-15T10:13:20", zone: .autoupdatingCurrent)!))
        for bad: JSON in [["at": "завтра", "title": "Маме"], ["at": "2023-11-15", "title": "Маме"],
                          ["at": "2023-11-15T10:13:20+03:00", "title": "  "], ["at": "2023-11-15T10:13:20+03:00"],
                          ["at": "2023-11-15T10:13:20+03:00", "title": .string(String(repeating: "м", count: 121))],
                          ["at": "2023-11-15T10:13:20+03:00", "title": "Маме", "list": "Работа"]] {
            #expect(throws: ChilkToolCatalog.ToolError.self) { try ChilkToolCatalog.parse(name: "chilk_reminder", arguments: bad) }
        }
        #expect(throws: ChilkToolCatalog.ToolError.self) { try ChilkToolCatalog.parse(name: "chilk_reminders", arguments: ["list": "Работа"]) }
        #expect(ChilkToolCatalog.tools.contains { $0.name == "chilk_reminder" } && ChilkToolCatalog.tools.contains { $0.name == "chilk_reminders" })
    }

    /// Slice 8c: the executor never creates on a tool call — only `create` after the card's «Да».
    @Test func aReminderIsCreatedOnlyAfterTheCardAndReportedWithItsTime() async {
        let store = FakeStore()
        let e = ChilkReminderExecutor(store: store, now: { [now] in now })
        let proposal = await e.execute(name: "chilk_reminder", arguments: ["at": "2023-11-15T09:00:00+03:00", "title": "Позвонить маме"])
        #expect(!proposal.success)
        #expect(await store.added.isEmpty)
        #expect(ChilkReminderExecutor.proposes("chilk_reminder") && ChilkReminderExecutor.proposes("chilk_reminder_change"))
        let result = await e.create(title: "Позвонить маме", due: now.addingTimeInterval(3600))
        #expect(result.success)
        #expect(result.value["title"]?.string == "Позвонить маме")
        #expect(result.value["list"]?.string == "Чилк")
        #expect(result.value["at"]?.string != nil)
        #expect(await store.added.count == 1)
    }

    @Test func deniedAccessCreatesNothingAndSaysWhy() async {
        let store = FakeStore()
        let e = ChilkReminderExecutor(store: store, now: { [now] in now })
        await store.setDeny(true)
        let denied = await e.create(title: "Чай", due: now.addingTimeInterval(3600))
        #expect(!denied.success)
        #expect(denied.value["error"]?.string?.contains("Privacy & Security → Reminders") == true)
        #expect(await store.added.isEmpty)
    }

    /// Slice 8c (decision 7): changes by id, only of the «Чилк» list.
    @Test func changesGoByIdAndAnUnknownIdIsNotFound() async throws {
        #expect(try ChilkToolCatalog.parse(name: "chilk_reminder_change",
                                           arguments: ["id": "r1", "action": "done", "at": "", "title": ""])
                == .reminderChange(id: "r1", change: .done))
        #expect(try ChilkToolCatalog.parse(name: "chilk_reminder_change",
                                           arguments: ["id": "r1", "action": "rename", "at": "", "title": " Хлеб "])
                == .reminderChange(id: "r1", change: .rename("Хлеб")))
        #expect(throws: ChilkToolCatalog.ToolError.self) {
            try ChilkToolCatalog.parse(name: "chilk_reminder_change", arguments: ["id": "r1", "action": "move", "at": "", "title": ""])
        }
        let store = FakeStore()
        await store.setItems([ReminderInfo(title: "Хлеб", due: now, id: "r1")])
        let e = ChilkReminderExecutor(store: store, now: { [now] in now })
        #expect(try await e.lookup(id: "r1").title == "Хлеб")
        await #expect(throws: ReminderAccessError.self) { try await e.lookup(id: "zz") }
        #expect(await e.complete(id: "r1").success)
        let missing = await e.delete(id: "zz")
        #expect(missing.value["error"]?.string?.hasPrefix("not_found") == true)
        #expect(await store.changed == ["complete r1"])
        let listed = await e.execute(name: "chilk_reminders", arguments: [:])
        guard case .array(let items) = listed.value["reminders"] else { Issue.record("Expected a list"); return }
        #expect(items.first?["id"]?.string == "r1")
    }

    @Test func theListIsSortedByDueAndBounded() async {
        let store = FakeStore()
        await store.setItems((0..<60).map { ReminderInfo(title: "№\($0)", due: now.addingTimeInterval(Double(60 - $0) * 60)) }
                             + [ReminderInfo(title: "Без срока", due: nil)])
        let e = ChilkReminderExecutor(store: store, now: { [now] in now })
        let result = await e.execute(name: "chilk_reminders", arguments: [:])
        #expect(result.success)
        guard case .array(let items) = result.value["reminders"] else { Issue.record("Expected a list"); return }
        #expect(items.count == 50)
        #expect(items.first?["title"]?.string == "№59")
        #expect(result.value["hasMore"]?.bool == true)
    }

    @MainActor
    @Test func theTimerExecutorDoesNotTouchReminders() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("timers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try ChilkToolExecutor(file: file).execute(name: "chilk_reminders", arguments: [:])
        #expect(result.success == false)
        #expect(ChilkReminderExecutor.handles("chilk_reminders") && !ChilkReminderExecutor.handles("chilk_timer"))
    }
}
