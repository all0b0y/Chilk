import Foundation
import Testing
@testable import ChilkCore

@Suite("Persistent local timers")
struct LocalTimerStoreTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func directory() throws -> URL {
        let root = ProcessInfo.processInfo.environment["CHILK_TEST_TMP"] ?? ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let dir = URL(fileURLWithPath: root).appendingPathComponent("chilk-timers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func cancellingBeforeTheDeadlineIsPersisted() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("timers.json")
        var store = try LocalTimerStore(file: file)
        try store.schedule(id: "tea", title: "Чай", message: "Пора", at: now.addingTimeInterval(30), now: now)
        #expect(try store.cancel(id: "unknown") == false)
        #expect(try store.cancel(id: "tea"))
        store = try LocalTimerStore(file: file)
        #expect(try store.collectDue(at: now.addingTimeInterval(40)).isEmpty)
        #expect(store.timers.entries.isEmpty)
    }

    @Test func failedWritesLeaveTheQueueUnchanged() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let parent = dir.appendingPathComponent("not-a-directory")
        try Data().write(to: parent)
        var store = try LocalTimerStore(file: parent.appendingPathComponent("timers.json"))
        #expect(throws: (any Error).self) {
            try store.schedule(id: "tea", title: "Чай", message: "Пора", at: now.addingTimeInterval(30), now: now)
        }
        #expect(store.timers.entries.isEmpty)
    }

    @Test func corruptOrInvalidSnapshotsDoNotBecomeAnEmptyQueue() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("timers.json")
        try Data("broken".utf8).write(to: file)
        #expect(throws: (any Error).self) { try LocalTimerStore(file: file) }
        let invalid = """
        {"entries":[{"id":"tea","title":"","message":"Пора","deadline":721692830,"due":false}]}
        """
        try Data(invalid.utf8).write(to: file)
        #expect(throws: (any Error).self) { try LocalTimerStore(file: file) }
    }

    @Test func aDueNoticeSurvivesRestartUntilTheAppAcknowledgesIt() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("timers.json")
        var store = try LocalTimerStore(file: file)
        let created = try store.schedule(id: "tea", title: "Чай", message: "Чай готов", at: now.addingTimeInterval(30), now: now)
        store = try LocalTimerStore(file: file)
        #expect(store.timers.entries == [created])
        #expect(try store.collectDue(at: now.addingTimeInterval(31)).map(\.id) == ["tea"])
        store = try LocalTimerStore(file: file)
        #expect(store.timers.ready.map(\.id) == ["tea"])
        #expect(try store.collectDue(at: now.addingTimeInterval(32)).isEmpty)
        #expect(try store.acknowledge(id: "tea"))
        store = try LocalTimerStore(file: file)
        #expect(store.timers.entries.isEmpty)
    }
}
