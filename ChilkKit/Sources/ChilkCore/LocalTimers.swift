import Foundation

/// Pending and due notices live in Chilk's own data; delivery does not consume a notice until acknowledged.
public struct LocalTimers: Codable, Equatable, Sendable {
    public enum TimerError: Error, Equatable, CustomStringConvertible {
        case invalidDeadline, invalidTitle, duplicateID, capacity, invalidSnapshot
        public var description: String {
            switch self {
            case .invalidDeadline: "Deadline must be within the next 366 days"
            case .invalidTitle: "Title must be a nonempty single line of at most 80 characters"
            case .duplicateID: "Timer id already exists"
            case .capacity: "At most 32 timers can be pending"
            case .invalidSnapshot: "Invalid timer snapshot"
            }
        }
    }
    public static let maximumDelay: TimeInterval = 366 * 24 * 60 * 60
    public struct Entry: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let message: String
        public let deadline: Date
        public fileprivate(set) var due = false
    }

    public private(set) var entries: [Entry] = []
    public init() {}

    private enum CodingKeys: String, CodingKey { case version, entries }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version == 1 else { throw TimerError.invalidSnapshot }
        let stored = try container.decode([Entry].self, forKey: .entries)
        guard stored.count <= 32 else { throw TimerError.capacity }
        var ids = Set<String>()
        for entry in stored {
            guard Self.validTitle(entry.title) else { throw TimerError.invalidTitle }
            guard !entry.id.isEmpty, entry.id.count <= 128,
                  !entry.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entry.message.count <= 240,
                  entry.deadline.timeIntervalSinceReferenceDate.isFinite else { throw TimerError.invalidSnapshot }
            guard ids.insert(entry.id).inserted else { throw TimerError.duplicateID }
        }
        entries = stored
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        try container.encode(entries, forKey: .entries)
    }

    private static func validTitle(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 80
        && !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    public var ready: [Entry] { entries.filter(\.due).sorted { $0.deadline < $1.deadline } }

    @discardableResult
    public mutating func schedule(id: String = UUID().uuidString, title: String, message: String,
                                  at deadline: Date, now: Date) throws -> Entry {
        let delay = deadline.timeIntervalSince(now)
        guard delay.isFinite, delay > 0, delay <= Self.maximumDelay else { throw TimerError.invalidDeadline }
        guard Self.validTitle(title) else {
            throw TimerError.invalidTitle
        }
        guard !entries.contains(where: { $0.id == id }) else { throw TimerError.duplicateID }
        guard entries.count < 32 else { throw TimerError.capacity }
        let entry = Entry(id: id, title: title, message: message, deadline: deadline)
        entries.append(entry)
        return entry
    }

    @discardableResult
    public mutating func acknowledge(id: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.due }) else { return false }
        entries.remove(at: index)
        return true
    }

    @discardableResult
    public mutating func cancel(id: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries.remove(at: index)
        return true
    }

    /// Only newly due notices are returned; already-due entries remain available in `ready` across restarts.
    public mutating func collectDue(at now: Date) -> [Entry] {
        var new: [Entry] = []
        for index in entries.indices where !entries[index].due && entries[index].deadline <= now {
            entries[index].due = true
            new.append(entries[index])
        }
        return new.sorted { $0.deadline < $1.deadline }
    }
}
