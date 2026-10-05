import Darwin
import Foundation

/// Serial filesystem work on its own actor, never on the animation/MainActor. Only explicitly granted folders, and
/// only reading (decision 2026-10-05): nothing here creates, writes, moves, renames or deletes a file.
public actor ChilkFileToolExecutor {
    private var grants: [String: FolderGrant] = [:]
    private var order: [String] = []
    private let allowedContainer: URL
    private let home: URL
    /// The app uses /; an explicit container lets isolated test fixtures live under a hidden scratch directory.
    /// This is host-only construction, never a tool argument or an inherited permission.
    public init(allowedContainer: URL = URL(fileURLWithPath: "/"),
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.allowedContainer = allowedContainer.standardizedFileURL
        self.home = Self.canonical(home)
    }

    static func canonical(_ url: URL) -> URL {
        guard let path = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    /// Cloud folders live under the hidden ~/Library: iCloud Drive and app containers such as Obsidian's in
    /// `~/Library/Mobile Documents/<container>/…`, File Provider drives (Google Drive, Dropbox, OneDrive) in
    /// `~/Library/CloudStorage/<provider>/…`. Only those two components are let through, only below a container;
    /// everything else in ~/Library stays blocked. Indices are into the path's components without "/".
    static func cloudPassage(_ components: [String], home: URL) -> Set<Int> {
        // Canonical (/private/var/…) and standardized (/var/…) spellings of the same home both count.
        guard let homeParts = [home.pathComponents, home.standardizedFileURL.pathComponents]
                .map({ $0.filter { $0 != "/" } }).first(where: { components.starts(with: $0) }) else { return [] }
        let h = homeParts.count
        guard components.count > h + 2, components[h] == "Library",
              ["Mobile Documents", "CloudStorage"].contains(components[h + 1]) else { return [] }
        return [h, h + 1]
    }
    public func configure(_ grants: [FolderGrant]) {
        self.grants = Dictionary(grants.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        order = grants.map(\.name)
    }
    public nonisolated static func handles(_ name: String) -> Bool {
        ["chilk_find_files", "chilk_read_file", "chilk_list_folders", "chilk_request_folder"].contains(name)
    }

    public func execute(name: String, arguments: JSON) -> CodexToolResult {
        do {
            try Task.checkCancellation()
            switch try ChilkToolCatalog.parse(name: name, arguments: arguments) {
            case .findFiles(let folder, let query, let offset):
                return .ok(try find(folder: folder, query: query, offset: offset))
            case .readFile(let folder, let path): return .ok(try read(folder: folder, path: path))
            case .listFolders: return .ok(list())
            default: return .failure("Unsupported file action")
            }
        } catch let error as FileError { return .failure(error.message) }
        catch is CancellationError { return .failure("Cancelled") }
        catch { return .failure("Unknown tool, invalid arguments or file operation failed") }
    }

    enum FileError: Error {
        case noFolder, unknownFolder, blocked, unreadable, unsupported
        var message: String {
            switch self {
            case .noFolder: "No folder is shared yet: ask with chilk_request_folder or let the user add one in Chilk's tools"
            case .unknownFolder: "No such shared folder; see chilk_list_folders"
            case .blocked: "Hidden, private, linked or out-of-scope paths are not allowed"
            case .unreadable: "File unavailable or could not be read"
            case .unsupported: "Only UTF-8 Markdown, text and CSV can be read; Obsidian is Markdown only"
            }
        }
    }

    /// Names, kinds and where they are (relative to home) — no file contents.
    private func list() -> JSON {
        ["folders": .array(order.compactMap { grants[$0] }.map { g in
            ["name": .string(g.name), "kind": .string(g.kind.rawValue), "location": .string(Self.location(g.root, home: home))]
        }), "readOnly": true]
    }

    static func location(_ root: URL, home: URL) -> String {
        let parts = root.standardizedFileURL.pathComponents, homeParts = home.standardizedFileURL.pathComponents
        guard parts.starts(with: homeParts), parts.count > homeParts.count else { return root.path }
        return "~/" + parts.dropFirst(homeParts.count).joined(separator: "/")
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

    static func allowedRoot(_ root: URL, within container: URL = URL(fileURLWithPath: "/"),
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let parts = root.standardizedFileURL.pathComponents.filter { $0 != "/" }
        let prefix = container.standardizedFileURL.pathComponents.filter { $0 != "/" }
        let cloud = cloudPassage(parts, home: canonical(home))
        return root.isFileURL && container.isFileURL && root.path != "/" && parts.starts(with: prefix)
            && parts.count > prefix.count
            && parts.indices.dropFirst(prefix.count).allSatisfy { cloud.contains($0) || allowedComponent(parts[$0]) }
    }

    /// Opens every component relative to an already-open directory with O_NOFOLLOW: path swaps cannot escape it.
    private func rootFD(_ grant: FolderGrant) throws -> Int32 {
        let root = grant.root
        let components = root.standardizedFileURL.pathComponents.filter { $0 != "/" }
        guard Self.allowedRoot(root, within: allowedContainer, home: home) else { throw FileError.blocked }
        let trustedCount = allowedContainer.pathComponents.filter { $0 != "/" }.count
        let cloud = Self.cloudPassage(components, home: home)
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
                guard index < trustedCount || cloud.contains(index)
                        || (fstat(next, &ancestor) == 0 && ancestor.st_flags & UInt32(UF_HIDDEN) == 0) else {
                    Darwin.close(next); throw FileError.blocked
                }
                Darwin.close(fd); fd = next
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_flags & UInt32(UF_HIDDEN) == 0 else { throw FileError.blocked }
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    private func grant(_ folder: String) throws -> FolderGrant {
        guard !grants.isEmpty else { throw FileError.noFolder }
        guard let grant = grants[folder] else { throw FileError.unknownFolder }
        return grant
    }

    private func parentFD(_ grant: FolderGrant, path: String) throws -> (Int32, String) {
        guard ChilkToolCatalog.validRelativePath(path) else { throw FileError.blocked }
        let components = path.split(separator: "/").map(String.init)
        guard components.allSatisfy(Self.allowedComponent), let name = components.last else { throw FileError.blocked }
        var fd = try rootFD(grant)
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

    private func read(folder: String, path: String) throws -> JSON {
        let grant = try grant(folder)
        let ext = (path as NSString).pathExtension.lowercased()
        guard (grant.kind == .obsidian ? ["md"] : ["md", "txt", "csv"]).contains(ext) else { throw FileError.unsupported }
        let (parent, name) = try parentFD(grant, path: path)
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
        return ["folder": .string(folder), "path": .string(path), "content": .string(text), "truncated": .bool(truncated)]
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

    private static func containsRecognizableSecret(_ text: String) -> Bool {
        text.range(of: #"-----BEGIN (?:[A-Z ]*PRIVATE KEY|OPENSSH PRIVATE KEY)-----|\b(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b|(?i)(?:api[_ -]?key|password|access[_ -]?token|client[_ -]?secret)["']?\s*[=:]\s*\S+"#, options: .regularExpression) != nil
    }

    /// `folder` is a shared folder's name or "all". Results are sorted by folder order, then path.
    private func find(folder: String, query: String, offset: Int) throws -> JSON {
        let targets = folder == "all" ? order.compactMap { grants[$0] } : [try grant(folder)]
        guard !targets.isEmpty else { throw FileError.noFolder }
        var visited = 0, incomplete = false
        var matches: [(String, String, Int64)] = []
        for grant in targets {
            let fd = try rootFD(grant)
            defer { Darwin.close(fd) }
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
                              grant.kind != .obsidian || (path as NSString).pathExtension.lowercased() == "md",
                              name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                        matches.append((grant.name, path, info.st_size))
                    }
                    if visited > 10000 { return }
                }
            }
            var found: [(String, String, Int64)] = []
            swap(&found, &matches)
            try walk(fd, "", 0)
            matches.sort { $0.1 < $1.1 }
            matches = found + matches
            if visited > 10000 { break }
        }
        let page = matches.dropFirst(offset).prefix(30).map { folder, path, bytes -> JSON in
            ["folder": .string(folder), "path": .string(path), "name": .string((path as NSString).lastPathComponent),
             "bytes": .number(Double(bytes))]
        }
        return ["files": .array(page), "hasMore": .bool(matches.count > offset + page.count), "scanTruncated": .bool(incomplete)]
    }
}
