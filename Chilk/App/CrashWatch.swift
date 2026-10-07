import ChilkCore
import Foundation

/// Slice 8a (decision 15): the marker `running.json` in the state folder says «this run has not quit normally yet».
/// At launch an old marker plus a newer `Chilk-*.ips` crash report means the last run crashed.
@MainActor
enum CrashWatch {
    private static var marker: URL { AppState.directory.appendingPathComponent("running.json") }

    /// Reads the previous run's marker, writes this run's; the crash time if the last run crashed.
    static func launch(now: Date = Date()) -> Date? {
        let previous = (try? Data(contentsOf: marker)).flatMap { data -> CrashNotice.Marker? in
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return try? d.decode(CrashNotice.Marker.self, from: data)
        }
        let crashed = CrashNotice.crashTime(previous: previous, reports: reports(), now: now)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? e.encode(CrashNotice.Marker(launchedAt: now)).write(to: marker, options: .atomic)
        return crashed
    }

    static func quitNormally() { try? FileManager.default.removeItem(at: marker) }

    /// Chilk's crash reports (names and creation dates only) in the user's DiagnosticReports and its Retired folder.
    private static func reports() -> [(name: String, created: Date)] {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        return [base, base.appendingPathComponent("Retired")].flatMap { dir -> [(name: String, created: Date)] in
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
            return files.compactMap { url in
                guard url.lastPathComponent.hasPrefix("Chilk-"),
                      let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { return nil }
                return (url.lastPathComponent, created)
            }
        }
    }
}
