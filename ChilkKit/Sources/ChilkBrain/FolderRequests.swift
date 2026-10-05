import Foundation

/// «Можно я загляну в …?» (decision 2026-10-05). Chilk may ask for read-only access to a folder the user named;
/// «Да» shares it at once, «Нет» is remembered until restart, no answer within the wait is a «нет» for now.
/// Never the whole home folder, the disk root, hidden or system folders — the store's own checks decide that.
@MainActor
public final class FolderRequests {
    public enum Outcome: Equatable, Sendable {
        case granted(FolderGrant), already(FolderGrant), declined, noAnswer, notAllowed
    }

    private var declined: Set<String> = []
    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL
    }

    /// `~/x` → the home folder's x; anything else as an absolute path.
    public static func resolve(_ path: String, home: URL) -> URL {
        let url = path.hasPrefix("~/") ? home.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
                                       : URL(fileURLWithPath: path, isDirectory: true)
        return url.standardizedFileURL
    }

    /// What the user sees: «Документы/Работа» (Finder's localized names, relative to home), else the full path.
    public static func display(_ url: URL, home: URL) -> String {
        let parts = url.standardizedFileURL.pathComponents, homeParts = home.standardizedFileURL.pathComponents
        guard parts.starts(with: homeParts), parts.count > homeParts.count else { return url.path }
        var current = home.standardizedFileURL
        return parts.dropFirst(homeParts.count).map { part in
            current.appendPathComponent(part)
            return FileManager.default.displayName(atPath: current.path)
        }.joined(separator: "/")
    }

    /// - Parameters: `check` — the store's validation (canonical folder or throws); `ask` — the Да/Нет bubble
    ///   (`nil` = no answer); `add` — share the folder.
    public func run(path: String, grants: [FolderGrant],
                    check: (URL) async throws -> URL,
                    ask: (URL) async -> Bool?,
                    add: (URL) async throws -> FolderGrant) async -> Outcome {
        let wanted = Self.resolve(path, home: home)
        guard let root = try? await check(wanted) else { return .notAllowed }
        if let grant = grants.first(where: { $0.root.path == root.path }) { return .already(grant) }
        guard !declined.contains(root.path) else { return .declined }
        switch await ask(root) {
        case .some(true):
            guard let grant = try? await add(root) else { return .notAllowed }
            return .granted(grant)
        case .some(false):
            declined.insert(root.path)
            return .declined
        case .none:
            return .noAnswer
        }
    }

    /// The tool result Codex reads.
    public static func result(_ outcome: Outcome) -> JSON {
        switch outcome {
        case .granted(let g): ["granted": true, "folder": .string(g.name)]
        case .already(let g): ["granted": true, "folder": .string(g.name), "alreadyShared": true]
        case .declined: ["granted": false, "reason": "declined_by_user"]
        case .noAnswer: ["granted": false, "reason": "no_answer"]
        case .notAllowed: ["granted": false, "reason": "not_allowed_or_missing"]
        }
    }
}
