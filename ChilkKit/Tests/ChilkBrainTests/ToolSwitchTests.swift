import ChilkCore
import Foundation
import Testing
@testable import ChilkBrain

/// Slice 5a, decision 9: a tool switched off in the tray is gone from new threads and refused on live ones;
/// web search is switched off per thread (`thread/start` config, verified live on codex 0.160). Folder switches act
/// on the folder's kind (read-only shared folders, branch `breaks-readonly-files`).
@Suite("Tool switches")
struct ToolSwitchTests {
    private func names(_ tools: [CodexTool]) -> [String] { tools.map(\.name) }
    private static let folders: [String: ChilkFileScope] = ["Работа": .files, "Заметки": .obsidian]

    @Test func everythingOnIsTheFullCatalog() {
        #expect(names(ChilkToolCatalog.tools(for: ToolSwitches())) == names(ChilkToolCatalog.tools))
        #expect(ChilkToolCatalog.threadConfig(for: ToolSwitches()) == nil)
    }

    @Test func timersOffRemovesEveryTimerToolButNotTheAlwaysOnOnes() {
        var s = ToolSwitches()
        s.set(.timers, on: false)
        let list = names(ChilkToolCatalog.tools(for: s))
        for gone in ["chilk_timer", "chilk_schedule", "chilk_timers", "chilk_cancel_timer"] { #expect(!list.contains(gone)) }
        for kept in ["chilk_status", "chilk_water", "chilk_mode", "chilk_reminder", "chilk_find_files"] { #expect(list.contains(kept)) }
        #expect(list.first == "chilk_status")
    }

    @Test func remindersOffRemovesBothReminderTools() {
        var s = ToolSwitches()
        s.set(.reminders, on: false)
        let list = names(ChilkToolCatalog.tools(for: s))
        #expect(!list.contains("chilk_reminder") && !list.contains("chilk_reminders"))
    }

    @Test func folderToolsGoOnlyWhenBothKindsAreOff() {
        var s = ToolSwitches()
        s.set(.files, on: false)
        var list = names(ChilkToolCatalog.tools(for: s))
        // Vaults are still readable; asking for a new folder needs «Файлы».
        for kept in ["chilk_list_folders", "chilk_find_files", "chilk_read_file"] { #expect(list.contains(kept)) }
        #expect(!list.contains("chilk_request_folder"))
        s.set(.obsidian, on: false)
        list = names(ChilkToolCatalog.tools(for: s))
        for gone in ChilkToolCatalog.folderTools { #expect(!list.contains(gone)) }
    }

    @Test func aLiveThreadStillListingAToolIsRefusedByTheHost() {
        var s = ToolSwitches()
        s.set(.files, on: false)
        s.set(.timers, on: false)
        func off(_ name: String, _ args: JSON) -> ChilkAbility? {
            ChilkToolCatalog.switchedOff(name: name, arguments: args, switches: s, kindOf: { Self.folders[$0] })
        }
        #expect(off("chilk_read_file", ["folder": "Работа", "path": "a.md"]) == .files)
        #expect(off("chilk_read_file", ["folder": "Заметки", "path": "a.md"]) == nil)
        #expect(off("chilk_find_files", ["folder": "all", "query": "a", "offset": 0]) == nil)   // only vaults are visible
        #expect(off("chilk_request_folder", ["path": "~/Документы", "reason": "договор"]) == .files)
        #expect(off("chilk_cancel_timer", ["id": "x"]) == .timers)
        #expect(off("chilk_water", [:]) == nil)
        s.set(.obsidian, on: false)
        #expect(off("chilk_list_folders", [:]) == .files)
    }

    @Test func webSearchOffIsAThreadConfigOverride() {
        var s = ToolSwitches()
        s.set(.webSearch, on: false)
        #expect(ChilkToolCatalog.threadConfig(for: s) == ["web_search": "disabled"])
    }

    @Test func theClientSendsTheThreadConfig() async throws {
        let c = CodexClientTests().client()
        try await c.start()
        let plain = try await c.startThread(model: "gpt-6-luna", instructions: "", cwd: CodexClientTests.temporary)
        #expect(plain == "t1")
        let noSearch = try await c.startThread(model: "gpt-6-luna", instructions: "", cwd: CodexClientTests.temporary,
                                               config: ["web_search": "disabled"])
        #expect(noSearch == #"t1:{"web_search": "disabled"}"#)
        await c.stop()
    }
}
