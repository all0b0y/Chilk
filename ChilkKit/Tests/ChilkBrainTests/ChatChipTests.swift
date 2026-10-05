import ChilkCore
import Foundation
import Testing
@testable import ChilkBrain

/// Slice 5b, decisions 14 and 17: action chips under an answer, and Chilk's memory tool.
@Suite("Chat chips and memory tool")
struct ChatChipTests {
    private let ok = CodexToolResult(success: true, value: ["ok": true])
    private let failed = CodexToolResult.failure("nope")
    private func chip(_ name: String, _ args: JSON, _ result: CodexToolResult? = nil) -> ChatChip? {
        ChatChips.chip(name: name, arguments: args, result: result ?? ok)
    }

    @Test func timersAndReminders() throws {
        #expect(chip("chilk_timer", ["seconds": 600, "title": "чай"]) == ChatChip(kind: .timer, subject: "чай", minutes: 10))
        #expect(chip("chilk_timer", ["seconds": 30, "title": "яйцо"])?.minutes == 1)              // never «0 мин»
        let at = "2026-10-05T17:00:00+03:00"
        let schedule = try #require(chip("chilk_schedule", ["at": .string(at), "title": "звонок", "message": "Позвони маме"]))
        #expect(schedule.kind == .timer && schedule.subject == "звонок" && schedule.at != nil && schedule.minutes == nil)
        #expect(chip("chilk_cancel_timer", ["id": "x"]) == ChatChip(kind: .cancelTimer))
        let reminder = try #require(chip("chilk_reminder", ["title": "Купить хлеб", "at": .string(at)]))
        #expect(reminder.kind == .reminder && reminder.subject == "Купить хлеб" && reminder.at != nil)
    }

    @Test func filesShowOnlyTheFileName() {
        #expect(chip("chilk_read_file", ["folder": "Работа", "path": "Проекты/План.md"]) == ChatChip(kind: .readFile, subject: "План.md"))
        #expect(chip("chilk_find_files", ["folder": "all", "query": "договор", "offset": 0]) == ChatChip(kind: .findFiles))
        #expect(chip("chilk_request_folder", ["path": "~/Документы/Банк", "reason": "договор"]) == ChatChip(kind: .requestFolder, subject: "Банк"))
    }

    @Test func careModeBreaksAndMemory() {
        #expect(chip("chilk_water", [:]) == ChatChip(kind: .water))
        #expect(chip("chilk_mode", ["mode": "strict"]) == ChatChip(kind: .mode, subject: "strict"))
        #expect(chip("chilk_warmup", [:]) == ChatChip(kind: .takeBreak, subject: "warmup"))
        #expect(chip("chilk_breathe", ["minutes": 3]) == ChatChip(kind: .takeBreak, subject: "breathe", minutes: 3))
        #expect(chip("chilk_remember", ["fact": "пьёт чай без сахара", "asked": true]) == ChatChip(kind: .remember))
    }

    @Test func lookingIsNotAnAction() {
        for name in ["chilk_status", "chilk_timers", "chilk_reminders", "chilk_list_folders"] { #expect(chip(name, [:]) == nil) }
    }

    @Test func anOkCallThatDidNothingIsRed() {
        let notCredited = CodexToolResult.ok(["credited": false])
        #expect(chip("chilk_water", [:], notCredited) == ChatChip(kind: .water, failed: true))
        #expect(chip("chilk_cancel_timer", ["id": "x"], .ok(["cancelled": false]))?.failed == true)
        #expect(chip("chilk_mode", ["mode": "silent"], .ok(["mode": "strict", "changed": false, "refused": "escalation_in_progress"]))?.failed == true)
        #expect(chip("chilk_warmup", [:], .ok(["willStart": false, "reason": "pause_in_progress"]))?.failed == true)
        #expect(chip("chilk_water", [:], .ok(["credited": true]))?.failed == false)
        // «Already known» is not a failure.
        #expect(chip("chilk_remember", ["fact": "x", "asked": true], .ok(["added": false, "duplicate": true]))?.failed == false)
    }

    @Test func aFailureIsARedChipEvenWithBadArguments() {
        #expect(chip("chilk_timer", ["seconds": 600, "title": "чай"], failed)
                == ChatChip(kind: .timer, subject: "чай", minutes: 10, failed: true))
        #expect(chip("chilk_timer", ["oops": 1], failed) == ChatChip(kind: .timer, failed: true))
        #expect(chip("chilk_read_file", ["folder": "Работа", "path": "секрет.pdf"], failed)
                == ChatChip(kind: .readFile, subject: "секрет.pdf", failed: true))
        #expect(chip("chilk_status", [:], failed) == nil)
    }

    @Test func webSearchComesFromCodexItems() {
        let item: JSON = ["threadId": "t1", "item": ["type": "webSearch", "id": "ws1", "query": "курс евро"]]
        #expect(ChatChips.webSearch(item) == ChatChip(kind: .webSearch))
        #expect(ChatChips.webSearch(["threadId": "t1", "item": ["type": "agentMessage", "id": "m"]]) == nil)
    }

    @Test func rememberIsAlwaysThereAndParsed() throws {
        let tool = try #require(ChilkToolCatalog.tools.first { $0.name == "chilk_remember" })
        #expect(tool.description.contains("asked"))
        var all = ToolSwitches()
        for a in ChilkAbility.allCases { all.set(a, on: false) }
        #expect(ChilkToolCatalog.tools(for: all).contains { $0.name == "chilk_remember" })
        #expect(try ChilkToolCatalog.parse(name: "chilk_remember", arguments: ["fact": "любит кофе", "asked": false])
                == .remember(fact: "любит кофе", asked: false))
        #expect(throws: (any Error).self) { try ChilkToolCatalog.parse(name: "chilk_remember", arguments: ["fact": "x"]) }
        #expect(throws: (any Error).self) {
            try ChilkToolCatalog.parse(name: "chilk_remember", arguments: ["fact": .string(String(repeating: "a", count: 201)), "asked": true])
        }
    }
}
