import Foundation

/// Copy → atomic write → publish. A failed write cannot produce a successful action or alter in-memory state.
public struct LocalTimerStore: Sendable {
    public private(set) var timers: LocalTimers
    private let file: URL

    public init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            timers = try JSONDecoder().decode(LocalTimers.self, from: Data(contentsOf: file))
        } else {
            timers = LocalTimers()
        }
    }

    @discardableResult
    public mutating func schedule(id: String = UUID().uuidString, title: String, message: String,
                                  at deadline: Date, now: Date) throws -> LocalTimers.Entry {
        var updated = timers
        let entry = try updated.schedule(id: id, title: title, message: message, at: deadline, now: now)
        try commit(updated)
        return entry
    }

    public mutating func collectDue(at now: Date) throws -> [LocalTimers.Entry] {
        var updated = timers
        let due = updated.collectDue(at: now)
        if !due.isEmpty { try commit(updated) }
        return due
    }

    @discardableResult
    public mutating func acknowledge(id: String) throws -> Bool {
        var updated = timers
        guard updated.acknowledge(id: id) else { return false }
        try commit(updated)
        return true
    }

    @discardableResult
    public mutating func cancel(id: String) throws -> Bool {
        var updated = timers
        guard updated.cancel(id: id) else { return false }
        try commit(updated)
        return true
    }

    private mutating func commit(_ updated: LocalTimers) throws {
        let data = try JSONEncoder().encode(updated)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        timers = updated
    }
}
