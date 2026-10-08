import Foundation

/// Slice 6c (decision 12): what Codex may show with Chilk's body. Needs and states (tired posture, eye bags, the stretch
/// hops, «лежит», sleep) are not here — one signal, one meaning. Slice 9 (decision 34): «удивление» (`surprised`) and
/// «смущение» (`shy`).
public enum Emotion: String, CaseIterable, Sendable, Codable {
    case cheer, laugh, clown, offended, dizzy, sad, surprised, shy
}

/// What is kept between launches: when the clown was last shown (decision 13).
public struct EmoteBook: Codable, Equatable, Sendable {
    public var clownAt: Date?
    public init(clownAt: Date? = nil) { self.clownAt = clownAt }

    /// A missing or damaged file means «never»: the clown is allowed, nothing crashes.
    public static func load(from url: URL) -> EmoteBook {
        guard let data = try? Data(contentsOf: url) else { return EmoteBook() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(EmoteBook.self, from: data)) ?? EmoteBook()
    }

    public func save(to url: URL) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: url, options: .atomic)
    }
}

/// The limits of `chilk_emote` in code (decisions 11, 13): one CALL per answer — a refusal uses it too, so a resting
/// clown is never swapped for another emotion — and the clown at most once in 14 days. A busy Chilk plays nothing and
/// does not spend the clown.
public struct EmoteGate: Sendable {
    public enum Verdict: Equatable, Sendable {
        case play
        case onePerAnswer
        case clownResting(until: Date)
        case busy
    }

    public static let clownRest: TimeInterval = 14 * 24 * 3600

    public private(set) var book: EmoteBook
    private var usedTurns: [String] = []

    public init(book: EmoteBook = EmoteBook()) { self.book = book }

    public mutating func request(_ e: Emotion, turn: String, now: Date, stageFree: Bool) -> Verdict {
        guard !usedTurns.contains(turn) else { return .onePerAnswer }
        usedTurns.append(turn)
        if usedTurns.count > 32 { usedTurns.removeFirst(usedTurns.count - 32) }
        if e == .clown, let last = book.clownAt, now < last + Self.clownRest {
            return .clownResting(until: last + Self.clownRest)
        }
        guard stageFree else { return .busy }
        if e == .clown { book.clownAt = now }
        return .play
    }
}
