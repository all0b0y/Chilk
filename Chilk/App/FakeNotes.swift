import ChilkBrain
import Foundation

/// Acceptance runs (CHILK_FAKE_NOTES=1 | seed): the real Codex and card path without the user's Notes. Every write lands
/// in `notes-fake.json` in CHILK_STATE_DIR. `seed`: «Покупки» (молоко, хлеб), «Пароли» locked with a password and «Дача»
/// with a photo (the refusals).
actor FakeNotes: NotesStore {
    private var items: [NoteInfo] = []
    private var deleted: [NoteInfo] = []
    private var made = 0
    private let file = AppState.directory.appendingPathComponent("notes-fake.json")

    init(seed: Bool) {
        guard seed else { return }
        let now = Date()
        items = [
            NoteInfo(id: "fake-shopping", title: "Покупки", text: "молоко\nхлеб", modified: now.addingTimeInterval(-3600)),
            NoteInfo(id: "fake-passwords", title: "Пароли", text: "", modified: now.addingTimeInterval(-7200), locked: true),
            NoteInfo(id: "fake-dacha", title: "Дача", text: "фото забора", modified: now.addingTimeInterval(-86400), attachments: true),
        ]
    }

    func add(title: String, text: String) async throws -> NoteInfo {
        made += 1
        let note = NoteInfo(id: "fake-\(made)", title: title, text: text, modified: Date())
        items.append(note)
        try save()
        return note
    }

    func notes() async throws -> [NoteInfo] {
        items.map { NoteInfo(id: $0.id, title: $0.title, text: String($0.text.prefix(300)), modified: $0.modified, locked: $0.locked,
                             attachments: $0.attachments) }
    }

    func note(id: String) async throws -> NoteInfo {
        guard let note = items.first(where: { $0.id == id }) else { throw NotesAccessError.notFound }
        return note
    }

    func append(id: String, text: String) async throws -> NoteInfo {
        let i = try writable(id)
        let n = items[i]
        items[i] = NoteInfo(id: id, title: n.title, text: n.text.isEmpty ? text : n.text + "\n" + text, modified: Date(),
                            attachments: n.attachments)
        try save()
        return items[i]
    }

    func rewrite(id: String, title: String, text: String) async throws -> NoteInfo {
        let i = try writable(id)
        guard !items[i].attachments else { throw NotesAccessError.attachments }
        items[i] = NoteInfo(id: id, title: title, text: text, modified: Date())
        try save()
        return items[i]
    }

    func delete(id: String) async throws {
        let i = try writable(id)
        deleted.append(items.remove(at: i))
        try save()
    }

    private func writable(_ id: String) throws -> Int {
        guard let i = items.firstIndex(where: { $0.id == id }) else { throw NotesAccessError.notFound }
        guard !items[i].locked else { throw NotesAccessError.locked }
        return i
    }

    private func save() throws {
        func row(_ n: NoteInfo, _ state: String) -> [String: Any] {
            ["id": n.id, "title": n.title, "text": n.text, "locked": n.locked, "attachments": n.attachments, "state": state]
        }
        let rows = items.map { row($0, "open") } + deleted.map { row($0, "deleted") }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }
}
