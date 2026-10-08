import Foundation

/// Slice 8f: one note of Chilk's own «Чилк» folder in Apple Notes. `text`: what is under the title (in a list — its
/// beginning); `locked`: closed with a password (its text cannot be read, Chilk does not change it); `attachments`:
/// pictures or files — a rewrite would lose them.
public struct NoteInfo: Sendable, Equatable {
    public let id: String
    public let title: String
    public let text: String
    public let modified: Date
    public let locked: Bool
    public let attachments: Bool

    public init(id: String, title: String, text: String, modified: Date, locked: Bool = false, attachments: Bool = false) {
        self.id = id
        self.title = title
        self.text = text
        self.modified = modified
        self.locked = locked
        self.attachments = attachments
    }
}

public enum NotesAccessError: Error, Equatable { case denied, unavailable, notFound, locked, attachments }

/// Apple Notes, Chilk's own «Чилк» folder only (SPEC «Срез 8», decision 10). Notes has no framework API: the app drives
/// it with AppleScript, and macOS asks once whether Chilk may control Notes.
public protocol NotesStore: Sendable {
    /// Makes the «Чилк» folder on first use.
    func add(title: String, text: String) async throws -> NoteInfo
    /// The folder's notes with the beginning of their text; an absent folder reads as empty (reading never makes it).
    func notes() async throws -> [NoteInfo]
    /// One note of the folder with its whole text (`notFound` for a note anywhere else).
    func note(id: String) async throws -> NoteInfo
    /// Only a note of the folder, only after the card's «Да».
    func append(id: String, text: String) async throws -> NoteInfo
    func rewrite(id: String, title: String, text: String) async throws -> NoteInfo
    /// Into Notes' «Recently Deleted».
    func delete(id: String) async throws
}

/// Reading here; writing (create, append, rewrite, delete) only from a confirmed card (decisions 3–7): `chilk_note` and
/// `chilk_note_change` are proposals the app turns into cards.
public struct ChilkNotesExecutor: Sendable {
    public static let folderTitle = "Чилк"
    /// What a list shows of each note, and the most of one note's text the model gets.
    public static let previewLimit = 300, textLimit = 4000
    private let store: any NotesStore

    public init(store: any NotesStore) {
        self.store = store
    }

    public static func handles(_ name: String) -> Bool { name == "chilk_notes" }

    /// Tools whose call is a proposal for a confirmation card, not a deed.
    public static func proposes(_ name: String) -> Bool { ["chilk_note", "chilk_note_change"].contains(name) }

    /// One note of the «Чилк» folder with its whole text (for a change card: what it is now).
    public func lookup(id: String) async throws -> NoteInfo { try await store.note(id: id) }

    // MARK: After «Да» — the card's values, not the model's

    public func create(title: String, text: String) async -> CodexToolResult {
        await run(nothing: "created") { .ok(Self.describe(try await store.add(title: title, text: text), limit: Self.previewLimit)) }
    }

    public func append(id: String, text: String) async -> CodexToolResult {
        await run(nothing: "changed") { .ok(Self.describe(try await store.append(id: id, text: text), limit: Self.previewLimit)) }
    }

    public func rewrite(id: String, title: String, text: String) async -> CodexToolResult {
        await run(nothing: "changed") {
            .ok(Self.describe(try await store.rewrite(id: id, title: title, text: text), limit: Self.previewLimit))
        }
    }

    public func delete(id: String) async -> CodexToolResult {
        await run(nothing: "changed") { try await store.delete(id: id); return .ok(["deleted": true]) }
    }

    public func execute(name: String, arguments: JSON) async -> CodexToolResult {
        guard case .notes(let id)? = try? ChilkToolCatalog.parse(name: name, arguments: arguments) else {
            return .failure(ChilkToolCatalog.explain(name: name, arguments: arguments))
        }
        return await run(nothing: "read") {
            try Task.checkCancellation()
            if !id.isEmpty { return .ok(Self.describe(try await store.note(id: id), limit: Self.textLimit)) }
            let found = try await store.notes().sorted { ($0.modified, $0.title) > ($1.modified, $1.title) }
            return .ok(["folder": .string(Self.folderTitle),
                        "notes": .array(found.prefix(50).map { Self.describe($0, limit: Self.previewLimit) }),
                        "hasMore": .bool(found.count > 50)])
        }
    }

    /// The error a tool result carries; `nothing`: what did not happen («nothing was created»).
    public static func failure(_ error: any Error, nothing: String = "changed") -> String {
        switch error {
        case NotesAccessError.denied:
            "no_access: Chilk may not control Notes. The user can allow it in System Settings → Privacy & Security → Automation → Чилк → Notes"
        case NotesAccessError.notFound: "not_found: no such note in the «Чилк» folder; list them with chilk_notes"
        case NotesAccessError.locked: "note_locked: the note is locked with a password — Chilk neither reads nor changes it; the user can in Notes"
        case NotesAccessError.attachments:
            "note_has_attachments: the note has pictures or files — a rewrite would lose them; append still works, or the user edits it in Notes"
        case NotesAccessError.unavailable: "notes_unavailable: could not make the «Чилк» folder; nothing was \(nothing)"
        case is CancellationError: "cancelled"
        default: "notes_unreachable: could not reach Apple Notes; nothing was \(nothing)"
        }
    }

    private func run(nothing: String, _ body: () async throws -> CodexToolResult) async -> CodexToolResult {
        do { return try await body() } catch { return .failure(Self.failure(error, nothing: nothing)) }
    }

    /// `limit`: how much of the text the model gets (`truncated` when cut). A locked note has no text to give.
    public static func describe(_ info: NoteInfo, limit: Int) -> JSON {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        var out: [String: JSON] = ["id": .string(info.id), "title": .string(info.title), "folder": .string(folderTitle),
                                   "modified": .string(f.string(from: info.modified)), "locked": .bool(info.locked),
                                   "attachments": .bool(info.attachments)]
        if !info.locked {
            out["text"] = .string(String(info.text.prefix(limit)))
            out["truncated"] = .bool(info.text.count > limit)
        }
        return .object(out)
    }
}
