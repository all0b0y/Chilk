import Foundation
import Testing
@testable import ChilkBrain

/// Where Chilk finds `codex` when it is started from Finder (no shell PATH): Homebrew, npm's global folders and the
/// Node version managers. A fake home with fake executables stands in for the user's Mac.
@Suite("Locating codex")
struct CodexLocateTests {
    /// A throwaway home; `codex` files are created executable where a test puts them.
    struct Home {
        let url: URL
        var path: String { url.path }

        init() throws {
            let base = ProcessInfo.processInfo.environment["CHILK_TEST_TMP"] ?? ProcessInfo.processInfo.environment["TMPDIR"]
                ?? NSTemporaryDirectory()
            url = URL(fileURLWithPath: base).appendingPathComponent("chilk-home-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        @discardableResult
        func put(_ name: String, in relative: String, executable: Bool = true) throws -> URL {
            let dir = url.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(name)
            try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: file.path)
            return file
        }

        func remove() { try? FileManager.default.removeItem(at: url) }
    }

    @Test func findsCodexInstalledUnderNvmWithoutAShellPath() throws {
        let home = try Home()
        defer { home.remove() }
        let codex = try home.put("codex", in: ".nvm/versions/node/v22.11.0/bin")
        #expect(CodexSetup.locateCodex(path: "/usr/bin:/bin:/usr/sbin:/sbin", home: home.path, systemDirs: [])?.path == codex.path)
    }

    @Test func prefersTheNewestNvmNode() throws {
        let home = try Home()
        defer { home.remove() }
        try home.put("codex", in: ".nvm/versions/node/v9.11.2/bin")
        try home.put("codex", in: ".nvm/versions/node/v20.18.0/bin")
        let newest = try home.put("codex", in: ".nvm/versions/node/v22.11.0/bin")
        #expect(CodexSetup.nvmBinDirectories(home: home.path).first == newest.deletingLastPathComponent().path)
        #expect(CodexSetup.locateCodex(path: nil, home: home.path, systemDirs: [])?.path == newest.path)
    }

    @Test func findsCodexFromVoltaPnpmAndBun() throws {
        for folder in [".volta/bin", "Library/pnpm", ".bun/bin"] {
            let home = try Home()
            defer { home.remove() }
            let codex = try home.put("codex", in: folder)
            #expect(CodexSetup.locateCodex(path: "", home: home.path, systemDirs: [])?.path == codex.path, "\(folder)")
        }
    }

    @Test func thePathStillComesFirstAndAPlainFileIsNotCodex() throws {
        let home = try Home()
        defer { home.remove() }
        let onPath = try home.put("codex", in: "custom/bin")
        try home.put("codex", in: ".nvm/versions/node/v22.11.0/bin")
        #expect(CodexSetup.locateCodex(path: onPath.deletingLastPathComponent().path, home: home.path, systemDirs: [])?.path == onPath.path)

        let other = try Home()
        defer { other.remove() }
        try other.put("codex", in: ".volta/bin", executable: false)
        #expect(CodexSetup.locateCodex(path: "", home: other.path, systemDirs: []) == nil)
    }

    @Test func searchesEachFolderOnce() throws {
        let home = try Home()
        defer { home.remove() }
        let dirs = CodexSetup.searchDirectories(path: "/opt/homebrew/bin:/usr/bin:/opt/homebrew/bin", home: home.path)
        #expect(dirs.filter { $0 == "/opt/homebrew/bin" }.count == 1)
        #expect(dirs.first == "/opt/homebrew/bin")
    }

    /// An npm-installed `codex` is a `#!/usr/bin/env node` script: under nvm, Node is found only beside it.
    @Test func codexFolderIsOnTheChildPathSoItsNodeIsFound() throws {
        let home = try Home()
        defer { home.remove() }
        let codex = try home.put("codex", in: ".nvm/versions/node/v22.11.0/bin")
        let setup = CodexSetup(dataDir: home.url.appendingPathComponent("data"), executable: codex, realHome: home.path)
        let path = setup.environment["PATH"]!.split(separator: ":").map(String.init)
        #expect(path.contains(codex.deletingLastPathComponent().path))
        #expect(path.contains("/opt/homebrew/bin"))
    }
}
