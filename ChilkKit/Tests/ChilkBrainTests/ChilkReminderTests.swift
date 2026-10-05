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
        func add(title: String, due: Date) async throws -> ReminderInfo {
            if deny { throw ReminderAccessError.denied }
            let info = ReminderInfo(title: title, due: due)
            added.append(info)
            return info
        }
        func open() async throws -> [ReminderInfo] {
            if deny { throw ReminderAccessError.denied }
            return items
        }
    }

    let now = Date(timeIntervalSince1970: 1_700_000_000)              // 2023-11-14T22:13:20Z

    @Test func aReminderNeedsAFutureTimestampWithATimezoneAndATitle() throws {
        let at = Date(timeIntervalSince1970: 1_700_032_400)
        #expect(try ChilkToolCatalog.parse(name: "chilk_reminder", arguments: ["at": "2023-11-15T10:13:20+03:00", "title": " Позвонить маме "])
                == .reminder(title: "Позвонить маме", at: at))
        for bad: JSON in [["at": "2023-11-15T10:13:20", "title": "Маме"], ["at": "завтра", "title": "Маме"],
                          ["at": "2023-11-15T10:13:20+03:00", "title": "  "], ["at": "2023-11-15T10:13:20+03:00"],
                          ["at": "2023-11-15T10:13:20+03:00", "title": .string(String(repeating: "м", count: 121))],
                          ["at": "2023-11-15T10:13:20+03:00", "title": "Маме", "list": "Работа"]] {
            #expect(throws: ChilkToolCatalog.ToolError.self) { try ChilkToolCatalog.parse(name: "chilk_reminder", arguments: bad) }
        }
        #expect(throws: ChilkToolCatalog.ToolError.self) { try ChilkToolCatalog.parse(name: "chilk_reminders", arguments: ["list": "Работа"]) }
        #expect(ChilkToolCatalog.tools.contains { $0.name == "chilk_reminder" } && ChilkToolCatalog.tools.contains { $0.name == "chilk_reminders" })
    }

    @Test func aReminderIsCreatedInChilksListAndReportedWithItsTime() async {
        let store = FakeStore()
        let e = ChilkReminderExecutor(store: store, now: { [now] in now })
        let result = await e.execute(name: "chilk_reminder", arguments: ["at": "2023-11-15T09:00:00+03:00", "title": "Позвонить маме"])
        #expect(result.success)
        #expect(result.value["title"]?.string == "Позвонить маме")
        #expect(result.value["list"]?.string == "Чилк")
        #expect(result.value["at"]?.string != nil)
        #expect(await store.added.count == 1)
    }

    @Test func aPastTimeOrDeniedAccessCreatesNothingAndSaysWhy() async {
        let store = FakeStore()
        let e = ChilkReminderExecutor(store: store, now: { [now] in now })
        let past = await e.execute(name: "chilk_reminder", arguments: ["at": "2023-11-14T20:00:00Z", "title": "Чай"])
        #expect(!past.success)
        await store.setDeny(true)
        let denied = await e.execute(name: "chilk_reminder", arguments: ["at": "2023-11-15T09:00:00+03:00", "title": "Чай"])
        #expect(!denied.success)
        #expect(denied.value["error"]?.string?.contains("Privacy & Security → Reminders") == true)
        #expect(await store.added.isEmpty)
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
        #expect(ChilkReminderExecutor.handles("chilk_reminder") && !ChilkReminderExecutor.handles("chilk_timer"))
    }
}
