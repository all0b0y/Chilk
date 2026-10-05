import Darwin
import Foundation
import Testing
@testable import ChilkBrain

@Suite("Selected-folder file tools")
struct SelectedFolderToolTests {
    @Test(arguments: [#"{"password":"demo"}"#, #"{"API_KEY":"demo"}"#, "'client_secret' = 'demo'"])
    func quotedSecretAssignmentsCannotBeRead(_ text: String) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("normal.md")
        let original = Data(text.utf8)
        try original.write(to: note)
        let executor = ChilkFileToolExecutor(allowedContainer: root.deletingLastPathComponent())
        await executor.configure([grant(root), grant(root, .obsidian, "Хранилище")])
        let read = await executor.execute(name: "chilk_read_file", arguments: ["folder": "Папка", "path": "normal.md"])
        #expect(!read.success)
        #expect(!read.value.serialized().contains("demo"))
        #expect(try Data(contentsOf: note) == original)
    }
    func grant(_ root: URL, _ kind: ChilkFileScope = .files, _ name: String = "Папка") -> FolderGrant {
        FolderGrant(name: name, kind: kind, root: root)
    }

    func fixture() throws -> URL {
        let base = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let root = URL(fileURLWithPath: base).appendingPathComponent("chilk-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Учёба"), withIntermediateDirectories: true)
        try Data("Сети: TCP/IP\n".utf8).write(to: root.appendingPathComponent("Учёба/Сети.md"))
        // Granted roots are canonical in the app (FolderAccessStore: realpath). `resolvingSymlinksInPath` is not:
        // it turns /private/var/folders/… back into /var/folders/…, and /var is a symlink the executor never follows.
        guard let canonical = realpath(root.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
    }

    @Test func secretContentIsNeverReturnedEvenInAnOrdinaryTextFile() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("-----BEGIN PRIVATE KEY-----\nNOT-A-REAL-KEY\n".utf8).write(to: root.appendingPathComponent("Обычная.md"))
        let e = ChilkFileToolExecutor(allowedContainer: root.deletingLastPathComponent())
        await e.configure([grant(root)])
        let result = await e.execute(name: "chilk_read_file", arguments: ["folder": "Папка", "path": "Обычная.md"])
        #expect(!result.success)
        #expect(!result.value.serialized().contains("NOT-A-REAL-KEY"))
    }

    @Test func linksHiddenPathsAndTraversalNeverEscapeTheGrant() async throws {
        let root = try fixture(), outside = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let fm = FileManager.default
        try fm.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("alias.md"), withDestinationURL: outside.appendingPathComponent("Учёба/Сети.md"))
        try fm.linkItem(at: outside.appendingPathComponent("Учёба/Сети.md"), to: root.appendingPathComponent("hard.md"))
        try fm.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try Data("PRIVATE".utf8).write(to: root.appendingPathComponent(".obsidian/hidden.md"))
        try Data("PRIVATE".utf8).write(to: root.appendingPathComponent("passwords.txt"))
        let e = ChilkFileToolExecutor(allowedContainer: root.deletingLastPathComponent())
        await e.configure([grant(root)])
        for path in ["escape/Учёба/Сети.md", "alias.md", "hard.md", ".obsidian/hidden.md", "passwords.txt", "../outside.md", "/etc/passwd"] {
            let result = await e.execute(name: "chilk_read_file", arguments: ["folder": "Папка", "path": .string(path)])
            #expect(!result.success, "must deny \(path)")
            #expect(!result.value.serialized().contains("PRIVATE"))
        }
        let result = await e.execute(name: "chilk_find_files", arguments: ["folder": "Папка", "query": ".", "offset": 0])
        #expect(result.success)
        if case .array(let files) = result.value["files"] { #expect(files.count == 1) }
        else { Issue.record("Expected a filtered file list") }
    }

    /// Links in the host container may be followed (tests: /var → /private/var); a grant reached via a link may not.
    @Test func aGrantWhosePathIsALinkIsDenied() async throws {
        let real = try fixture()
        let link = real.deletingLastPathComponent().appendingPathComponent("chilk-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: real); try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let e = ChilkFileToolExecutor(allowedContainer: real.deletingLastPathComponent())
        await e.configure([grant(link)])
        let read = await e.execute(name: "chilk_read_file", arguments: ["folder": "Папка", "path": "Учёба/Сети.md"])
        #expect(!read.success)
        #expect(!read.value.serialized().contains("TCP/IP"))
    }

    @Test func longUTF8ReadsAndSearchPagesHaveHonestBounds() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(String(repeating: "🌿", count: 20000).utf8).write(to: root.appendingPathComponent("long.txt"))
        for i in 0..<35 { try Data("hi".utf8).write(to: root.appendingPathComponent(String(format: "page-%02d.md", i))) }
        let e = ChilkFileToolExecutor(allowedContainer: root.deletingLastPathComponent())
        await e.configure([grant(root)])
        let read = await e.execute(name: "chilk_read_file", arguments: ["folder": "Папка", "path": "long.txt"])
        #expect(read.success && read.value["truncated"]?.bool == true)
        #expect(read.value["content"]?.string?.utf8.count == 64000)
        let first = await e.execute(name: "chilk_find_files", arguments: ["folder": "Папка", "query": "page-", "offset": 0])
        let last = await e.execute(name: "chilk_find_files", arguments: ["folder": "Папка", "query": "page-", "offset": 30])
        #expect(first.value["hasMore"]?.bool == true && last.value["hasMore"]?.bool == false)
        if case .array(let files) = last.value["files"] { #expect(files.count == 5) }
        else { Issue.record("Expected final page") }
    }

    @Test func aFileHiddenByMacFlagsIsNotSearchableOrReadable() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let hidden = root.appendingPathComponent("hidden.md")
        try Data("HIDDEN".utf8).write(to: hidden)
        #expect(chflags(hidden.path, UInt32(UF_HIDDEN)) == 0)
        let e = ChilkFileToolExecutor(allowedContainer: root.deletingLastPathComponent())
        await e.configure([grant(root), grant(root, .obsidian, "Хранилище")])
        #expect(await e.execute(name: "chilk_read_file", arguments: ["folder": "Папка", "path": "hidden.md"]).success == false)
        let found = await e.execute(name: "chilk_find_files", arguments: ["folder": "Папка", "query": "hidden", "offset": 0])
        #expect(found.value["files"] == .array([]))
        #expect(try Data(contentsOf: hidden) == Data("HIDDEN".utf8))
    }

    @Test func findingAndReadingRequireTheSelectedRoot() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let e = ChilkFileToolExecutor(allowedContainer: root.deletingLastPathComponent())
        let args: JSON = ["folder": "Папка", "query": "сети", "offset": 0]
        #expect(await e.execute(name: "chilk_find_files", arguments: args).success == false)
        await e.configure([grant(root)])
        let found = await e.execute(name: "chilk_find_files", arguments: args)
        #expect(found.success)
        if case .array(let files) = found.value["files"] {
            #expect(files.map { $0["path"]?.string } == ["Учёба/Сети.md"])
        } else { Issue.record("Expected filename results") }
        let read = await e.execute(name: "chilk_read_file", arguments: ["folder": "Папка", "path": "Учёба/Сети.md"])
        #expect(read.success)
        #expect(read.value["content"]?.string == "Сети: TCP/IP\n")
        #expect(read.value["truncated"]?.bool == false)
        await e.configure([])
        #expect(await e.execute(name: "chilk_read_file", arguments: ["folder": "Папка", "path": "Учёба/Сети.md"]).success == false)
    }

    /// Decision 2026-10-05: files are read-only — there is no tool that writes, and old write calls fail.
    @Test func thereIsNoWayToWriteMoveOrDeleteAFile() async throws {
        let names = Set(ChilkToolCatalog.tools.map(\.name))
        #expect(names.isDisjoint(with: ["chilk_append_note", "chilk_write_file", "chilk_move_file", "chilk_delete_file"]))
        #expect(names.filter { $0.contains("file") || $0.contains("folder") || $0.contains("note") }
                == Set(["chilk_find_files", "chilk_read_file", "chilk_list_folders", "chilk_request_folder"]))
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let e = ChilkFileToolExecutor(allowedContainer: root.deletingLastPathComponent())
        await e.configure([grant(root, .obsidian, "Хранилище")])
        let write = await e.execute(name: "chilk_append_note", arguments: ["path": "Идеи.md", "text": "Мысль"])
        #expect(!write.success)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Идеи.md").path))
    }

    @Test func severalSharedFoldersAreSearchedTogetherOrOneByOneAndListedWithoutContents() async throws {
        let work = try fixture(), study = try fixture()
        defer { try? FileManager.default.removeItem(at: work); try? FileManager.default.removeItem(at: study) }
        try Data("план".utf8).write(to: work.appendingPathComponent("Сети-план.txt"))
        let e = ChilkFileToolExecutor(allowedContainer: work.deletingLastPathComponent())
        await e.configure([grant(work, .files, "Работа"), grant(study, .files, "Учёба")])
        let all = await e.execute(name: "chilk_find_files", arguments: ["folder": "all", "query": "сети", "offset": 0])
        if case .array(let files) = all.value["files"] {
            #expect(files.map { "\($0["folder"]?.string ?? "")/\($0["path"]?.string ?? "")" }
                    == ["Работа/Сети-план.txt", "Работа/Учёба/Сети.md", "Учёба/Учёба/Сети.md"])
        } else { Issue.record("Expected results from both folders") }
        let one = await e.execute(name: "chilk_find_files", arguments: ["folder": "Учёба", "query": "сети", "offset": 0])
        if case .array(let files) = one.value["files"] { #expect(files.count == 1) } else { Issue.record("Expected one folder") }
        #expect(await e.execute(name: "chilk_read_file", arguments: ["folder": "Нет такой", "path": "Учёба/Сети.md"]).success == false)
        let list = await e.execute(name: "chilk_list_folders", arguments: [:])
        #expect(list.value["readOnly"]?.bool == true)
        if case .array(let folders) = list.value["folders"] {
            #expect(folders.map { $0["name"]?.string } == ["Работа", "Учёба"])
            #expect(!list.value.serialized().contains("TCP/IP"))
        } else { Issue.record("Expected the folder list") }
    }
}
