import Foundation

public struct ReminderInfo: Sendable, Equatable {
    public let title: String
    public let due: Date?
    public init(title: String, due: Date?) {
        self.title = title
        self.due = due
    }
}

public enum ReminderAccessError: Error { case denied, unavailable }

/// Apple Reminders, Chilk's own «Чилк» list only (decision 2026-10-05). The app supplies EventKit; access is asked
/// on the first request, never at launch.
public protocol ReminderStore: Sendable {
    func add(title: String, due: Date) async throws -> ReminderInfo
    func open() async throws -> [ReminderInfo]
}

/// Create and read only: editing, completing or deleting a reminder would be a dangerous action, which needs the
/// «Да/Нет» confirmation that does not exist yet (SPEC, decision 2026-10-05).
public struct ChilkReminderExecutor: Sendable {
    public static let listTitle = "Чилк"
    private let store: any ReminderStore
    private let now: @Sendable () -> Date

    public init(store: any ReminderStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    public static func handles(_ name: String) -> Bool { ["chilk_reminder", "chilk_reminders"].contains(name) }

    public func execute(name: String, arguments: JSON) async -> CodexToolResult {
        do {
            try Task.checkCancellation()
            switch try ChilkToolCatalog.parse(name: name, arguments: arguments) {
            case .reminder(let title, let at):
                guard at > now().addingTimeInterval(30) else {
                    return .failure("That time has already passed: ask the user for a future time")
                }
                return .ok(Self.describe(try await store.add(title: title, due: at)))
            case .reminders:
                let open = try await store.open().sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
                return .ok(["list": .string(Self.listTitle), "reminders": .array(open.prefix(50).map(Self.describe)),
                            "hasMore": .bool(open.count > 50)])
            default: return .failure("Unsupported reminders action")
            }
        } catch ReminderAccessError.denied {
            return .failure("No access to Reminders. The user can allow it in System Settings → Privacy & Security → Reminders → Чилк")
        } catch is CancellationError {
            return .failure("Cancelled")
        } catch is ChilkToolCatalog.ToolError {
            return .failure("Unknown tool or invalid arguments")
        } catch {
            return .failure("Could not reach Apple Reminders; nothing was created")
        }
    }

    private static func describe(_ info: ReminderInfo) -> JSON {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        var fields: [String: JSON] = ["title": .string(info.title), "list": .string(listTitle)]
        if let due = info.due { fields["at"] = .string(f.string(from: due)) }
        return .object(fields)
    }
}