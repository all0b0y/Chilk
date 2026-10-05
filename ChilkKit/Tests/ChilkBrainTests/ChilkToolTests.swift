import Foundation
import Testing
@testable import ChilkBrain

@Suite("Chilk tool arguments")
struct ChilkToolTests {
    @Test func onlyTheAllowlistedActionsAndTheirExactParametersAreAccepted() throws {
        #expect(try ChilkToolCatalog.parse(name: "chilk_status", arguments: [:]) == .status)
        #expect(try ChilkToolCatalog.parse(name: "chilk_water", arguments: [:]) == .water)
        #expect(try ChilkToolCatalog.parse(name: "chilk_timers", arguments: [:]) == .timers)
        #expect(try ChilkToolCatalog.parse(name: "chilk_cancel_timer", arguments: ["id": "EXACT-ID"]) == .cancel(id: "EXACT-ID"))
        #expect(throws: (any Error).self) { try ChilkToolCatalog.parse(name: "shell", arguments: [:]) }
        #expect(throws: (any Error).self) { try ChilkToolCatalog.parse(name: "chilk_water", arguments: ["path": "/etc/passwd"]) }
        #expect(throws: (any Error).self) { try ChilkToolCatalog.parse(name: "chilk_cancel_timer", arguments: ["id": ""]) }
    }

    @Test func fileActionsRequireAnExactScopeRelativePathAndBoundedPage() throws {
        #expect(throws: Never.self) {
            _ = try ChilkToolCatalog.parse(name: "chilk_find_files", arguments: ["scope": "files", "query": "отчёт", "offset": 0])
            _ = try ChilkToolCatalog.parse(name: "chilk_read_file", arguments: ["scope": "obsidian", "path": "Учёба/Сети.md"])
            _ = try ChilkToolCatalog.parse(name: "chilk_append_note", arguments: ["path": "Идеи.md", "text": "Мысль"])
        }
        let invalidSearches: [JSON] = [
            ["scope": "home", "query": "отчёт", "offset": 0],
            ["scope": "files", "query": "отчёт", "offset": "0"],
            ["scope": "files", "query": " ", "offset": 0],
            ["scope": "files", "query": "отчёт", "offset": .number(0.5)],
            ["scope": "files", "query": "отчёт", "offset": 10001],
            ["scope": "files", "query": "отчёт", "offset": 0, "root": "/"],
        ]
        for bad in invalidSearches { #expect(throws: (any Error).self) { try ChilkToolCatalog.parse(name: "chilk_find_files", arguments: bad) } }
        for path in ["/etc/passwd", "../note.md", "notes/../note.md", "notes//a.md", "~/note.md", "notes/./a.md", "a\u{0}.md"] {
            #expect(throws: (any Error).self) { try ChilkToolCatalog.parse(name: "chilk_read_file", arguments: ["scope": "files", "path": .string(path)]) }
        }
        #expect(throws: (any Error).self) { try ChilkToolCatalog.parse(name: "chilk_append_note", arguments: ["path": "a.md", "text": " "]) }
    }

    @Test func absoluteTimesNeedAnExplicitTimezoneAndAShortMessage() throws {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(try ChilkToolCatalog.parse(name: "chilk_schedule", arguments: ["at": "2023-11-15T01:13:20+03:00", "title": "Чай", "message": "Пора"]) == .schedule(at: at, title: "Чай", message: "Пора"))
        #expect(throws: (any Error).self) {
            try ChilkToolCatalog.parse(name: "chilk_schedule", arguments: ["at": "2023-11-15T01:13:20", "title": "Чай", "message": "Пора"])
        }
        #expect(throws: (any Error).self) {
            try ChilkToolCatalog.parse(name: "chilk_schedule", arguments: ["at": "2023-11-15T01:13:20+03:00", "title": "Чай", "message": .string(String(repeating: "ч", count: 241))])
        }
    }

    @Test func relativeTimersRequireAnExactIntegerAndNoExtraFields() throws {
        #expect(try ChilkToolCatalog.parse(name: "chilk_timer", arguments: ["seconds": 30, "title": "Чай"]) == .timer(seconds: 30, title: "Чай"))
        #expect(throws: (any Error).self) {
            try ChilkToolCatalog.parse(name: "chilk_timer", arguments: ["seconds": .number(1.5), "title": "Чай"])
        }
        #expect(throws: (any Error).self) {
            try ChilkToolCatalog.parse(name: "chilk_timer", arguments: ["seconds": "30", "title": "Чай"])
        }
        #expect(throws: (any Error).self) {
            try ChilkToolCatalog.parse(name: "chilk_timer", arguments: ["seconds": 30, "title": "Чай", "command": "touch /tmp/no"])
        }
    }
}
