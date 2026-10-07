import ChilkCore
import Darwin
import Foundation

/// Slice 8a (decision 15): every run keeps a marker `running/<pid>.json` in the state folder and removes it on a
/// normal quit. At launch the markers of runs that are gone are matched against Chilk's crash reports by pid.
/// macOS may write the report a few seconds after a quick relaunch: then the check runs again 15 s later.
@MainActor
enum CrashWatch {
    private static var folder: URL { AppState.directory.appendingPathComponent("running", isDirectory: true) }
    private static var own: URL { folder.appendingPathComponent("\(getpid()).json") }

    /// Writes this run's marker; the markers left by runs that are no longer alive.
    static func launch(now: Date = Date()) -> [CrashNotice.Marker] {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let left = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).compactMap { url -> CrashNotice.Marker? in
            guard let m = (try? Data(contentsOf: url)).flatMap({ try? decoder.decode(CrashNotice.Marker.self, from: $0) }),
                  m.pid != getpid(), kill(m.pid, 0) != 0 else { return nil }   // another copy still running: not ours
            return m
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(CrashNotice.Marker(launchedAt: now, pid: getpid())).write(to: own, options: .atomic)
        return left
    }

    /// The crash time, if one of `left` crashed; the checked markers are removed when `final`.
    static func check(_ left: [CrashNotice.Marker], now: Date = Date(), final: Bool) -> Date? {
        guard !left.isEmpty else { return nil }
        let crashed = CrashNotice.crashTime(left: left, reports: reports(), now: now)
        if crashed != nil || final {
            for m in left { try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(m.pid).json")) }
        }
        return crashed
    }

    static func quitNormally() { try? FileManager.default.removeItem(at: own) }

    /// Chilk's crash reports in the user's DiagnosticReports and its Retired folder: name, date and the pid from the
    /// first 4 KB (nothing else is read).
    private static func reports() -> [CrashNotice.Report] {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        return [base, base.appendingPathComponent("Retired")].flatMap { dir -> [CrashNotice.Report] in
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
            return files.compactMap { url in
                guard url.lastPathComponent.hasPrefix("Chilk-"), url.pathExtension == "ips",
                      let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { return nil }
                let head = (try? FileHandle(forReadingFrom: url)).flatMap { h -> String? in
                    defer { try? h.close() }
                    return (try? h.read(upToCount: 4096)).flatMap { String(decoding: $0, as: UTF8.self) }
                }
                return CrashNotice.Report(name: url.lastPathComponent, created: created,
                                          pid: head.flatMap(CrashNotice.pid(inReportHead:)))
            }
        }
    }
}
