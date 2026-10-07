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
        let f = ISO8601DateFormatter()                       // with the offset: unambiguous across a DST change
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        let safeTool = tool.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } && tool.count <= 40 ? tool : "unknown"
        let what: String = switch outcome {
        case .ok: "ok"
        case .refused(let c): "refused \(c)"
        case .failed(let c): "failed \(c)"
        }
        return "\(f.string(from: date)) \(safeTool) \(what) \(String(format: "%.1f", seconds)) s"
    }

    /// Appends with `O_APPEND` (two running copies do not overwrite each other's lines) and never throws: a full disk
    /// or a removed folder loses a journal line, not the app (`FileHandle.write(_:)` raises an ObjC exception).
    public func write(_ line: String) {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.limit {
            let old = url.deletingPathExtension().appendingPathExtension("1").appendingPathExtension(url.pathExtension)
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
}

/// «Я упал в ЧЧ:ММ — уже снова тут» (decision 15). Every run leaves a marker (its pid and launch time) and removes it
/// on a normal quit. A marker left by a run that is gone, plus a macOS crash report for that very pid written after
/// its launch = a crash. A force quit, `pkill` or a power cut leaves no report: he says nothing then. Another copy's
/// crash (a Debug build, an acceptance run) has another pid and is not his.
public enum CrashNotice {
    public struct Marker: Codable, Equatable, Sendable {
        public let launchedAt: Date
        public let pid: Int32
        public init(launchedAt: Date, pid: Int32) {
            self.launchedAt = launchedAt
            self.pid = pid
        }
    }

    public struct Report: Equatable, Sendable {
        public let name: String
        public let created: Date
        public let pid: Int32?
        public init(name: String, created: Date, pid: Int32?) {
            self.name = name
            self.created = created
            self.pid = pid
        }
    }

    /// The latest crash among the left markers, `nil` = say nothing.
    public static func crashTime(left: [Marker], reports: [Report], now: Date) -> Date? {
        left.compactMap { marker in
            reports.filter { $0.name.hasPrefix("Chilk-") && $0.name.hasSuffix(".ips") && $0.pid == marker.pid
                             && $0.created >= marker.launchedAt && $0.created <= now }
                .map(\.created).max()
        }.max()
    }

    /// The pid in a crash report's body (`"pid" : 35617`, within the first few KB).
    public static func pid(inReportHead text: String) -> Int32? {
        guard let r = text.range(of: #""pid"\s*:\s*([0-9]+)"#, options: .regularExpression) else { return nil }
        return Int32(text[r].split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "")
    }

    /// «в 14:05» today, «вчера в 23:10» — older crashes are not news.
    public enum When: Equatable, Sendable { case today(String), yesterday(String) }

    public static func when(_ crash: Date, now: Date, calendar: Calendar = .current) -> When? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "HH:mm"
        if calendar.isDate(crash, inSameDayAs: now) { return .today(f.string(from: crash)) }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(crash, inSameDayAs: y) {
            return .yesterday(f.string(from: crash))
        }
        return nil
    }
}
