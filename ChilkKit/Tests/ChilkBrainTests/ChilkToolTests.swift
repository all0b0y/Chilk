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
