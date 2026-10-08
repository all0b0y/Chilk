import Foundation

/// Slice 8e: one event of Chilk's own «Чилк» calendar. `end` is exclusive (EventKit ends an all-day event at 23:59:59 of
/// its last day); `recurring`: a repeating event someone made there by hand — Chilk neither changes nor deletes it.
public struct EventInfo: Sendable, Equatable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public let recurring: Bool

    public init(id: String, title: String, start: Date, end: Date, allDay: Bool, recurring: Bool) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.recurring = recurring
    }
}

public enum CalendarAccessError: Error { case denied, unavailable, notFound, recurring }

/// Apple Calendar, Chilk's own «Чилк» calendar only (SPEC «Срез 8», decision 11): the app supplies EventKit with full
/// access and keeps itself to that calendar. Access is asked on first use, never at launch.
public protocol CalendarStore: Sendable {
    /// Creates the «Чилк» calendar on first use.
    func add(title: String, start: Date, end: Date, allDay: Bool) async throws -> EventInfo
    /// The calendar's events overlapping `from` … `to`; an absent calendar reads as empty (reading never creates it).
    func events(from: Date, to: Date) async throws -> [EventInfo]
    /// One event of the «Чилк» calendar (`notFound` for any other calendar's event).
    func event(id: String) async throws -> EventInfo
    /// Only an event of the «Чилк» calendar, only after the card's «Да»; nil keeps a value. A repeating one: `recurring`.
    func update(id: String, title: String?, start: Date?, end: Date?) async throws -> EventInfo
    func delete(id: String) async throws
}

/// Reading here; writing (create, move, rename, delete) only from a confirmed card (decisions 3–7): `chilk_event` and
/// `chilk_event_change` are proposals the app turns into cards.
public struct ChilkCalendarExecutor: Sendable {
    public static let calendarTitle = "Чилк"
    private let store: any CalendarStore

    public init(store: any CalendarStore) {
        self.store = store
    }

    public static func handles(_ name: String) -> Bool { name == "chilk_events" }

    /// Tools whose call is a proposal for a confirmation card, not a deed.
    public static func proposes(_ name: String) -> Bool { ["chilk_event", "chilk_event_change"].contains(name) }

    /// One event of the «Чилк» calendar (for a change card: what it is now).
    public func lookup(id: String) async throws -> EventInfo { try await store.event(id: id) }

    // MARK: After «Да» — the card's values, not the model's

    public func create(title: String, start: Date, end: Date, allDay: Bool) async -> CodexToolResult {
        await run(nothing: "created") { .ok(Self.describe(try await store.add(title: title, start: start, end: end, allDay: allDay))) }
    }

    public func change(id: String, title: String?, start: Date?, end: Date?) async -> CodexToolResult {
        await run(nothing: "changed") { .ok(Self.describe(try await store.update(id: id, title: title, start: start, end: end))) }
    }

    public func delete(id: String) async -> CodexToolResult {
        await run(nothing: "changed") { try await store.delete(id: id); return .ok(["deleted": true]) }
    }

    public func execute(name: String, arguments: JSON) async -> CodexToolResult {
        guard case .events(let from, let to)? = try? ChilkToolCatalog.parse(name: name, arguments: arguments) else {
            return .failure(ChilkToolCatalog.explain(name: name, arguments: arguments))
        }
        return await run(nothing: "read") {
            try Task.checkCancellation()
            let found = try await store.events(from: from, to: to).sorted { ($0.start, $0.title) < ($1.start, $1.title) }
            return .ok(["calendar": .string(Self.calendarTitle), "events": .array(found.prefix(50).map(Self.describe)),
                        "hasMore": .bool(found.count > 50)])
        }
    }

    /// The error a tool result carries; `nothing`: what did not happen («nothing was created»).
    public static func failure(_ error: any Error, nothing: String = "changed") -> String {
        switch error {
        case CalendarAccessError.denied:
            "no_access: no access to Calendar. The user can allow it in System Settings → Privacy & Security → Calendars → Чилк"
        case CalendarAccessError.notFound: "not_found: no such event in the «Чилк» calendar; list them with chilk_events"
        case CalendarAccessError.recurring:
            "recurring_event: a repeating event — Chilk changes only single events; the user can change it in Calendar"
        case CalendarAccessError.unavailable: "calendar_unavailable: could not make the «Чилк» calendar; nothing was \(nothing)"
        case is CancellationError: "cancelled"
        default: "calendar_unreachable: could not reach Apple Calendar; nothing was \(nothing)"
        }
    }

    private func run(nothing: String, _ body: () async throws -> CodexToolResult) async -> CodexToolResult {
        do { return try await body() } catch { return .failure(Self.failure(error, nothing: nothing)) }
    }

    public static func describe(_ info: EventInfo) -> JSON {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return .object(["id": .string(info.id), "title": .string(info.title), "calendar": .string(calendarTitle),
                        "start": .string(f.string(from: info.start)), "end": .string(f.string(from: info.end)),
                        "allDay": .bool(info.allDay), "recurring": .bool(info.recurring)])
    }
}
