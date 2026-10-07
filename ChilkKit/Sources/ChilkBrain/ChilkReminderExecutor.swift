import Foundation

public struct ReminderInfo: Sendable, Equatable {
    public let title: String
    public let due: Date?
    /// EventKit's `calendarItemIdentifier` (slice 8c: the model changes a reminder by it); nil from older stores.
    public let id: String?
    public init(title: String, due: Date?, id: String? = nil) {
        self.title = title
        self.due = due
        self.id = id
    }
}

public enum ReminderAccessError: Error { case denied, unavailable, notFound }

/// Apple Reminders, Chilk's own «Чилк» list only (decision 2026-10-05). The app supplies EventKit; access is asked
/// on the first request, never at launch.
public protocol ReminderStore: Sendable {
    func add(title: String, due: Date) async throws -> ReminderInfo
    func open() async throws -> [ReminderInfo]
    /// Slice 8c (decision 7): only a reminder of the «Чилк» list, only after the card's «Да».
    func update(id: String, title: String?, due: Date?) async throws -> ReminderInfo
    func complete(id: String) async throws
    func delete(id: String) async throws
}

/// Reading here; writing (create, change, complete, delete) only from a confirmed card (slice 8c, decisions 3–7):
/// `chilk_reminder` and `chilk_reminder_change` are proposals the app turns into cards.
public struct ChilkReminderExecutor: Sendable {
    public static let listTitle = "Чилк"
    private let store: any ReminderStore
    private let now: @Sendable () -> Date

    public init(store: any ReminderStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    public static func handles(_ name: String) -> Bool { ["chilk_reminders"].contains(name) }

    /// Tools whose call is a proposal for a confirmation card (slice 8c), not a deed.
    public static func proposes(_ name: String) -> Bool { ["chilk_reminder", "chilk_reminder_change"].contains(name) }

    /// One of the «Чилк» list's open reminders (for a change card: what it is now).
    public func lookup(id: String) async throws -> ReminderInfo {
        guard let found = try await store.open().first(where: { $0.id == id }) else { throw ReminderAccessError.notFound }
        return found
    }

    // MARK: After «Да» — the card's values, not the model's

    public func create(title: String, due: Date) async -> CodexToolResult {
        await run { .ok(Self.describe(try await store.add(title: title, due: due))) }
    }

    public func change(id: String, title: String?, due: Date?) async -> CodexToolResult {
        await run { .ok(Self.describe(try await store.update(id: id, title: title, due: due))) }
    }

    public func complete(id: String) async -> CodexToolResult { await run { try await store.complete(id: id); return .ok(["done": true]) } }

    public func delete(id: String) async -> CodexToolResult { await run { try await store.delete(id: id); return .ok(["deleted": true]) } }

    private func run(_ body: () async throws -> CodexToolResult) async -> CodexToolResult {
        do { return try await body() }
        catch ReminderAccessError.denied {
            return .failure("no_access: no access to Reminders. The user can allow it in System Settings → Privacy & Security → Reminders → Чилк")
        } catch ReminderAccessError.notFound {
            return .failure("not_found: no such reminder in the «Чилк» list")
        } catch {
            return .failure("reminders_unreachable: could not reach Apple Reminders; nothing was changed")
        }
    }

    public func execute(name: String, arguments: JSON) async -> CodexToolResult {
        do {
            try Task.checkCancellation()
            switch try ChilkToolCatalog.parse(name: name, arguments: arguments) {
            case .reminders:
                let open = try await store.open().sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
                return .ok(["list": .string(Self.listTitle), "reminders": .array(open.prefix(50).map(Self.describe)),
                            "hasMore": .bool(open.count > 50)])
            default: return .failure("Unsupported reminders action")
            }
        } catch ReminderAccessError.denied {
            return .failure("no_access: no access to Reminders. The user can allow it in System Settings → Privacy & Security → Reminders → Чилк")
        } catch is CancellationError {
            return .failure("cancelled")
        } catch is ChilkToolCatalog.ToolError {
            return .failure(ChilkToolCatalog.explain(name: name, arguments: arguments))
        } catch {
            return .failure("reminders_unreachable: could not reach Apple Reminders; nothing was created")
        }
    }

    public static func describe(_ info: ReminderInfo) -> JSON {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        var fields: [String: JSON] = ["title": .string(info.title), "list": .string(listTitle)]
        if let id = info.id { fields["id"] = .string(id) }
        if let due = info.due { fields["at"] = .string(f.string(from: due)) }
        return .object(fields)
    }
}