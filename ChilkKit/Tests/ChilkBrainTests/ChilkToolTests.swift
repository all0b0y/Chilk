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

    @Test func fileActionsRequireAFolderNameRelativePathAndBoundedPage() throws {
        #expect(throws: Never.self) {
            _ = try ChilkToolCatalog.parse(name: "chilk_find_files", arguments: ["folder": "all", "query": "отчёт", "offset": 0])
            _ = try ChilkToolCatalog.parse(name: "chilk_read_file", arguments: ["folder": "Хранилище", "path": "Учёба/Сети.md"])
            _ = try ChilkToolCatalog.parse(name: "chilk_list_folders", arguments: [:])
            _ = try ChilkToolCatalog.parse(name: "chilk_request_folder", arguments: ["path": "~/Documents/Работа", "reason": "ищу договор"])
        }
        let invalidSearches: [JSON] = [
            ["scope": "files", "query": "отчёт", "offset": 0],
            ["folder": "", "query": "отчёт", "offset": 0],
            ["folder": "all", "query": "отчёт", "offset": "0"],
            ["folder": "all", "query": " ", "offset": 0],
            ["folder": "all", "query": "отчёт", "offset": .number(0.5)],
            ["folder": "all", "query": "отчёт", "offset": 10001],
            ["folder": "all", "query": "отчёт", "offset": 0, "root": "/"],
        ]
        for bad in invalidSearches { #expect(throws: (any Error).self) { try ChilkToolCatalog.parse(name: "chilk_find_files", arguments: bad) } }
        for path in ["/etc/passwd", "../note.md", "notes/../note.md", "notes//a.md", "~/note.md", "notes/./a.md", "a\u{0}.md"] {
            #expect(throws: (any Error).self) { try ChilkToolCatalog.parse(name: "chilk_read_file", arguments: ["folder": "Папка", "path": .string(path)]) }
        }
        for path in ["Documents", "~", "~/", "../x", "/Users/../etc", "~/a/../b", "/a\u{0}b"] {
            #expect(throws: (any Error).self) { try ChilkToolCatalog.parse(name: "chilk_request_folder", arguments: ["path": .string(path), "reason": "ищу"]) }
        }
        #expect(throws: (any Error).self) { try ChilkToolCatalog.parse(name: "chilk_request_folder", arguments: ["path": "~/Documents", "reason": " "]) }
        #expect(throws: (any Error).self) { try ChilkToolCatalog.parse(name: "chilk_append_note", arguments: ["path": "a.md", "text": "Мысль"]) }
    }

    @Test func absoluteTimesNeedAnExplicitTimezoneAndAShortMessage() throws {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(try ChilkToolCatalog.parse(name: "chilk_schedule", arguments: ["at": "2023-11-15T01:13:20+03:00", "title": "Чай", "message": "Пора"]) == .schedule(at: at, title: "Чай", message: "Пора"))
        // Slice 8c: without a zone it is local time (the card shows it before anything is scheduled).
        #expect(throws: Never.self) {
            try ChilkToolCatalog.parse(name: "chilk_schedule", arguments: ["at": "2023-11-15T01:13:20", "title": "Чай", "message": "Пора"])
        }
        #expect(throws: (any Error).self) {
            try ChilkToolCatalog.parse(name: "chilk_schedule", arguments: ["at": "15 ноября", "title": "Чай", "message": "Пора"])
        }
        #expect(throws: (any Error).self) {
            try ChilkToolCatalog.parse(name: "chilk_schedule", arguments: ["at": "2023-11-15T01:13:20+03:00", "title": "Чай", "message": .string(String(repeating: "ч", count: 241))])
        }
    }

    @Test func relativeTimersRequireAnExactIntegerAndNoExtraFields() throws {
        #expect(try ChilkToolCatalog.parse(name: "chilk_timer", arguments: ["seconds": 30, "title": "Чай"]) == .timer(seconds: 30, title: "Чай"))
        #expect(try ChilkToolCatalog.parse(name: "chilk_clock_open", arguments: [:]) == .openClock)
        #expect(throws: (any Error).self) {                              // Clock's timer: 23:59:59 at most
            try ChilkToolCatalog.parse(name: "chilk_timer", arguments: ["seconds": 86400, "title": "Сутки"])
        }
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
