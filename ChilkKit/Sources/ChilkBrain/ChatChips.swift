import ChilkCore
import Foundation

/// Slice 5b, decision 14: what Chilk did during a turn, as chips under his answer — the kind and its subject
/// (a timer's title, a file's name), never what a file or a web page said. Looking (status, lists) is not a chip.
public enum ChatChips {
    public static func chip(name: String, arguments: JSON, result: CodexToolResult) -> ChatChip? {
        guard let kind = kind(of: name) else { return nil }
        // Slice 8c: a proposal is not a deed — the card itself shows in the chat until it is answered.
        if result.value["awaiting_confirmation"]?.bool == true { return nil }
        // 6d+: «в 3 — ночи или дня?» is a question, not a failure: no red chip for it.
        if !result.success, result.value["error"]?.string?.hasPrefix("ambiguous_") == true { return nil }
        var chip = ChatChip(kind: kind, failed: !result.success || didNothing(result.value))
        guard let action = try? ChilkToolCatalog.parse(name: name, arguments: arguments) else { return chip }
        switch action {
        case .timer(let seconds, let title):
            chip.subject = clean(title)
            chip.minutes = max(1, Int((Double(seconds) / 60).rounded()))
        case .schedule(let at, let title, _):
            chip.subject = clean(title)
            chip.at = at
        case .reminder(let title, let at):
            chip.subject = clean(title)
            chip.at = at
        case .event(let title, let at, _, _):
            chip.subject = clean(title)
            chip.at = at
        case .readFile(_, let path):
            chip.subject = path.split(separator: "/").last.map(String.init)
        case .requestFolder(let path, _):
            chip.subject = path.split(separator: "/").last.map(String.init)
        case .mode(let mode):
            chip.subject = mode.rawValue
        case .deferRequest(let asked):
            guard !chip.failed else { break }
            chip.subject = result.value["need"]?.string
            if case .number(let granted)? = result.value["minutes"] { chip.minutes = Int(granted) } else { chip.minutes = asked }
        case .focus:
            guard !chip.failed else { break }
            chip.at = result.value["until"]?.string.flatMap { ChilkToolCatalog.timestamp($0) }
        case .hide(let hidden):
            chip.subject = hidden ? "hidden" : "shown"
        case .game(let kind, _):
            chip.subject = result.value["game"]?.string ?? kind?.rawValue
        case .takeBreak(let b):
            switch b {
            case .eyeGym: chip.subject = "eyeGym"
            case .warmup: chip.subject = "warmup"
            case .walk: chip.subject = "walk"
            case .breathe(let minutes):
                chip.subject = "breathe"
                chip.minutes = minutes
            }
        default:
            break
        }
        return chip
    }

    /// Codex's own web search, seen as an `item/completed` notification with a `webSearch` item.
    public static func webSearch(_ params: JSON) -> ChatChip? {
        params["item"]?["type"]?.string == "webSearch" ? ChatChip(kind: .webSearch) : nil
    }

    /// A call that went through but did nothing: water not credited, nothing cancelled, a softer mode or a break refused.
    private static func didNothing(_ value: JSON) -> Bool {
        value["credited"]?.bool == false || value["cancelled"]?.bool == false || value["willStart"]?.bool == false
            || value["refused"] != nil || value["deferred"]?.bool == false || value["focus"]?.bool == false
            || value["ended"]?.bool == false || value["changed"]?.bool == false
    }

    private static func kind(of name: String) -> ChatChip.Kind? {
        switch name {
        case "chilk_timer", "chilk_schedule": .timer
        case "chilk_cancel_timer": .cancelTimer
        case "chilk_clock_open": .openClock
        case "chilk_reminder": .reminder
        case "chilk_event": .event
        case "chilk_find_files": .findFiles
        case "chilk_read_file": .readFile
        case "chilk_request_folder": .requestFolder
        case "chilk_mode": .mode
        case "chilk_water": .water
        case "chilk_eye_gym", "chilk_warmup", "chilk_walk", "chilk_breathe": .takeBreak
        case "chilk_remember": .remember
        case "chilk_defer": .deferRequest
        case "chilk_focus": .focus
        case "chilk_end_focus": .endFocus
        case "chilk_hide": .hide
        case "chilk_game": .game
        default: nil
        }
    }

    private static func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
