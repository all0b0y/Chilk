import Darwin
import Foundation
import Testing
@testable import ChilkBrain

@Suite("Selected-folder file tools")
struct SelectedFolderToolTests {
    @Test(arguments: [#"{"password":"demo"}"#, #"{"API_KEY":"demo"}"#, "'client_secret' = 'demo'"])
    func quotedSecretAssignmentsCannotBeReadOrAppended(_ text: String) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("normal.md")
        let original = Data(text.utf8)
        try original.write(to: note)
        let executor = ChilkFileToolExecutor(allowedContainer: root.deletingLastPathComponent())
        await executor.configure([.files: root, .obsidian: root])
        let read = await executor.execute(name: "chilk_read_file", arguments: ["scope": "files", "path": "normal.md"])
        #expect(!read.success)
        #expect(!read.value.serialized().contains("demo"))
        let append = await executor.execute(name: "chilk_append_note", arguments: ["path": "normal.md", "text": .string(text)])
        #expect(!append.success)
        #expect(try Data(contentsOf: note) == original)
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
        await e.configure([.files: root])
        let result = await e.execute(name: "chilk_read_file", arguments: ["scope": "files", "path": "Обычная.md"])
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
        await e.configure([.files: root])
        for path in ["escape/Учёба/Сети.md", "alias.md", "hard.md", ".obsidian/hidden.md", "passwords.txt", "../outside.md", "/etc/passwd"] {
            let result = await e.execute(name: "chilk_read_file", arguments: ["scope": "files", "path": .string(path)])
            #expect(!result.success, "must deny \(path)")
            #expect(!result.value.serialized().contains("PRIVATE"))
        }
        let result = await e.execute(name: "chilk_find_files", arguments: ["scope": "files", "query": ".", "offset": 0])
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
        await e.configure([.files: link])
        let read = await e.execute(name: "chilk_read_file", arguments: ["scope": "files", "path": "Учёба/Сети.md"])
        #expect(!read.success)
        #expect(!read.value.serialized().contains("TCP/IP"))
    }

    @Test func longUTF8ReadsAndSearchPagesHaveHonestBounds() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(String(repeating: "🌿", count: 20000).utf8).write(to: root.appendingPathComponent("long.txt"))
        for i in 0..<35 { try Data("hi".utf8).write(to: root.appendingPathComponent(String(format: "page-%02d.md", i))) }
        let e = ChilkFileToolExecutor(allowedContainer: root.deletingLastPathComponent())
        await e.configure([.files: root])
        let read = await e.execute(name: "chilk_read_file", arguments: ["scope": "files", "path": "long.txt"])
        #expect(read.success && read.value["truncated"]?.bool == true)
        #expect(read.value["content"]?.string?.utf8.count == 64000)
        let first = await e.execute(name: "chilk_find_files", arguments: ["scope": "files", "query": "page-", "offset": 0])
        let last = await e.execute(name: "chilk_find_files", arguments: ["scope": "files", "query": "page-", "offset": 30])
        #expect(first.value["hasMore"]?.bool == true && last.value["hasMore"]?.bool == false)
        if case .array(let files) = last.value["files"] { #expect(files.count == 5) }
        else { Issue.record("Expected final page") }
    }

    @Test func notesAreCreatedAndAppendedWithoutOverwritingTheOriginal() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let e = ChilkFileToolExecutor(allowedContainer: root.deletingLastPathComponent())
        await e.configure([.files: root])
        let args: JSON = ["path": "Идеи.md", "text": "Выгулять собаку"]
        #expect(await e.execute(name: "chilk_append_note", arguments: args).success == false)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Идеи.md").path))
        await e.configure([.obsidian: root])
        let created = await e.execute(name: "chilk_append_note", arguments: args)
        #expect(created.success && created.value["created"]?.bool == true)
        let before = try Data(contentsOf: root.appendingPathComponent("Идеи.md"))
        let appended = await e.execute(name: "chilk_append_note", arguments: ["path": "Идеи.md", "text": "И выпить воды"])
        #expect(appended.success && appended.value["created"]?.bool == false)
        let after = try Data(contentsOf: root.appendingPathComponent("Идеи.md"))
        #expect(after.starts(with: before))
        #expect(String(decoding: after, as: UTF8.self) == "Выгулять собаку\n\nИ выпить воды\n")
    }

    @Test func aNoteWriteCannotFollowLinksOverwriteBinaryOrCreateParentFolders() async throws {
        let root = try fixture(), outside = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let target = outside.appendingPathComponent("Учёба/Сети.md")
        let original = try Data(contentsOf: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.md"), withDestinationURL: target)
        try Data([0, 255, 1]).write(to: root.appendingPathComponent("binary.md"))
        let e = ChilkFileToolExecutor(allowedContainer: root.deletingLastPathComponent())
        await e.configure([.obsidian: root])
        for path in ["link.md", "binary.md", "missing/note.md", "script.sh", ".obsidian/settings.md", "../note.md"] {
            #expect(await e.execute(name: "chilk_append_note", arguments: ["path": .string(path), "text": "new"]).success == false)
        }
        #expect(try Data(contentsOf: target) == original)
        #expect(try Data(contentsOf: root.appendingPathComponent("binary.md")) == Data([0, 255, 1]))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
    }

    @Test func aFileHiddenByMacFlagsIsNotSearchableReadableOrWritable() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let hidden = root.appendingPathComponent("hidden.md")
        try Data("HIDDEN".utf8).write(to: hidden)
        #expect(chflags(hidden.path, UInt32(UF_HIDDEN)) == 0)
        let e = ChilkFileToolExecutor(allowedContainer: root.deletingLastPathComponent())
        await e.configure([.files: root, .obsidian: root])
        #expect(await e.execute(name: "chilk_read_file", arguments: ["scope": "files", "path": "hidden.md"]).success == false)
        let found = await e.execute(name: "chilk_find_files", arguments: ["scope": "files", "query": "hidden", "offset": 0])
        #expect(found.value["files"] == .array([]))
        #expect(await e.execute(name: "chilk_append_note", arguments: ["path": "hidden.md", "text": "new"]).success == false)
        #expect(try Data(contentsOf: hidden) == Data("HIDDEN".utf8))
    }

    @Test func cancelledRequestsCannotCreateANote() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let e = ChilkFileToolExecutor(allowedContainer: root.deletingLastPathComponent())
        await e.configure([.obsidian: root])
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await e.execute(name: "chilk_append_note", arguments: ["path": "cancelled.md", "text": "no"])
        }.value
        #expect(!result.success)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cancelled.md").path))
    }

    @Test func findingAndReadingRequireTheSelectedRoot() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let e = ChilkFileToolExecutor(allowedContainer: root.deletingLastPathComponent())
        let args: JSON = ["scope": "files", "query": "сети", "offset": 0]
        #expect(await e.execute(name: "chilk_find_files", arguments: args).success == false)
        await e.configure([.files: root])
        let found = await e.execute(name: "chilk_find_files", arguments: args)
        #expect(found.success)
        if case .array(let files) = found.value["files"] {
            #expect(files.map { $0["path"]?.string } == ["Учёба/Сети.md"])
        } else { Issue.record("Expected filename results") }
        let read = await e.execute(name: "chilk_read_file", arguments: ["scope": "files", "path": "Учёба/Сети.md"])
        #expect(read.success)
        #expect(read.value["content"]?.string == "Сети: TCP/IP\n")
        #expect(read.value["truncated"]?.bool == false)
        await e.configure([:])
        #expect(await e.execute(name: "chilk_read_file", arguments: ["scope": "files", "path": "Учёба/Сети.md"]).success == false)
    }
}
