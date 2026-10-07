import Foundation

// MARK: - Slice 8a (SPEC «Срез 8», decisions 14–15): what the tools did, and «я упал»

/// `tools.log`: one line per tool call — time, tool, outcome code, seconds. Never names, times of reminders, paths or
/// any text the user or the model wrote. ~1 MB at most; one previous file is kept as `tools.1.log`.
public struct ToolJournal: Sendable {
    public enum Outcome: Equatable, Sendable {
        case ok
        case refused(String)
        case failed(String)
    }

    public static let limit = 1_000_000
    public let url: URL

    public init(url: URL) { self.url = url }

    /// A failure's code: the leading `snake_case` word of its message («invalid_arguments: at — …» →
    /// `invalid_arguments`), else `error` — free text never reaches the journal.
    public static func code(of message: String) -> String {
        let head = message.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        let ok = !head.isEmpty && head.count <= 40 && head.allSatisfy { $0.isASCII && ($0.isLowercase || $0 == "_") }
        return ok ? head : "error"
    }

    public static func line(at date: Date, tool: String, outcome: Outcome, seconds: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        f.timeZone = .current
        let safeTool = tool.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } && tool.count <= 40 ? tool : "unknown"
        let what: String = switch outcome {
        case .ok: "ok"
        case .refused(let c): "refused \(c)"
        case .failed(let c): "failed \(c)"
        }
        return "\(f.string(from: date)) \(safeTool) \(what) \(String(format: "%.1f", seconds)) s"
    }

    public func write(_ line: String) {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.limit {
            let old = url.deletingLastPathComponent().appendingPathComponent("tools.1.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }
}

/// «Я упал в ЧЧ:ММ — уже снова тут» (decision 15): only when the last run left its marker (it did not quit normally)
/// AND macOS wrote a crash report for Chilk after that launch. A force quit, `pkill` or a power cut leaves no report:
/// he says nothing then.
public enum CrashNotice {
    /// The marker file's content: the launch time.
    public struct Marker: Codable, Equatable, Sendable {
        public let launchedAt: Date
        public init(launchedAt: Date) { self.launchedAt = launchedAt }
    }

    /// `reports`: names and creation dates of the files in the crash-report folders. `nil` = say nothing.
    public static func crashTime(previous: Marker?, reports: [(name: String, created: Date)], now: Date) -> Date? {
        guard let previous else { return nil }
        return reports
            .filter { $0.name.hasPrefix("Chilk-") && $0.name.hasSuffix(".ips") }
            .map(\.created)
            .filter { $0 >= previous.launchedAt && $0 <= now }
            .max()
    }
}
