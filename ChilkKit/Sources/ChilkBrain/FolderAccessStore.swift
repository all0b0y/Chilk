import Darwin
import Foundation

/// A folder the user let Chilk read (decision 2026-10-05: files are read-only, any number of folders, all chosen or
/// confirmed by the user). `name` is how Codex refers to it; `kind` .obsidian reads Markdown only.
public struct FolderGrant: Sendable, Equatable {
    public var name: String
    public var kind: ChilkFileScope
    public var root: URL

    public init(name: String, kind: ChilkFileScope, root: URL) {
        self.name = name
        self.kind = kind
        self.root = root
    }
}

/// Explicit user choices only. No environment variables, discovery of vaults, or inherited agent access.
public actor FolderAccessStore {
    public enum AccessError: Error, Equatable { case invalidFolder, invalidVault, tooBroad, tooMany, corruptStore }
    public static let maxGrants = 50
    public private(set) var grants: [FolderGrant] = []
    private var bookmarks: [String: Data] = [:]                    // by grant name
    private let file: URL
    private let allowedContainer: URL
    private let home: URL

    public init(file: URL, allowedContainer: URL = URL(fileURLWithPath: "/"),
                home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws {
        self.file = file
        self.allowedContainer = allowedContainer.standardizedFileURL
        self.home = Self.canonical(home) ?? home.standardizedFileURL
        try load()
    }

    private struct Stored: Codable {
        var version = 2
        var grants: [Entry]
        struct Entry: Codable { var name: String; var kind: ChilkFileScope; var bookmark: Data }
    }

    private func load() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 262_144 else { throw AccessError.corruptStore }
        let data = try Data(contentsOf: file)
        let entries: [Stored.Entry]
        if let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            entries = stored.grants
        } else {
            // Version 1: one folder per kind, {"files": bookmark, "obsidian": bookmark}.
            let old = try JSONDecoder().decode([String: Data].self, from: data)
            guard Set(old.keys).isSubset(of: ["files", "obsidian"]) else { throw AccessError.corruptStore }
            entries = old.sorted { $0.key < $1.key }.compactMap { key, bookmark in
                ChilkFileScope(rawValue: key).map { Stored.Entry(name: "", kind: $0, bookmark: bookmark) }
            }
        }
        guard entries.count <= Self.maxGrants else { throw AccessError.corruptStore }
        for entry in entries {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: entry.bookmark, options: [.withoutUI, .withoutMounting],
                                     relativeTo: nil, bookmarkDataIsStale: &stale), !stale,
                  let root = try? validate(entry.kind, url: url) else { continue }
            let name = entry.name.isEmpty || grants.contains(where: { $0.name == entry.name })
                ? uniqueName(for: root) : entry.name
            grants.append(FolderGrant(name: name, kind: entry.kind, root: root))
            bookmarks[name] = entry.bookmark
        }
    }

    /// Adds a folder (or returns the existing grant for the same folder and kind).
    @discardableResult
    public func add(_ kind: ChilkFileScope, url: URL) throws -> FolderGrant {
        let root = try validate(kind, url: url)
        if let existing = grants.first(where: { $0.root.path == root.path && $0.kind == kind }) { return existing }
        guard grants.count < Self.maxGrants else { throw AccessError.tooMany }
        // Chilk is not App-Sandboxed: keep a persistent location without implicit, temporary scope escalation.
        let bookmark = try root.bookmarkData(options: [.withoutImplicitSecurityScope],
                                             includingResourceValuesForKeys: nil, relativeTo: nil)
        let grant = FolderGrant(name: uniqueName(for: root), kind: kind, root: root)
        var candidate = bookmarks
        candidate[grant.name] = bookmark
        try save(grants + [grant], candidate)
        bookmarks = candidate
        grants.append(grant)
        return grant
    }

    /// A folder from a multiple choice that could not be added, and why.
    public struct Refusal: Sendable {
        public let url: URL
        public let error: any Error
    }

    /// What the one alert after a multiple choice says (review 2026-10-08): every refused folder in the order chosen,
    /// each reason once with its folders, and whether any chosen folder is in the list now.
    public struct RefusalSummary: Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            case notAVault, tooBroad, tooMany, unavailable

            public init(_ error: any Error) {
                switch error as? AccessError {
                case .invalidVault: self = .notAVault
                case .tooBroad: self = .tooBroad
                case .tooMany: self = .tooMany
                default: self = .unavailable
                }
            }
        }

        public struct Group: Equatable, Sendable {
            public let reason: Reason
            public let names: [String]
        }

        public let names: [String]
        public let groups: [Group]                                  // reasons in the order first met
        public let othersAdded: Bool

        public init(chosen: Int, refused: [Refusal]) {
            names = refused.map(\.url.lastPathComponent)
            var groups: [Group] = []
            for refusal in refused {
                let reason = Reason(refusal.error), name = refusal.url.lastPathComponent
                if let index = groups.firstIndex(where: { $0.reason == reason }) {
                    groups[index] = Group(reason: reason, names: groups[index].names + [name])
                } else {
                    groups.append(Group(reason: reason, names: [name]))
                }
            }
            self.groups = groups
            othersAdded = chosen > refused.count
        }
    }

    /// Several folders chosen at once (the panel allows a multiple selection): each is added as by `add(_:url:)`, in
    /// order; the ones that cannot be added come back with the reason, the others are kept.
    public func add(_ kind: ChilkFileScope, urls: [URL]) -> [Refusal] {
        urls.compactMap { url in
            do { try add(kind, url: url); return nil } catch { return Refusal(url: url, error: error) }
        }
    }

    public func remove(name: String) throws {
        guard grants.contains(where: { $0.name == name }) else { return }
        let kept = grants.filter { $0.name != name }
        var candidate = bookmarks
        candidate.removeValue(forKey: name)
        try save(kept, candidate)
        bookmarks = candidate
        grants = kept
    }

    /// Would `url` be accepted, and where is it really? (Used before asking the user about a folder.)
    public func check(_ kind: ChilkFileScope, url: URL) throws -> URL { try validate(kind, url: url) }

    private func save(_ list: [FolderGrant], _ marks: [String: Data]) throws {
        let stored = Stored(grants: list.compactMap { g in marks[g.name].map { .init(name: g.name, kind: g.kind, bookmark: $0) } })
        let data = try JSONEncoder().encode(stored)
        guard data.count <= 262_144 else { throw AccessError.corruptStore }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    /// «Работа», then «Работа 2», … — names are how Codex refers to folders.
    private func uniqueName(for root: URL) -> String {
        let base = String(root.lastPathComponent.prefix(60))
        var name = base, n = 2
        while grants.contains(where: { $0.name == name }) || bookmarks[name] != nil { name = "\(base) \(n)"; n += 1 }
        return name
    }

    private static func canonical(_ url: URL) -> URL? {
        guard let path = realpath(url.path, nil) else { return nil }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private func validate(_ scope: ChilkFileScope, url: URL) throws -> URL {
        guard url.isFileURL, let root = Self.canonical(url) else { throw AccessError.invalidFolder }
        guard ChilkFileToolExecutor.allowedRoot(root, within: allowedContainer, home: home) else { throw AccessError.invalidFolder }
        // Never the whole home folder, anything above it, or a top-level folder of the disk (decision 2026-10-05).
        let parts = root.pathComponents.filter { $0 != "/" }
        let homeParts = home.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, !homeParts.starts(with: parts) else { throw AccessError.tooBroad }
        var info = stat(), current = "/"
        let trustedCount = allowedContainer.pathComponents.filter { $0 != "/" }.count
        let cloud = ChilkFileToolExecutor.cloudPassage(parts, home: home)       // iCloud / CloudStorage under ~/Library
        for (index, component) in parts.enumerated() {
            current = (current as NSString).appendingPathComponent(component)
            if index < trustedCount || cloud.contains(index) { continue }
            guard lstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_flags & UInt32(UF_HIDDEN) == 0 else { throw AccessError.invalidFolder }
        }
        if scope == .obsidian {
            let marker = root.appendingPathComponent(".obsidian")
            guard lstat(marker.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw AccessError.invalidVault }
        }
        return root
    }
}
