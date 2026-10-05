import Darwin
import Foundation
import Testing
@testable import ChilkBrain

@Suite("Explicit folder grants")
struct FolderAccessStoreTests {
    private func folderStoreIsOnMainThread(_ store: isolated FolderAccessStore) -> Bool { Thread.isMainThread }
    @Test func bookmarkStorageHasAnIndependentExecutor() async throws {
        let root = try SelectedFolderToolTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await FolderAccessStore(file: root.appendingPathComponent("grants.json"), allowedContainer: root.deletingLastPathComponent())
        #expect(await folderStoreIsOnMainThread(store) == false)
    }

    @Test(arguments: ["System", "usr", "etc", "private", "bin", "sbin", "dev", "var", "tmp", "Applications", "cores"])
    func aSystemNamedAncestorCannotBecomeASelectedRoot(_ name: String) async throws {
        let root = try SelectedFolderToolTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent(name).appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let store = try await FolderAccessStore(file: root.appendingPathComponent("grants.json"), allowedContainer: root.deletingLastPathComponent())
        await #expect(throws: FolderAccessStore.AccessError.self) { try await store.add(.files, url: nested) }
        #expect(await store.grants.isEmpty)
        let executor = ChilkFileToolExecutor(allowedContainer: root.deletingLastPathComponent())
        await executor.configure([FolderGrant(name: "Notes", kind: .files, root: nested)])
        #expect(await executor.execute(name: "chilk_find_files", arguments: ["folder": "Notes", "query": "notes", "offset": 0]).success == false)
    }

    @Test func aNestedRootCannotBypassHiddenOrSecretAncestorNames() async throws {
        #expect(!ChilkFileToolExecutor.allowedRoot(URL(fileURLWithPath: "/Users/example/.private/Notes")))
        #expect(!ChilkFileToolExecutor.allowedRoot(URL(fileURLWithPath: "/Users/example/secrets/Notes")))
        let root = try SelectedFolderToolTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await FolderAccessStore(file: root.appendingPathComponent("grants.json"), allowedContainer: root.deletingLastPathComponent())
        for parent in [".private", "secrets"] {
            let nested = root.appendingPathComponent(parent + "/Notes")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            await #expect(throws: (any Error).self) { try await store.add(.files, url: nested) }
        }
        #expect(await store.grants.isEmpty)
    }

    @Test func aNestedRootCannotBypassAFinderHiddenAncestor() async throws {
        let root = try SelectedFolderToolTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let hidden = root.appendingPathComponent("ordinary")
        let nested = hidden.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(chflags(hidden.path, UInt32(UF_HIDDEN)) == 0)
        let store = try await FolderAccessStore(file: root.appendingPathComponent("grants.json"), allowedContainer: root.deletingLastPathComponent())
        await #expect(throws: (any Error).self) { try await store.add(.files, url: nested) }
        #expect(await store.grants.isEmpty)
    }

    @Test func chosenFoldersSurviveRestartAndRevocationIsPersisted() async throws {
        let root = try SelectedFolderToolTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("grants.json")
        let store = try await FolderAccessStore(file: file, allowedContainer: root.deletingLastPathComponent())
        #expect(await store.grants.isEmpty)
        let files = try await store.add(.files, url: root)
        let vault = try await store.add(.obsidian, url: root)
        #expect(try await store.add(.files, url: root) == files)                 // the same folder is not added twice
        #expect(files.name != vault.name)
        let restored = try await FolderAccessStore(file: file, allowedContainer: root.deletingLastPathComponent())
        #expect(await restored.grants == [files, vault])
        try await restored.remove(name: files.name)
        let reopened = try await FolderAccessStore(file: file, allowedContainer: root.deletingLastPathComponent())
        #expect(await reopened.grants == [vault])
    }

    @Test func anInvalidVaultOrFailedSaveDoesNotGrantAnything() async throws {
        let root = try SelectedFolderToolTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("grants.json")
        let store = try await FolderAccessStore(file: file, allowedContainer: root.deletingLastPathComponent())
        await #expect(throws: (any Error).self) { try await store.add(.obsidian, url: root) }
        #expect(await store.grants.isEmpty)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await store.add(.files, url: root) }
        #expect(await store.grants.isEmpty)
    }

    @Test func corruptStoredAccessFailsClosedRatherThanGuessingAFolder() async throws {
        let root = try SelectedFolderToolTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("grants.json")
        try Data("bad data".utf8).write(to: file)
        await #expect(throws: (any Error).self) { try await FolderAccessStore(file: file, allowedContainer: root.deletingLastPathComponent()) }
    }

    @Test func neverTheWholeHomeAnythingAboveItOrADiskTopLevel() async throws {
        let root = try SelectedFolderToolTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Учёба")                     // pretend this is the home folder
        let store = try await FolderAccessStore(file: root.appendingPathComponent("grants.json"),
                                                allowedContainer: URL(fileURLWithPath: "/"), home: home)
        for url in [home, root, URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/Users")] {
            await #expect(throws: (any Error).self) { try await store.add(.files, url: url) }
        }
        #expect(await store.grants.isEmpty)
    }

    @Test func aVersionOneFileIsKeptAsSharedFolders() async throws {
        let root = try SelectedFolderToolTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("grants.json")
        let bookmark = try root.bookmarkData(options: [.withoutImplicitSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        try JSONEncoder().encode(["files": bookmark]).write(to: file)
        let store = try await FolderAccessStore(file: file, allowedContainer: root.deletingLastPathComponent())
        #expect(await store.grants.map(\.kind) == [.files])
        #expect(await store.grants.first?.root.path == root.path)
    }
}
