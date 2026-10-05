import Foundation
import Testing
@testable import ChilkBrain

@Suite("Chilk tool execution")
@MainActor
struct ChilkToolExecutorTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func file() -> URL {
        let base = ProcessInfo.processInfo.environment["CHILK_TEST_TMP"] ?? ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: base).appendingPathComponent("chilk-actions-\(UUID().uuidString)/timers.json")
    }

    @Test func toolsReallyScheduleListCancelAndRestoreANotice() throws {
        let path = file()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let fixedNow = now
        var water = 0
        let e = try ChilkToolExecutor(file: path, now: { fixedNow }, status: { ["minutes": 12] }, water: {
            water += 1
            return ["credited": true]
        })
        let timer = e.execute(name: "chilk_timer", arguments: ["seconds": 30, "title": "Чай"])
        #expect(timer.success)
        let id = try #require(timer.value["id"]?.string)
        let list = e.execute(name: "chilk_timers", arguments: [:])
        if case .array(let recorded) = list.value["timers"] {
            #expect(recorded.count == 1)
        } else { Issue.record("Expected a timer list") }
        let restored = try ChilkToolExecutor(file: path, now: { fixedNow })
        #expect(restored.entries.first?.id == id)
        #expect(restored.execute(name: "chilk_cancel_timer", arguments: ["id": .string(id)]).value["cancelled"]?.bool == true)
        #expect(try restored.collectDue(at: now.addingTimeInterval(60)).isEmpty)
        #expect(e.execute(name: "chilk_water", arguments: [:]).success)
        #expect(water == 1)
        #expect(e.execute(name: "chilk_water", arguments: ["extra": true]).success == false)
        #expect(water == 1)
        #expect(e.execute(name: "chilk_status", arguments: [:]).value["minutes"]?.int == 12)
    }

    @Test func theRegisteredCatalogMatchesTheSupportedActions() {
        #expect(Set(ChilkToolCatalog.tools.map(\.name)) == ["chilk_status", "chilk_water", "chilk_timer", "chilk_schedule", "chilk_timers", "chilk_cancel_timer", "chilk_find_files", "chilk_read_file", "chilk_append_note", "chilk_reminder", "chilk_reminders"])
        #expect(ChilkToolCatalog.tools.allSatisfy { $0.inputSchema["additionalProperties"]?.bool == false })
    }
}
