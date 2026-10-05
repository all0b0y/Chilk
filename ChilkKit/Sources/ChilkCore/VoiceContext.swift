import Foundation

public enum VoiceContext {
    /// No app/window names, documents or transcript history; explicit date and timezone prevent relative-date guesses.
    /// The user's name (slice 5a) is the one they gave Chilk, so he can address them.
    public static func text(sittingMinutes: Int, now: Date = Date(), zone: TimeZone = .autoupdatingCurrent,
                            name: String? = nil) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = zone
        let who = name.flatMap(UserProfile.cleanName).map { "; пользователя зовут \($0)" } ?? ""
        return "[контекст: сейчас \(f.string(from: now)); timezone \(zone.identifier); пользователь за Mac без перерыва \(max(0, sittingMinutes)) мин\(who)]\n"
    }
}
