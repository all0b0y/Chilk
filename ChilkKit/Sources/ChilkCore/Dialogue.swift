import Foundation

/// Dialogue rules (decided 2026-10-04): Codex tags every reply, Чилк keeps listening for a while after it,
/// a short pause continues the same conversation, a long one starts clean.
public enum ReplyMode: String, Sendable, Equatable, CaseIterable {
    /// He asked something or wants a confirmation — waits longest.
    case question
    /// An ordinary answer.
    case answer
    /// A request was carried out — a short window for «а ещё…».
    case done
    /// The user said thanks / bye — reply is a farewell, no window.
    case end
}

/// Where a conversation is.
public enum DialoguePhase: Sendable, Equatable {
    case idle
    /// Ears up, the user is (about to start) talking.
    case listening
    /// After his reply: ears up, waiting for a follow-up; nothing said yet.
    case waiting
    case thinking
    case answering
}

/// What a press or a click means right now.
public enum DialogueCommand: Sendable, Equatable {
    case startListening
    /// «I'm done talking» — send what was heard.
    case doneTalking
    /// Back to the edge without a word.
    case leaveQuietly
    /// Stop the answer and listen to a correction (same thread, context kept).
    case interruptAndListen
    /// Stop everything: «Ладно, проехали».
    case cancel
}

public enum Dialogue {
    /// ⌃⌥Space (decided 2026-10-04, questions 3 and 5).
    public static func hotkey(_ phase: DialoguePhase) -> DialogueCommand {
        switch phase {
        case .idle: .startListening
        case .listening: .doneTalking
        case .waiting: .leaveQuietly
        case .thinking, .answering: .interruptAndListen
        }
    }

    /// A click on Чилк. `nil` = not about the conversation (a balance poke).
    public static func click(_ phase: DialoguePhase) -> DialogueCommand? {
        switch phase {
        case .idle: nil
        case .listening: .doneTalking
        case .waiting: .leaveQuietly
        case .thinking, .answering: .cancel
        }
    }

    /// Seconds to keep listening after a reply: time to read it (≈14 chars/s, at least 2 s) + slack by mode.
    /// `nil` = do not listen (the conversation is over).
    public static func followUpWindow(mode: ReplyMode, replyLength: Int) -> TimeInterval? {
        let reading = max(2, Double(replyLength) / 14)
        switch mode {
        case .question: return reading + 10
        case .answer: return reading + 6
        case .done: return reading + 4
        case .end: return nil
        }
    }

    /// Slice 9, decision 8 (was: `followUpWindow(.question, 0)` ≈ 12 s — gone before the card was read): after a
    /// confirmation card appears he listens for «да / нет / поправка» without his name this long.
    public static let cardAnswerWindow: TimeInterval = 60

    /// Time to read a reply before he goes back to the edge.
    public static func readingTime(_ replyLength: Int) -> TimeInterval { 2.5 + Double(replyLength) / 14 }

    /// Longer replies do not fit a bubble (decision 2026-10-05): the bubble shows the start + «Подробнее».
    public static let bubbleLimit = 240

    /// What the bubble shows of a reply: all of it, or its start cut at a word with «…».
    public static func preview(_ text: String) -> (text: String, isCut: Bool) {
        guard text.count > bubbleLimit else { return (text, false) }
        let head = text.prefix(bubbleLimit - 40)
        let cut = head.lastIndex(where: \.isWhitespace).map { head[..<$0] } ?? head
        let tidy = cut.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return (tidy + "…", true)
    }

    /// A new call continues the previous conversation if it ended less than this ago.
    public static let continueWithin: TimeInterval = 15 * 60

    public static func continues(lastExchange: Date?, now: Date) -> Bool {
        guard let last = lastExchange else { return false }
        return now.timeIntervalSince(last) < continueWithin
    }

    /// JSON Schema for Codex's structured reply (`outputSchema` of `turn/start`). `reply` first: it streams first.
    public static var schema: [String: Any] {
        [
        "type": "object",
        "properties": [
            "reply": ["type": "string"],
            "mode": ["type": "string", "enum": ReplyMode.allCases.map(\.rawValue)],
        ],
        "required": ["reply", "mode"],
        "additionalProperties": false,
        ]
    }

    /// Bubbles show plain text: markdown links become their text (+ the site), emphasis marks go away.
    public static func plain(_ text: String) -> String {
        var s = text
        if let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\((https?://)?(www\.)?([^/)\s]+)[^)]*\)"#) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1 ($4)")
        }
        for mark in ["**", "__", "`"] { s = s.replacingOccurrences(of: mark, with: "") }
        return withoutEmoji(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Emoji are Chilk's own canned-line flavour, not something the model sprinkles into replies (2026-10-04).
    /// Whole grapheme clusters go (ZWJ families, skin tones, flags, keycaps); text symbols such as © № ° → stay.
    static func withoutEmoji(_ text: String) -> String {
        let kept = text.filter { character in
            let scalars = character.unicodeScalars
            let presentation = scalars.contains { $0.properties.isEmojiPresentation }
            let styled = scalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 }
                && scalars.contains { $0.properties.isEmoji }
            return !(presentation || styled)
        }
        guard kept.count != text.count else { return text }
        // Tidy the gap an emoji leaves: no doubled spaces, no space before punctuation; newlines stay.
        var tidy = kept.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        tidy = tidy.replacingOccurrences(of: #"[ \t]+([,.!?…:;])"#, with: "$1", options: .regularExpression)
        tidy = tidy.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        return tidy
    }

    /// The final message: `{"reply": …, "mode": …}`. A model that ignored the schema still gets through:
    /// plain text becomes the reply, and a trailing «?» means it asked something.
    public static func parse(_ message: String) -> (reply: String, mode: ReplyMode) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = jsonObjectText(trimmed).data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let reply = object["reply"] as? String {
            let mode = (object["mode"] as? String).flatMap(ReplyMode.init(rawValue:)) ?? .answer
            return (reply.trimmingCharacters(in: .whitespacesAndNewlines), mode)
        }
        return (trimmed, trimmed.hasSuffix("?") ? .question : .answer)
    }

    /// The reply text so far while the JSON is still streaming in (`{"reply":"Прив` → «Прив»).
    /// Not JSON at all → the text itself.
    public static func partialReply(_ streamed: String) -> String {
        let s = streamed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("{") || s.hasPrefix("```") else { return s }
        guard let key = s.range(of: "\"reply\"") else { return "" }
        var i = key.upperBound
        while i < s.endIndex, s[i] == " " || s[i] == ":" || s[i] == "\n" { i = s.index(after: i) }
        guard i < s.endIndex, s[i] == "\"" else { return "" }
        i = s.index(after: i)
        var out = ""
        var escaped = false
        while i < s.endIndex {
            let c = s[i]
            if escaped {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "u":
                    let hex = s[s.index(after: i)...].prefix(4)
                    if hex.count == 4, let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                        out.unicodeScalars.append(scalar)
                        i = s.index(i, offsetBy: 4)
                    } else {
                        return out                                   // \u split across deltas: wait for the rest
                    }
                default: out.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                break
            } else {
                out.append(c)
            }
            i = s.index(after: i)
        }
        return out
    }

    private static func jsonObjectText(_ s: String) -> String {
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end else { return s }
        return String(s[start...end])
    }
}
