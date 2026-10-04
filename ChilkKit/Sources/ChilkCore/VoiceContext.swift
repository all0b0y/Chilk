import Foundation

public enum VoiceContext {
    /// No app/window names, documents or transcript history; explicit date and timezone prevent relative-date guesses.
    public static func text(sittingMinutes: Int, now: Date = Date(), zone: TimeZone = .autoupdatingCurrent) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = zone
        return "[контекст: сейчас \(f.string(from: now)); timezone \(zone.identifier); пользователь за Mac без перерыва \(max(0, sittingMinutes)) мин]\n"
    }
}
