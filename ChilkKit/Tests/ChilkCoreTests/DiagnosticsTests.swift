import ChilkCore
import Foundation
import Testing

/// Slice 8a: `tools.log` and «я упал».
struct ToolJournalTests {
    @Test func aLineHasTheToolTheOutcomeAndTheTimeButNoContent() {
        let d = Date(timeIntervalSince1970: 1_791_000_000)
        let line = ToolJournal.line(at: d, tool: "chilk_reminders", outcome: .ok, seconds: 0.123)
        #expect(line.hasSuffix(" chilk_reminders ok 0.1 s"))
        let failed = ToolJournal.line(at: d, tool: "chilk_reminder", outcome: .failed("invalid_arguments"), seconds: 0)
        #expect(failed.hasSuffix(" chilk_reminder failed invalid_arguments 0.0 s"))
        #expect(ToolJournal.line(at: d, tool: "rm -rf «Купить хлеб»", outcome: .ok, seconds: 0).contains(" unknown ok "))
    }

    @Test func onlyACodeOfAFailureIsKept() {
        #expect(ToolJournal.code(of: "invalid_arguments: title — must not be empty") == "invalid_arguments")
        #expect(ToolJournal.code(of: "ambiguous_time: «в 3» — ночи или дня?") == "ambiguous_time")
        #expect(ToolJournal.code(of: "No access to Reminders. The user can allow it…") == "error")
        #expect(ToolJournal.code(of: "Купить хлеб: завтра") == "error")
    }

    @Test func theFileRotatesAtTheLimit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tooljournal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let j = ToolJournal(url: dir.appendingPathComponent("tools.log"))
        let line = String(repeating: "x", count: 1000)
        for _ in 0..<(ToolJournal.limit / 1000 + 5) { j.write(line) }
        let size = try FileManager.default.attributesOfItem(atPath: j.url.path)[.size] as? Int ?? 0
        #expect(size < 20_000)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("tools.1.log").path))
    }
}

struct CrashNoticeTests {
    let launch = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func aReportAfterTheMarkedLaunchMeansACrash() {
        let crash = launch.addingTimeInterval(600)
        let t = CrashNotice.crashTime(previous: .init(launchedAt: launch),
                                      reports: [("Chilk-2026-10-07-120407.ips", crash), ("Chilk-old.ips", launch.addingTimeInterval(-99)),
                                                ("Safari-2026.ips", crash.addingTimeInterval(5))],
                                      now: crash.addingTimeInterval(30))
        #expect(t == crash)
    }

    @Test func noMarkerOrNoReportSaysNothing() {
        let crash = launch.addingTimeInterval(600)
        #expect(CrashNotice.crashTime(previous: nil, reports: [("Chilk-x.ips", crash)], now: crash) == nil)   // quit normally
        #expect(CrashNotice.crashTime(previous: .init(launchedAt: launch), reports: [], now: crash) == nil)   // force quit
        #expect(CrashNotice.crashTime(previous: .init(launchedAt: launch),
                                      reports: [("Chilk-x.ips", launch.addingTimeInterval(-5))], now: crash) == nil)  // older one
    }
}
