import Foundation
import Testing
import ChilkCore
@testable import ChilkBrain

// Slice 6d (decision 17): «Чилк, спрячься» / «выходи» by voice or chat — `chilk_hide`.

@MainActor
struct HideToolTests {
    @Test func theToolIsAlwaysThereAndParsesHiddenOnly() throws {
        var off = ToolSwitches()
        for a in ChilkAbility.allCases { off.set(a, on: false) }
        #expect(ChilkToolCatalog.tools(for: off).contains { $0.name == "chilk_hide" })
        #expect(try ChilkToolCatalog.parse(name: "chilk_hide", arguments: ["hidden": true]) == .hide(true))
        #expect(try ChilkToolCatalog.parse(name: "chilk_hide", arguments: ["hidden": false]) == .hide(false))
        for bad: JSON in [[:], ["hidden": "yes"], ["hidden": true, "now": true]] {
            #expect(throws: ChilkToolCatalog.ToolError.self) { try ChilkToolCatalog.parse(name: "chilk_hide", arguments: bad) }
        }
    }

    @Test func theExecutorHandsItToTheApp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var asked: [Bool] = []
        let executor = try ChilkToolExecutor(file: dir.appendingPathComponent("timers.json"),
                                             hide: { asked.append($0); return ["hidden": .bool($0), "changed": true] })
        let r = executor.execute(name: "chilk_hide", arguments: ["hidden": true])
        #expect(r.success && r.value["hidden"]?.bool == true)
        #expect(asked == [true])
    }

    @Test func aChipSaysWhatHappened() {
        let hid = ChatChips.chip(name: "chilk_hide", arguments: ["hidden": true], result: .ok(["hidden": true, "changed": true]))
        #expect(hid?.kind == .hide && hid?.subject == "hidden" && hid?.failed == false)
        let out = ChatChips.chip(name: "chilk_hide", arguments: ["hidden": false], result: .ok(["hidden": false, "changed": true]))
        #expect(out?.subject == "shown")
        let already = ChatChips.chip(name: "chilk_hide", arguments: ["hidden": true], result: .ok(["hidden": true, "changed": false]))
        #expect(already?.failed == true)                             // nothing changed: red, like other no-ops
    }

    @Test func anOpenTimeQuestionLeavesNoChip() {
        let asked = ChatChips.chip(name: "chilk_reminder", arguments: ["at": "2026-10-07T03:00:00+03:00", "title": "Маме"],
                                   result: .failure("ambiguous_time: the user said 3 …"))
        #expect(asked == nil)
        let failed = ChatChips.chip(name: "chilk_reminder", arguments: ["at": "x", "title": "Маме"], result: .failure("denied"))
        #expect(failed?.failed == true)
    }
}
