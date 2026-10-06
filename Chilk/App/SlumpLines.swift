import Foundation

/// «Лежит» (slice 6b, decisions 8–9): the user's own words for him, and the little shake-up at the edge.
extension Lines {
    static let slumpHelp = String(localized: "Помоги мне… сделай хоть что-нибудь")
    static let slumpLater = String(localized: "Сделаешь — поговорим потом")
    /// What he answers to a call or a chat message while he lies (no Codex).
    static var slumpRefusal: String { [slumpHelp, slumpLater].randomElement()! }
    static let slumpDrank = String(localized: "Попил")
    static let slumpShake = String(localized: "Встряхнуться")
    static let roseUp = String(localized: "Ох… спасибо. Уже лучше")
    /// «Встряхнуться»: three moves at the edge, ~8 s each.
    static let shakeSteps = [String(localized: "Покрути плечами"), String(localized: "Потянись вверх"),
                             String(localized: "Встряхни руками")]
    static func shakeStep(_ text: String, seconds: Int) -> String { "\(text) · \(seconds)" }
}
