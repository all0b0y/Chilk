import ChilkCore
import Foundation

public struct ReminderInfo: Sendable, Equatable {
    public let title: String
    public let due: Date?
    /// EventKit's `calendarItemIdentifier` (slice 8c: the model changes a reminder by it); nil from older stores.
    public let id: String?
    /// Slice 9b (decision 9): the due date has a time of day and an alarm; false — a date only (a plan item «без
    /// времени»: no alarm, it waits in «Сегодня»).
    public let timed: Bool
    /// Slice 9b: ticked off (the plan sheet reads a day's done items too).
    public let done: Bool
    public init(title: String, due: Date?, id: String? = nil, timed: Bool = true, done: Bool = false) {
        self.title = title
        self.due = due
        self.id = id
        self.timed = timed && due != nil
        self.done = done
    }
}

public enum ReminderAccessError: Error { case denied, unavailable, notFound }

/// Apple Reminders, Chilk's own «Чилк» list only (decision 2026-10-05). The app supplies EventKit; access is asked
/// on the first request, never at launch.
public protocol ReminderStore: Sendable {
    /// `timed: false` (slice 9b, decision 9): the date only — no alarm.
    func add(title: String, due: Date, timed: Bool) async throws -> ReminderInfo
    func open() async throws -> [ReminderInfo]
    /// Slice 8c (decision 7): only a reminder of the «Чилк» list, only after the card's «Да» (slice 9b: or a direct
    /// action on Chilk's plan sheet). `due` nil keeps the date as it is; `timed` matters only with a `due`.
    func update(id: String, title: String?, due: Date?, timed: Bool) async throws -> ReminderInfo
    /// Slice 9b (decision 14): ticked or unticked; completing is `setDone(id:done: true)`.
    func setDone(id: String, done: Bool) async throws
    func delete(id: String) async throws
    /// Slice 9b: every reminder of the «Чилк» list due on `day` — open and done, with a time or on the date only.
    func day(_ day: Date) async throws -> [ReminderInfo]
}

public extension ReminderStore {
    func add(title: String, due: Date) async throws -> ReminderInfo { try await add(title: title, due: due, timed: true) }
    func update(id: String, title: String?, due: Date?) async throws -> ReminderInfo {
        try await update(id: id, title: title, due: due, timed: true)
    }
    func complete(id: String) async throws { try await setDone(id: id, done: true) }
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

    /// Slice 9b: one item of a confirmed plan (or one added on the plan sheet) — with a time, or on the date only.
    public func create(title: String, due: Date, timed: Bool) async -> CodexToolResult {
        await run { .ok(Self.describe(try await store.add(title: title, due: due, timed: timed))) }
    }

    /// Slice 9b: a direct edit on the plan sheet — the title, and the time (`due` with `timed`) or the date only.
    public func edit(id: String, title: String?, due: Date?, timed: Bool) async -> CodexToolResult {
        await run { .ok(Self.describe(try await store.update(id: id, title: title, due: due, timed: timed))) }
    }

    /// Slice 9b: a tick on the plan sheet (and its undo).
    public func setDone(id: String, done: Bool) async -> CodexToolResult {
        await run { try await store.setDone(id: id, done: done); return .ok(["done": .bool(done)]) }
    }

    /// Slice 9b: the day's plan as it is in the «Чилк» list (throws on no access).
    public func day(_ day: Date) async throws -> [ReminderInfo] { try await store.day(day) }

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
        // Slice 9b: a plan item without a time has a day, not a midnight time.
        if let due = info.due {
            if info.timed { fields["at"] = .string(f.string(from: due)) }
            else { fields["day"] = .string(PlanDay.iso(due, calendar: .current)) }
        }
        if info.done { fields["done"] = .bool(true) }
        return .object(fields)
    }
}