import ChilkBrain
import ChilkCore
import Foundation
import Testing

/// Slice 8f (SPEC «Срез 8», decisions 3–7, 10, 13): the notes tools. A fake store stands in for Apple Notes.
struct ChilkNotesTests {
    actor FakeStore: NotesStore {
        var items: [NoteInfo] = []
        var writes: [String] = []
        var deny = false

        func seed(_ n: NoteInfo) { items.append(n) }
        func refuse() { deny = true }

        func add(title: String, text: String) async throws -> NoteInfo {
            guard !deny else { throw NotesAccessError.denied }
            writes.append("add \(title)")
            let n = NoteInfo(id: "n\(items.count + 1)", title: title, text: text, modified: Date())
            items.append(n)
            return n
        }
        func notes() async throws -> [NoteInfo] {
            guard !deny else { throw NotesAccessError.denied }
            return items
        }
        func note(id: String) async throws -> NoteInfo {
            guard !deny else { throw NotesAccessError.denied }
            guard let n = items.first(where: { $0.id == id }) else { throw NotesAccessError.notFound }
            return n
        }
        func append(id: String, text: String) async throws -> NoteInfo {
            let n = try await note(id: id)
            writes.append("append \(n.title)")
            return n
        }
        func rewrite(id: String, title: String, text: String) async throws -> NoteInfo {
            let n = try await note(id: id)
            writes.append("rewrite \(n.title)")
            return n
        }
        func delete(id: String) async throws {
            let n = try await note(id: id)
            writes.append("delete \(n.title)")
        }
    }

    private func ids(_ r: CodexToolResult) -> [String] {
        guard case .array(let a)? = r.value["notes"] else { return [] }
        return a.compactMap { $0["id"]?.string }
    }

    @Test func proposalsAreNotDeedsAndTheToolsHaveTheirSwitch() {
        #expect(ChilkNotesExecutor.proposes("chilk_note") && ChilkNotesExecutor.proposes("chilk_note_change"))
        #expect(ChilkNotesExecutor.handles("chilk_notes") && !ChilkNotesExecutor.handles("chilk_note"))
        var s = ToolSwitches()
        s.set(.notes, on: false)
        for name in ["chilk_note", "chilk_notes", "chilk_note_change"] {
            #expect(ChilkToolCatalog.switchedOff(name: name, arguments: [:], switches: s, kindOf: { _ in nil }) == .notes)
        }
        #expect(ChilkToolCatalog.switchedOff(name: "chilk_event", arguments: [:], switches: s, kindOf: { _ in nil }) == nil)
    }

    @Test func aNoteTakesATitleAndTheUsersText() throws {
        let note = try ChilkToolCatalog.parse(name: "chilk_note", arguments: ["title": " Покупки ", "text": "молоко\r\nхлеб\u{0007}\n\n"])
        #expect(note == .note(title: "Покупки", text: "молоко\nхлеб"))
        #expect(throws: ChilkToolCatalog.ToolError.self) {
            try ChilkToolCatalog.parse(name: "chilk_note", arguments: ["title": " ", "text": "x"])
        }
        let long: JSON = ["title": "Мысль", "text": .string(String(repeating: "а", count: 2001))]
        #expect(ChilkToolCatalog.explain(name: "chilk_note", arguments: long).hasPrefix("invalid_arguments: text"))
    }

    @Test func changesNeedWhatTheirActionUses() throws {
        func parse(_ a: JSON) throws -> ChilkAction { try ChilkToolCatalog.parse(name: "chilk_note_change", arguments: a) }
        #expect(try parse(["id": "n1", "action": "append", "title": "", "text": "сыр"]) == .noteChange(id: "n1", change: .append("сыр")))
        #expect(try parse(["id": "n1", "action": "rewrite", "title": "", "text": "кофе"])
                == .noteChange(id: "n1", change: .rewrite(title: nil, text: "кофе")))
        #expect(try parse(["id": "n1", "action": "rewrite", "title": "Кофе", "text": "только кофе"])
                == .noteChange(id: "n1", change: .rewrite(title: "Кофе", text: "только кофе")))
        #expect(try parse(["id": "n1", "action": "delete", "title": "", "text": ""]) == .noteChange(id: "n1", change: .delete))
        let empty: JSON = ["id": "n1", "action": "append", "title": "", "text": "  "]
        #expect(throws: ChilkToolCatalog.ToolError.self) { try parse(empty) }
        #expect(ChilkToolCatalog.explain(name: "chilk_note_change", arguments: empty) == "invalid_arguments: text — append needs the text to add")
    }

    @Test func readingListsTheFolderNewestFirstAndOneNoteWhole() async throws {
        let store = FakeStore()
        await store.seed(NoteInfo(id: "a", title: "Старое", text: "x", modified: Date(timeIntervalSince1970: 1_000)))
        await store.seed(NoteInfo(id: "b", title: "Новое", text: String(repeating: "я", count: 5000), modified: Date(timeIntervalSince1970: 2_000)))
        await store.seed(NoteInfo(id: "c", title: "Пароли", text: "", modified: Date(timeIntervalSince1970: 500), locked: true))
        let exec = ChilkNotesExecutor(store: store)
        let list = await exec.execute(name: "chilk_notes", arguments: ["id": ""])
        #expect(list.success && ids(list) == ["b", "a", "c"] && list.value["folder"]?.string == "Чилк")
        let one = await exec.execute(name: "chilk_notes", arguments: ["id": "b"])
        #expect(one.value["text"]?.string?.count == 4000 && one.value["truncated"]?.bool == true)
        let locked = await exec.execute(name: "chilk_notes", arguments: ["id": "c"])
        #expect(locked.value["locked"]?.bool == true && locked.value["text"] == nil)
        #expect(await store.writes.isEmpty)
    }

    @Test func errorsSayWhatHappenedAndNothingIsWritten() async {
        let store = FakeStore()
        await store.refuse()
        let exec = ChilkNotesExecutor(store: store)
        let r = await exec.create(title: "Мысль", text: "x")
        #expect(!r.success && r.value["error"]?.string?.hasPrefix("no_access:") == true)
        let missing = await ChilkNotesExecutor(store: FakeStore()).delete(id: "zz")
        #expect(missing.value["error"]?.string?.hasPrefix("not_found:") == true)
        #expect(ChilkNotesExecutor.failure(NotesAccessError.locked).hasPrefix("note_locked:"))
        #expect(ChilkNotesExecutor.failure(NotesAccessError.attachments).hasPrefix("note_has_attachments:"))
        #expect(ChilkNotesExecutor.failure(NotesAccessError.unavailable, nothing: "created").hasSuffix("nothing was created"))
        #expect(await store.writes.isEmpty)
    }
}
