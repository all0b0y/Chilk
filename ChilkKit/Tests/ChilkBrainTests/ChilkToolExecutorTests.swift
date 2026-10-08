import Foundation
import Testing
@testable import ChilkBrain
import ChilkCore

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
        let at = ISO8601DateFormatter().string(from: fixedNow.addingTimeInterval(30))
        let timer = e.execute(name: "chilk_schedule", arguments: ["at": .string(at), "title": "Чай", "message": "Чай готов"])
        #expect(!e.execute(name: "chilk_timer", arguments: ["seconds": 30, "title": "Чай"]).success)   // 8d: Clock
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
        #expect(Set(ChilkToolCatalog.tools.map(\.name)) == ["chilk_status", "chilk_water", "chilk_timer", "chilk_clock_open", "chilk_schedule", "chilk_timers", "chilk_cancel_timer", "chilk_find_files", "chilk_read_file", "chilk_list_folders", "chilk_request_folder", "chilk_reminder", "chilk_reminders", "chilk_reminder_change", "chilk_plan", "chilk_plan_show", "chilk_event", "chilk_events", "chilk_event_change", "chilk_note", "chilk_notes", "chilk_note_change", "chilk_mode", "chilk_eye_gym", "chilk_warmup", "chilk_breathe", "chilk_walk", "chilk_remember", "chilk_defer", "chilk_focus", "chilk_end_focus", "chilk_emote", "chilk_hide", "chilk_game"])
        #expect(ChilkToolCatalog.tools.allSatisfy { $0.inputSchema["additionalProperties"]?.bool == false })
    }

    @Test func theModeToolTakesOnlyAKnownModeAndReportsWhatTheAppDecided() throws {
        #expect(try ChilkToolCatalog.parse(name: "chilk_mode", arguments: ["mode": "strict"]) == .mode(.strict))
        #expect(throws: ChilkToolCatalog.ToolError.self) { try ChilkToolCatalog.parse(name: "chilk_mode", arguments: ["mode": "harsh"]) }
        #expect(throws: ChilkToolCatalog.ToolError.self) { try ChilkToolCatalog.parse(name: "chilk_mode", arguments: [:]) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mode-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var asked: [BalanceMode] = []
        let e = try ChilkToolExecutor(file: file, mode: { m in
            asked.append(m)
            return m == .soft ? ["mode": "strict", "changed": false, "refused": "escalation"] : ["mode": .string(m.rawValue), "changed": true]
        })
        #expect(e.execute(name: "chilk_mode", arguments: ["mode": "strict"]).value["changed"]?.bool == true)
        #expect(e.execute(name: "chilk_mode", arguments: ["mode": "soft"]).value["refused"]?.string == "escalation")
        #expect(asked == [.strict, .soft])
    }

    /// Decisions 2026-10-05: the four breaks by voice reach the app callback; breathing is 1 or 3 minutes.
    @Test func breaksByVoiceReachTheAppAndBreathingIsOneOrThreeMinutes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var asked: [ChilkBreak] = []
        let executor = try ChilkToolExecutor(file: dir.appendingPathComponent("timers.json"),
                                             breaks: { asked.append($0); return ["willStartAfterReply": true] })
        for name in ["chilk_eye_gym", "chilk_warmup", "chilk_walk"] {
            #expect(executor.execute(name: name, arguments: [:]).value["willStartAfterReply"]?.bool == true)
        }
        #expect(executor.execute(name: "chilk_breathe", arguments: ["minutes": 3]).success)
        #expect(asked == [.eyeGym, .warmup, .walk, .breathe(minutes: 3)])
        for bad: JSON in [["minutes": 2], ["minutes": "1"], [:], ["minutes": 1, "x": 1]] {
            #expect(!executor.execute(name: "chilk_breathe", arguments: bad).success)
        }
        #expect(!executor.execute(name: "chilk_warmup", arguments: ["minutes": 5]).success)
        #expect(asked.count == 4)
    }
}
