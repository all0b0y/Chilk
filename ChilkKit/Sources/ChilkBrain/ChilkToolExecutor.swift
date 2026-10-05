import Foundation
import ChilkCore

/// Owns the bounded persistent notice queue. AppKit only supplies aggregate reads and the water credit callback.
@MainActor
public final class ChilkToolExecutor {
    private var store: LocalTimerStore
    private let now: @Sendable () -> Date
    private let status: () -> JSON
    private let water: () throws -> JSON
    public var entries: [LocalTimers.Entry] { store.timers.entries }
    public var ready: [LocalTimers.Entry] { store.timers.ready }

    public init(file: URL, now: @escaping @Sendable () -> Date = { Date() },
                status: @escaping () -> JSON = { [:] },
                water: @escaping () throws -> JSON = { ["credited": false] }) throws {
        store = try LocalTimerStore(file: file)
        self.now = now; self.status = status; self.water = water
    }

    public func execute(name: String, arguments: JSON) -> CodexToolResult {
        guard !Task.isCancelled else { return .failure("Cancelled") }
        do {
            let action = try ChilkToolCatalog.parse(name: name, arguments: arguments)
            switch action {
            case .findFiles, .readFile, .appendNote: return .failure("File access is handled by the selected-folder tools")
            case .status: return .ok(status())
            case .water: return .ok(try water())
            case .timers: return .ok(["timers": .array(entries.map(Self.describe))])
            case .cancel(let id): return .ok(["cancelled": .bool(try store.cancel(id: id))])
            case .timer(let seconds, let title):
                let start = now()
                let entry = try store.schedule(title: title, message: title,
                                               at: start.addingTimeInterval(Double(seconds)), now: start)
                return .ok(Self.describe(entry))
            case .schedule(let at, let title, let message):
                let entry = try store.schedule(title: title, message: message, at: at, now: now())
                return .ok(Self.describe(entry))
            }
        } catch {
            // No paths or argument text are copied into an error response.
            if let reason = error as? LocalTimers.TimerError { return .failure(reason.description) }
            if error is ChilkToolCatalog.ToolError { return .failure("Unknown tool or invalid arguments") }
            return .failure("Could not persist Chilk state; the operation was not completed")
        }
    }

    public func collectDue(at now: Date = Date()) throws -> [LocalTimers.Entry] { try store.collectDue(at: now) }
    public func acknowledge(id: String) throws -> Bool { try store.acknowledge(id: id) }

    /// Facts only. A prose «delivery» note here got paraphrased into odd replies («покажет, когда приложение сможет»).
    private static func describe(_ entry: LocalTimers.Entry) -> JSON {
        ["id": .string(entry.id), "title": .string(entry.title),
         "at": .string(ISO8601DateFormatter().string(from: entry.deadline)), "due": .bool(entry.due)]
    }
}
