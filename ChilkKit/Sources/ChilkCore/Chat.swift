import Foundation

// Slice 5b (SPEC «Срез 5», decisions 10–14): one chat log for voice and text. A chat is a session of the shared
// Codex thread; voice is kept as text only. The log never holds audio, and Codex keeps nothing — deleting a chat
// here deletes the only copy.

/// One action under an answer, without content (decision 14). The app turns it into words and an icon.
public struct ChatChip: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case timer, cancelTimer, reminder, webSearch, findFiles, readFile, requestFolder, mode, water, takeBreak, remember
        /// Slice 8d: opened Clock (cancel / pause / resume a Clock timer there).
        case openClock
        /// Slice 8e: an event for Chilk's «Чилк» calendar (only a failed proposal is a chip; the card shows the rest).
        case event
        /// Slice 8f: a note for Chilk's «Чилк» folder (only a failed proposal is a chip; the card shows the rest).
        case note
        /// Slice 4b: a persuaded deferral, the focus mode on, the focus ended early.
        case deferRequest, focus, endFocus
        /// Slice 6d: hid behind the screen edge / came back out (`subject` = "hidden" / "shown").
        case hide
        /// Slice 7a: opened the notebook with a game (`subject` = the game's raw value, e.g. "tictactoe").
        case game
    }
    public var kind: Kind
    /// What it was about: a timer's title, a file's name, a mode, a break — never what a file or page said.
    public var subject: String?
    public var minutes: Int?
    public var at: Date?
    public var failed: Bool

    public init(kind: Kind, subject: String? = nil, minutes: Int? = nil, at: Date? = nil, failed: Bool = false) {
        self.kind = kind
        self.subject = subject
        self.minutes = minutes
        self.at = at
        self.failed = failed
    }
}

public struct ChatTurn: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, chilk }
    /// How the question came: by voice (heard and kept as text) or typed in the chat window.
    public enum Via: String, Codable, Sendable { case voice, text }

    public var id: UUID
    public var role: Role
    public var via: Via
    public var text: String
    public var at: Date
    public var chips: [ChatChip]

    public init(id: UUID = UUID(), role: Role, via: Via, text: String, at: Date, chips: [ChatChip] = []) {
        self.id = id
        self.role = role
        self.via = via
        self.text = text
        self.at = at
        self.chips = chips
    }
}

public struct ChatSession: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var started: Date
    public var lastActive: Date
    public var turns: [ChatTurn]

    public static let titleLength = 40

    /// The first thing the user said, on one line, at most 40 characters.
    public var title: String {
        let first = turns.first { $0.role == .user }?.text ?? ""
        let line = first.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > Self.titleLength ? String(line.prefix(Self.titleLength)) + "…" : line
    }
}

public struct ChatLog: Codable, Equatable, Sendable {
    /// Newest activity first.
    public private(set) var sessions: [ChatSession] = []
    /// Inactive chats go after this many days (decision 11: 1 / 7 / 30, `nil` = never; default 7).
    public var autoDeleteDays: Int? = 7
    /// Which chat each live Codex thread writes to. Threads are ephemeral, so this is never saved.
    private var threads: [String: UUID] = [:]

    public static let seedTurns = 20
    public static let seedTurnLength = 500

    private enum CodingKeys: String, CodingKey { case sessions, autoDeleteDays }

    public init() {}

    public func session(_ id: UUID) -> ChatSession? { sessions.first { $0.id == id } }

    /// The chat the live thread `thread` writes to, if any.
    public func session(forThread thread: String) -> ChatSession? { threads[thread].flatMap(session) }

    /// One exchange: the question and Chilk's answer (with its chips). Same thread → same chat; a fresh thread
    /// continuing the chat the user picked → that chat (decision 12); otherwise a new chat. Returns the chat's id.
    @discardableResult
    public mutating func record(question: String, answer: String, via: ChatTurn.Via, chips: [ChatChip], thread: String,
                                continuing: UUID?, at: Date) -> UUID {
        let id: UUID
        if let known = threads[thread], session(known) != nil {
            id = known
        } else if let continuing, session(continuing) != nil {
            id = continuing
        } else {
            id = UUID()
            sessions.append(ChatSession(id: id, started: at, lastActive: at, turns: []))
        }
        threads[thread] = id
        append(question: question, answer: answer, via: via, chips: chips, to: id, at: at)
        return id
    }

    /// A pair that never went to Codex (6b: lying, he does not talk): into the chat the user picked, else a new one.
    /// No thread is mapped — the next real turn picks its thread as usual (`plan`).
    public mutating func recordLocal(question: String, answer: String, via: ChatTurn.Via, continuing: UUID?,
                                     at: Date) -> UUID {
        let id: UUID
        if let continuing, session(continuing) != nil {
            id = continuing
        } else {
            id = UUID()
            sessions.append(ChatSession(id: id, started: at, lastActive: at, turns: []))
        }
        append(question: question, answer: answer, via: via, chips: [], to: id, at: at)
        return id
    }

    private mutating func append(question: String, answer: String, via: ChatTurn.Via, chips: [ChatChip], to id: UUID,
                                 at: Date) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].turns.append(ChatTurn(role: .user, via: via, text: Self.clean(question), at: at))
        sessions[index].turns.append(ChatTurn(role: .chilk, via: via, text: answer.trimmingCharacters(in: .whitespacesAndNewlines),
                                              at: at, chips: chips))
        sessions[index].lastActive = at
        sessions.sort { $0.lastActive > $1.lastActive }
    }

    public mutating func delete(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        threads = threads.filter { $0.value != id }
    }

    /// Where a typed question goes (decision 12).
    public struct Plan: Equatable, Sendable {
        /// Start a clean thread even within 15 minutes.
        public var fresh: Bool
        /// What a clean thread hears first; ignored when the live thread goes on.
        public var seed: String?
        /// The chat the answer is written to (`nil` = the thread's own chat, or a new one).
        public var continuing: UUID?
    }

    /// The picked chat is the live thread's → that thread goes on (with the seed in case it ran out meanwhile); another
    /// chat → a clean thread that first hears it as text; nothing picked → the shared thread decides.
    public func plan(picked: UUID?, liveThread: String?) -> Plan {
        guard let picked, session(picked) != nil else { return Plan(fresh: false, seed: nil, continuing: nil) }
        let liveChat = liveThread.flatMap { session(forThread: $0)?.id }
        return Plan(fresh: liveChat != picked, seed: seed(for: picked), continuing: picked)
    }

    /// Removes chats inactive for longer than `autoDeleteDays`; returns how many went.
    @discardableResult
    public mutating func purge(now: Date) -> Int {
        guard let days = autoDeleteDays else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 3600)
        let gone = sessions.filter { $0.lastActive < cutoff }.map(\.id)
        for id in gone { delete(id) }
        return gone.count
    }

    /// What a fresh thread gets before the user's next words when an old chat is continued: the last 20 turns as
    /// plain text, each at most 500 characters, without chips.
    public func seed(for id: UUID) -> String {
        guard let s = session(id) else { return "" }
        let lines = s.turns.suffix(Self.seedTurns).map { turn -> String in
            let who = turn.role == .user ? "Пользователь" : "Чилк"
            var text = turn.text.split(whereSeparator: \.isNewline).joined(separator: " ")
            if text.count > Self.seedTurnLength { text = String(text.prefix(Self.seedTurnLength)) + "…" }
            return "\(who): \(text)"
        }
        return (["[переписка ранее]"] + lines + ["[конец переписки]"]).joined(separator: "\n")
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
