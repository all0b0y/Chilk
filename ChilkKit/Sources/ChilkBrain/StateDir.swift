import Foundation

/// Acceptance runs keep all their state in CHILK_STATE_DIR. Only a set, non-empty value isolates a run — the state
/// directory follows it, and demo hooks act only then; an empty value is the user's own state (review 2026-10-08).
public enum StateDir {
    public static func isolated(in environment: [String: String]) -> URL? {
        guard let path = environment["CHILK_STATE_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
