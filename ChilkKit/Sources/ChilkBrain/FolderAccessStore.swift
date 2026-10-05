import Darwin
import Foundation

/// Explicit user choices only. No environment variables, discovery of vaults, or inherited agent access.
public actor FolderAccessStore {
    public enum AccessError: Error { case invalidFolder, invalidVault, corruptStore }
    public private(set) var roots: [ChilkFileScope: URL] = [:]
    private var bookmarks: [String: Data] = [:]
    private let file: URL
    private let allowedContainer: URL

    public init(file: URL, allowedContainer: URL = URL(fileURLWithPath: "/")) async throws {
        self.file = file
        self.allowedContainer = allowedContainer.standardizedFileURL
        try load()
    }

    private func load() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 16384 else { throw AccessError.corruptStore }
        bookmarks = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: file))
        guard Set(bookmarks.keys).isSubset(of: ["files", "obsidian"]) else { throw AccessError.corruptStore }
        for (key, data) in bookmarks {
            guard let scope = ChilkFileScope(rawValue: key) else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                     relativeTo: nil, bookmarkDataIsStale: &stale), !stale,
                  let root = try? Self.validate(scope, url: url, within: allowedContainer) else { continue }
            roots[scope] = root
        }
    }

    public func select(_ scope: ChilkFileScope, url: URL) throws {
        let root = try Self.validate(scope, url: url, within: allowedContainer)
        // Chilk is not App-Sandboxed: keep a persistent location without implicit, temporary scope escalation.
        let bookmark = try root.bookmarkData(options: [.withoutImplicitSecurityScope],
                                             includingResourceValuesForKeys: nil, relativeTo: nil)
        var candidate = bookmarks
        candidate[scope.rawValue] = bookmark
        try save(candidate)
        bookmarks = candidate
        roots[scope] = root
    }

    public func revoke(_ scope: ChilkFileScope) throws {
        var candidate = bookmarks
        candidate.removeValue(forKey: scope.rawValue)
        try save(candidate)
        bookmarks = candidate
        roots.removeValue(forKey: scope)
    }

    private func save(_ candidate: [String: Data]) throws {
        let data = try JSONEncoder().encode(candidate)
        guard data.count <= 16384 else { throw AccessError.corruptStore }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    private static func validate(_ scope: ChilkFileScope, url: URL, within container: URL) throws -> URL {
        guard url.isFileURL, let canonical = realpath(url.path, nil) else { throw AccessError.invalidFolder }
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        guard ChilkFileToolExecutor.allowedRoot(root, within: container) else { throw AccessError.invalidFolder }
        var info = stat(), current = "/"
        let trustedCount = container.pathComponents.filter { $0 != "/" }.count
        for (index, component) in root.pathComponents.filter({ $0 != "/" }).enumerated() {
            current = (current as NSString).appendingPathComponent(component)
            if index < trustedCount { continue }
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
