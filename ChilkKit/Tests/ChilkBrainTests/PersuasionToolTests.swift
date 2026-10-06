import ChilkCore
import Foundation
import Testing
@testable import ChilkBrain

/// Slice 4b: the persuasion and focus tools — parsed again on the host, always on, chips from the engine's answer.
@Suite("Persuasion and focus tools")
@MainActor
struct PersuasionToolTests {
    @Test func argumentsAreParsedStrictly() throws {
        #expect(try ChilkToolCatalog.parse(name: "chilk_defer", arguments: ["minutes": 30]) == .deferRequest(minutes: 30))
        #expect(throws: ChilkToolCatalog.ToolError.self) { try ChilkToolCatalog.parse(name: "chilk_defer", arguments: ["minutes": 45]) }
        #expect(throws: ChilkToolCatalog.ToolError.self) {
            try ChilkToolCatalog.parse(name: "chilk_defer", arguments: ["minutes": 15, "reason": "созвон"])
        }
        #expect(try ChilkToolCatalog.parse(name: "chilk_focus", arguments: ["minutes": 120]) == .focus(minutes: 120))
        let bad: [JSON] = [["minutes": 0], ["minutes": 721], ["minutes": .number(1.5)], [:]]
        for args in bad {
            #expect(throws: ChilkToolCatalog.ToolError.self) { try ChilkToolCatalog.parse(name: "chilk_focus", arguments: args) }
        }
        #expect(try ChilkToolCatalog.parse(name: "chilk_end_focus", arguments: [:]) == .endFocus)
    }

    @Test func theyAreAlwaysOnLikeTheMode() {
        var off = ToolSwitches()
        for a in ChilkAbility.allCases { off.set(a, on: false) }
        let names = Set(ChilkToolCatalog.tools(for: off).map(\.name))
        #expect(names.isSuperset(of: ["chilk_defer", "chilk_focus", "chilk_end_focus", "chilk_mode"]))
    }

    @Test func theExecutorHandsThemToTheApp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var calls: [String] = []
        let executor = try ChilkToolExecutor(file: dir.appendingPathComponent("timers.json"),
            persuade: { m in calls.append("defer \(m)"); return ["deferred": true, "minutes": 15] },
            focus: { m in calls.append("focus \(m)"); return ["focus": true] },
            endFocus: { calls.append("end"); return ["ended": true] })
        #expect(executor.execute(name: "chilk_defer", arguments: ["minutes": 60]).success)
        #expect(executor.execute(name: "chilk_focus", arguments: ["minutes": 90]).success)
        #expect(executor.execute(name: "chilk_end_focus", arguments: [:]).success)
        #expect(!executor.execute(name: "chilk_defer", arguments: ["minutes": 5]).success)
        #expect(calls == ["defer 60", "focus 90", "end"])
    }

    @Test func chipsShowWhatTheEngineGranted() {
        let granted = CodexToolResult(success: true, value: ["deferred": true, "need": "stretch", "minutes": 30])
        #expect(ChatChips.chip(name: "chilk_defer", arguments: ["minutes": 60], result: granted)
                == ChatChip(kind: .deferRequest, subject: "stretch", minutes: 30))
        let refused = CodexToolResult(success: true, value: ["deferred": false, "refused": "limit_reached"])
        #expect(ChatChips.chip(name: "chilk_defer", arguments: ["minutes": 15], result: refused)
                == ChatChip(kind: .deferRequest, failed: true))
        let until = "2026-10-06T18:00:00+03:00"
        let focus = CodexToolResult(success: true, value: ["focus": true, "until": .string(until), "minutes": 120])
        let chip = ChatChips.chip(name: "chilk_focus", arguments: ["minutes": 120], result: focus)
        #expect(chip?.kind == .focus && chip?.at == ChilkToolCatalog.timestamp(until) && chip?.failed == false)
        #expect(ChatChips.chip(name: "chilk_focus", arguments: ["minutes": 60],
                               result: CodexToolResult(success: true, value: ["focus": false, "refused": "escalation_in_progress"]))?.failed == true)
        #expect(ChatChips.chip(name: "chilk_end_focus", arguments: [:], result: CodexToolResult(success: true, value: ["ended": false]))
                == ChatChip(kind: .endFocus, failed: true))
    }
}
