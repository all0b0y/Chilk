import ChilkCore
import Foundation
import Testing

/// Slice 8a: `tools.log` and «я упал».
struct ToolJournalTests {
    @Test func aLineHasTheToolTheOutcomeAndTheTimeButNoContent() {
        let d = Date(timeIntervalSince1970: 1_791_000_000)
        let line = ToolJournal.line(at: d, tool: "chilk_reminders", outcome: .ok, seconds: 0.123)
        #expect(line.hasSuffix(" chilk_reminders ok 0.1 s"))
        #expect(line.range(of: "T[0-9:]{8}([+-][0-9]{2}:[0-9]{2}|Z) ", options: .regularExpression) != nil)
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

    @Test func aReportForThatPidAfterItsLaunchMeansACrash() {
        let crash = launch.addingTimeInterval(600)
        let t = CrashNotice.crashTime(left: [.init(launchedAt: launch, pid: 42)],
                                      reports: [.init(name: "Chilk-2026-10-07-120407.ips", created: crash, pid: 42),
                                                .init(name: "Chilk-old.ips", created: launch.addingTimeInterval(-99), pid: 42),
                                                .init(name: "Safari-2026.ips", created: crash.addingTimeInterval(5), pid: 42)],
                                      now: crash.addingTimeInterval(30))
        #expect(t == crash)
    }

    @Test func noMarkerNoReportAnOlderOneOrAnotherCopysCrashSaysNothing() {
        let crash = launch.addingTimeInterval(600)
        let mine = CrashNotice.Marker(launchedAt: launch, pid: 42)
        #expect(CrashNotice.crashTime(left: [], reports: [.init(name: "Chilk-x.ips", created: crash, pid: 42)], now: crash) == nil)
        #expect(CrashNotice.crashTime(left: [mine], reports: [], now: crash) == nil)                     // force quit
        #expect(CrashNotice.crashTime(left: [mine], reports: [.init(name: "Chilk-x.ips", created: launch.addingTimeInterval(-5), pid: 42)],
                                      now: crash) == nil)
        #expect(CrashNotice.crashTime(left: [mine], reports: [.init(name: "Chilk-x.ips", created: crash, pid: 77)],
                                      now: crash) == nil)                                               // a Debug copy crashed
    }

    @Test func thePidIsReadFromTheReportBody() {
        #expect(CrashNotice.pid(inReportHead: #"{"app_name":"Chilk"}\n{\n  "uptime" : 1,\n  "pid" : 35617,\n"#) == 35617)
        #expect(CrashNotice.pid(inReportHead: "{}") == nil)
    }

    @Test func todayYesterdayOrNothing() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 9, minute: 30))!
        let today = cal.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 3, minute: 5))!
        let yesterday = cal.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 23, minute: 10))!
        #expect(CrashNotice.when(today, now: now, calendar: cal) == .today("03:05"))
        #expect(CrashNotice.when(yesterday, now: now, calendar: cal) == .yesterday("23:10"))
        #expect(CrashNotice.when(yesterday.addingTimeInterval(-86_400), now: now, calendar: cal) == nil)
    }
}
