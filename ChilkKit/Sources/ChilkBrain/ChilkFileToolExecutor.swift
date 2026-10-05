import Darwin
import Foundation

/// Serial filesystem work on its own actor, never on the animation/MainActor. Only explicitly granted roots.
public actor ChilkFileToolExecutor {
    private var roots: [ChilkFileScope: URL] = [:]
    private let allowedContainer: URL
    /// The app uses /; an explicit container lets isolated test fixtures live under a hidden scratch directory.
    /// This is host-only construction, never a tool argument or an inherited permission.
    public init(allowedContainer: URL = URL(fileURLWithPath: "/")) {
        self.allowedContainer = allowedContainer.standardizedFileURL
    }
    public func configure(_ roots: [ChilkFileScope: URL]) { self.roots = roots }
    public nonisolated static func handles(_ name: String) -> Bool {
        ["chilk_find_files", "chilk_read_file", "chilk_append_note"].contains(name)
    }

    public func execute(name: String, arguments: JSON) -> CodexToolResult {
        do {
            try Task.checkCancellation()
            switch try ChilkToolCatalog.parse(name: name, arguments: arguments) {
            case .findFiles(let scope, let query, let offset):
                return .ok(try find(scope: scope, query: query, offset: offset))
            case .readFile(let scope, let path): return .ok(try read(scope: scope, path: path))
            case .appendNote(let path, let text): return .ok(try append(path: path, text: text))
            default: return .failure("Unsupported file action")
            }
        } catch let error as FileError { return .failure(error.message) }
        catch is CancellationError { return .failure("Cancelled") }
        catch { return .failure("Unknown tool, invalid arguments or file operation failed") }
    }

    enum FileError: Error {
        case noFolder, blocked, unreadable, unsupported, writeIncomplete
        var message: String {
            switch self {
            case .noFolder: "Choose a folder first in Dock → Файлы и Obsidian"
            case .blocked: "Hidden, private, linked or out-of-scope paths are not allowed"
            case .unreadable: "File unavailable or could not be read"
            case .unsupported: "Only UTF-8 Markdown, text and CSV can be read; Obsidian is Markdown only"
            case .writeIncomplete: "Could not verify the note write. Check the note before retrying; it may have changed"
            }
        }
    }

    private static let blockedNames: Set<String> = [
        "system", "usr", "etc", "bin", "sbin", "dev", "private", "var", "tmp", "applications", "cores",
        "library", "node_modules", "vendor", "build", "dist", "target", "venv", "__pycache__",
        "passwords", "secrets", "credentials", "keychains", "auth.json", "id_rsa", "id_ed25519",
    ]
    private static let secretExtensions: Set<String> = ["pem", "key", "p12", "pfx", "keychain", "keychain-db", "env"]
    static func allowedComponent(_ name: String) -> Bool {
        let lower = name.lowercased()
        return !name.hasPrefix(".") && name != ".." && !name.isEmpty && name.utf8.count <= 255
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && !blockedNames.contains(lower) && !secretExtensions.contains((name as NSString).pathExtension.lowercased())
            && !["password", "secret", "credential", "token", "private-key", "private_key"].contains { lower.contains($0) }
    }

    static func allowedRoot(_ root: URL, within container: URL = URL(fileURLWithPath: "/")) -> Bool {
        let parts = root.standardizedFileURL.pathComponents.filter { $0 != "/" }
        let prefix = container.standardizedFileURL.pathComponents.filter { $0 != "/" }
        return root.isFileURL && container.isFileURL && root.path != "/" && parts.starts(with: prefix)
            && parts.count > prefix.count && parts.dropFirst(prefix.count).allSatisfy(allowedComponent)
    }

    /// Opens every component relative to an already-open directory with O_NOFOLLOW: path swaps cannot escape it.
    private func rootFD(_ scope: ChilkFileScope) throws -> Int32 {
        guard let root = roots[scope] else { throw FileError.noFolder }
        let components = root.standardizedFileURL.pathComponents.filter { $0 != "/" }
        guard Self.allowedRoot(root, within: allowedContainer) else { throw FileError.blocked }
        let trustedCount = allowedContainer.pathComponents.filter { $0 != "/" }.count
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw FileError.unreadable }
        do {
            for (index, component) in components.enumerated() {
                try Task.checkCancellation()
                // Container components are host configuration (the app uses /, so none): a system link there, such
                // as /var → /private/var for a test container, may be followed. Inside the grant, never.
                let follow = index < trustedCount ? 0 : O_NOFOLLOW
                let next = Darwin.openat(fd, component, O_RDONLY | O_DIRECTORY | follow | O_CLOEXEC)
                guard next >= 0 else { throw FileError.blocked }
                var ancestor = stat()
                guard index < trustedCount || (fstat(next, &ancestor) == 0 && ancestor.st_flags & UInt32(UF_HIDDEN) == 0) else {
                    Darwin.close(next); throw FileError.blocked
                }
                Darwin.close(fd); fd = next
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_flags & UInt32(UF_HIDDEN) == 0 else { throw FileError.blocked }
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    private func parentFD(_ scope: ChilkFileScope, path: String) throws -> (Int32, String) {
        guard ChilkToolCatalog.validRelativePath(path) else { throw FileError.blocked }
        let components = path.split(separator: "/").map(String.init)
        guard components.allSatisfy(Self.allowedComponent), let name = components.last else { throw FileError.blocked }
        var fd = try rootFD(scope)
        do {
            for component in components.dropLast() {
                let next = Darwin.openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw FileError.blocked }
                var info = stat()
                guard fstat(next, &info) == 0, info.st_flags & UInt32(UF_HIDDEN) == 0 else {
                    Darwin.close(next); throw FileError.blocked
                }
                Darwin.close(fd); fd = next
            }
            return (fd, name)
        } catch { Darwin.close(fd); throw error }
    }

    private func read(scope: ChilkFileScope, path: String) throws -> JSON {
        let ext = (path as NSString).pathExtension.lowercased()
        guard (scope == .obsidian ? ["md"] : ["md", "txt", "csv"]).contains(ext) else { throw FileError.unsupported }
        let (parent, name) = try parentFD(scope, path: path)
        defer { Darwin.close(parent) }
        let fd = Darwin.openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw FileError.unreadable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_flags & UInt32(UF_HIDDEN) == 0 else { throw FileError.blocked }
        var data = Data(count: min(Int(info.st_size), 64000))
        let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count >= 0 else { throw FileError.unreadable }
        data.count = count
        let truncated = info.st_size > count
        // A bounded prefix can end inside a UTF-8 scalar; remove only that incomplete tail, never replace bytes.
        if truncated {
            for _ in 0..<3 where String(data: data, encoding: .utf8) == nil { if !data.isEmpty { data.removeLast() } }
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw FileError.unsupported }
        guard !Self.containsRecognizableSecret(text) else { throw FileError.blocked }
        return ["path": .string(path), "scope": .string(scope.rawValue), "content": .string(text), "truncated": .bool(truncated)]
    }

    private func append(path: String, text: String) throws -> JSON {
        guard (path as NSString).pathExtension.lowercased() == "md",
              !Self.containsRecognizableSecret(text) else { throw FileError.blocked }
        let (parent, name) = try parentFD(.obsidian, path: path)
        defer { Darwin.close(parent) }
        let flags = O_RDWR | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        var fd = Darwin.openat(parent, name, flags | O_CREAT | O_EXCL, mode_t(0o600))
        let created = fd >= 0
        if fd < 0, errno == EEXIST { fd = Darwin.openat(parent, name, flags) }
        guard fd >= 0 else { throw FileError.unreadable }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_flags & UInt32(UF_HIDDEN) == 0, before.st_size >= 0, before.st_size <= 1_048_576 else { throw FileError.blocked }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw FileError.unreadable }
        defer { flock(fd, LOCK_UN) }
        let original = try readBytes(fd, count: Int(before.st_size))
        guard original.count == before.st_size, !original.contains(0),
              let existing = String(data: original, encoding: .utf8),
              !Self.containsRecognizableSecret(existing) else { throw FileError.blocked }
        let separator = original.isEmpty ? "" : (original.last == 10 ? "\n" : "\n\n")
        let addition = Data((separator + text + (text.hasSuffix("\n") ? "" : "\n")).utf8)
        guard original.count + addition.count <= 1_048_576 else { throw FileError.blocked }
        var current = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == before.st_dev, current.st_ino == before.st_ino,
              current.st_size == before.st_size, current.st_nlink == 1 else { throw FileError.writeIncomplete }
        try Task.checkCancellation()
        // O_APPEND, never O_TRUNC or replacement: existing bytes are not rewritten or lost.
        let written = addition.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == addition.count, fsync(fd) == 0 else { throw FileError.writeIncomplete }
        let expected = original + addition
        try Self.verifyCommittedAppend {
            guard try readBytes(fd, count: expected.count) == expected,
                  fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == before.st_dev, current.st_ino == before.st_ino,
                  current.st_size == expected.count, current.st_nlink == 1 else { return false }
            return true
        }
        return ["path": .string(path), "created": .bool(created), "appendedBytes": .number(Double(addition.count))]
    }

    static func searchableDirectory(_ fd: Int32, expected: stat) -> Bool {
        var opened = stat()
        return fstat(fd, &opened) == 0 && opened.st_mode & S_IFMT == S_IFDIR
            && opened.st_flags & UInt32(UF_HIDDEN) == 0
            && opened.st_dev == expected.st_dev && opened.st_ino == expected.st_ino
    }

    static func openDirectory(_ fd: Int32, using open: (Int32) -> UnsafeMutablePointer<DIR>? = { fdopendir($0) },
                              close: (Int32) -> Int32 = { Darwin.close($0) }) -> UnsafeMutablePointer<DIR>? {
        let duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { return nil }
        guard let dir = open(duplicate) else {
            let failure = errno
            _ = close(duplicate)
            errno = failure
            return nil
        }
        return dir
    }

    static func readDirectoryEntry(_ dir: UnsafeMutablePointer<DIR>, using next: (UnsafeMutablePointer<DIR>) -> UnsafeMutablePointer<dirent>? = { readdir($0) }) throws -> UnsafeMutablePointer<dirent>? {
        errno = 0
        let entry = next(dir)
        if entry == nil, errno != 0 { throw FileError.unreadable }
        return entry
    }

    static func verifyCommittedAppend(_ verify: () throws -> Bool) throws {
        do {
            guard try verify() else { throw FileError.writeIncomplete }
        } catch { throw FileError.writeIncomplete }
    }

    private func readBytes(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count), offset = 0
        while offset < count {
            try Task.checkCancellation()
            let n = data.withUnsafeMutableBytes { bytes in
                pread(fd, bytes.baseAddress?.advanced(by: offset), count - offset, off_t(offset))
            }
            if n == 0 { break }
            if n < 0 { if errno == EINTR { continue }; throw FileError.unreadable }
            offset += n
        }
        data.count = offset
        return data
    }

    private static func containsRecognizableSecret(_ text: String) -> Bool {
        text.range(of: #"-----BEGIN (?:[A-Z ]*PRIVATE KEY|OPENSSH PRIVATE KEY)-----|\b(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b|(?i)(?:api[_ -]?key|password|access[_ -]?token|client[_ -]?secret)["']?\s*[=:]\s*\S+"#, options: .regularExpression) != nil
    }

    private func find(scope: ChilkFileScope, query: String, offset: Int) throws -> JSON {
        let fd = try rootFD(scope)
        defer { Darwin.close(fd) }
        var visited = 0, incomplete = false
        var matches: [(String, Int64)] = []
        func walk(_ fd: Int32, _ prefix: String, _ depth: Int) throws {
            guard depth <= 16 else { incomplete = true; return }
            guard let dir = Self.openDirectory(fd) else { incomplete = true; return }
            defer { closedir(dir) }
            while true {
                let entry: UnsafeMutablePointer<dirent>
                do {
                    guard let next = try Self.readDirectoryEntry(dir) else { break }
                    entry = next
                } catch { incomplete = true; break }
                try Task.checkCancellation()
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                visited += 1
                guard visited <= 10000 else { incomplete = true; return }
                guard Self.allowedComponent(name) else { continue }
                let path = prefix + name
                guard ChilkToolCatalog.validRelativePath(path) else { continue }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { incomplete = true; continue }
                guard info.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
                if info.st_mode & S_IFMT == S_IFDIR {
                    let child = Darwin.openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { incomplete = true; continue }
                    guard Self.searchableDirectory(child, expected: info) else {
                        Darwin.close(child); incomplete = true; continue
                    }
                    do { try walk(child, path + "/", depth + 1) } catch { Darwin.close(child); throw error }
                    Darwin.close(child)
                } else if info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                          scope != .obsidian || (path as NSString).pathExtension.lowercased() == "md",
                          name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    matches.append((path, info.st_size))
                }
                if visited > 10000 { return }
            }
        }
        try walk(fd, "", 0)
        matches.sort { $0.0 < $1.0 }
        let page = matches.dropFirst(offset).prefix(30).map { path, bytes -> JSON in
            ["path": .string(path), "name": .string((path as NSString).lastPathComponent), "bytes": .number(Double(bytes))]
        }
        return ["scope": .string(scope.rawValue), "files": .array(page),
                "hasMore": .bool(matches.count > offset + page.count), "scanTruncated": .bool(incomplete)]
    }
}
