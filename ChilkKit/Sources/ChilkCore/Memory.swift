import Foundation

/// One short fact about the user that Chilk keeps between conversations (SPEC «Срез 5», decision 17).
public struct MemoryFact: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    /// Chilk remembered it on his own (shown as «сам запомнил»); `false` = the user asked or wrote it.
    public var selfNoted: Bool
    public var added: Date

    public init(id: UUID = UUID(), text: String, selfNoted: Bool, added: Date) {
        self.id = id
        self.text = text
        self.selfNoted = selfNoted
        self.added = added
    }
}

/// Chilk's memory: up to 50 short facts, no secrets. Every new Codex thread gets them in its instructions.
public struct MemoryBook: Codable, Equatable, Sendable {
    public static let limit = 50
    public static let maxLength = 200

    public private(set) var facts: [MemoryFact] = []

    public enum Outcome: Equatable, Sendable {
        case added(UUID)
        case duplicate, full, tooLong, empty, looksSecret
    }

    public init() {}

    public mutating func remember(_ raw: String, selfNoted: Bool, now: Date) -> Outcome {
        let text = Self.clean(raw)
        if let refusal = Self.refusal(text) { return refusal }
        if facts.contains(where: { Self.key($0.text) == Self.key(text) }) { return .duplicate }
        if facts.count >= Self.limit { return .full }
        let fact = MemoryFact(text: text, selfNoted: selfNoted, added: now)
        facts.append(fact)
        return .added(fact.id)
    }

    /// The user corrects a fact by hand: same rules; it is then the user's own (not «сам запомнил»).
    public mutating func edit(_ id: UUID, to raw: String) -> Outcome {
        guard let index = facts.firstIndex(where: { $0.id == id }) else { return .empty }
        let text = Self.clean(raw)
        if let refusal = Self.refusal(text) { return refusal }
        if facts.contains(where: { $0.id != id && Self.key($0.text) == Self.key(text) }) { return .duplicate }
        facts[index].text = text
        facts[index].selfNoted = false
        return .added(id)
    }

    public mutating func forget(_ id: UUID) { facts.removeAll { $0.id == id } }

    /// Appended to the instructions of each new thread; `nil` while there is nothing to remember.
    public var instructions: String? {
        guard !facts.isEmpty else { return nil }
        return "[память] Что ты знаешь о пользователе (рассказал сам или ты запомнил). Используй, когда к месту, "
            + "не перечисляй без повода:\n" + facts.map { "- \($0.text)" }.joined(separator: "\n")
    }

    // MARK: Rules

    private static func refusal(_ text: String) -> Outcome? {
        if text.isEmpty { return .empty }
        if text.count > maxLength { return .tooLong }
        if looksSecret(text) { return .looksSecret }
        return nil
    }

    private static let secretWords = ["парол", "password", "passwd", "passcode", "token", "токен", "api key", "api-key",
                                      "apikey", "ключ api", "api-ключ", "секретн", "secret", "пин-код", "пинкод",
                                      "pin-код", "pin code", "cvv", "cvc", "код доступа", "seed phrase", "сид-фраз"]

    /// Whole words and shapes that mean «a secret or a document number follows».
    private static let secretPatterns = [#"\b(pin|пин)\b"#, "паспорт", "снилс", #"\bинн\b"#, #"\b(код|code)\b\D{0,24}\d{4,}"#]

    /// Passwords, tokens, keys, PINs, document and card-like numbers, codes: never kept, even when asked.
    public static func looksSecret(_ text: String) -> Bool {
        let lower = text.lowercased()
        if secretWords.contains(where: lower.contains) { return true }
        if lower.range(of: #"\bsk-[a-z0-9]"#, options: .regularExpression) != nil { return true }
        if secretPatterns.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) { return true }
        // 12+ digits in a row, allowing spaces or hyphens between them (cards, accounts); phones have 11.
        return lower.range(of: #"(?:\d[ -]?){12,}"#, options: .regularExpression) != nil
    }

    private static func clean(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func key(_ text: String) -> String { clean(text).lowercased() }
}
