import AppKit
import ChilkCore
import ChilkApple
import ChilkBrain

/// Test state is separate from both personal balance aggregates and the official Chilk Codex login.
enum AppState {
    static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["CHILK_STATE_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return CodexSetup.defaultDataDir
    }
}

@MainActor
final class Actions {
    let executor: ChilkToolExecutor?
    let files: Files
    private let reminders = ChilkReminderExecutor(store: ProcessInfo.processInfo.environment["CHILK_FAKE_REMINDERS"] != nil
                                                  ? FakeReminders() : EventKitReminders())
    private weak var balance: BalanceController?
    private let sim: CharacterSim
    private var timer: Timer?
    private var display = NoticeDisplay()
    /// A timer whose «seen» could not be saved is not shown again in this run (no show/hide loop).
    private var unsaved: Set<String> = []
    private var reportedFailure = false
    /// Set by the app: a conversation owns the stage (a due bubble waits, or comes back after it).
    var conversationActive: () -> Bool = { false }
    /// Tray → Tools (slice 5a): a switched-off tool is refused even on a thread that still lists it.
    var switches: () -> ToolSwitches = { ToolSwitches() }
    /// A timer fell due: the tray icon wiggles once (was the Dock bounce).
    var onDue: () -> Void = {}
    var ownsStage: Bool { display.showing != nil }
    /// A due timer is on screen or waits to be seen (the dot on the tray icon).
    var noticeWaiting: Bool { display.showing != nil || !(executor?.ready.isEmpty ?? true) }

    init(balance: BalanceController, sim: CharacterSim, files: Files? = nil) {
        self.balance = balance
        self.sim = sim
        self.files = files ?? Files(file: AppState.directory.appendingPathComponent("folders.json"))
        do {
            executor = try ChilkToolExecutor(file: AppState.directory.appendingPathComponent("timers.json"),
                status: { [weak balance] in
                    guard let balance else { return [:] }
                    return ["sittingMinutes": .number(Double(balance.sittingMinutes)),
                            "waterPressure": .number(balance.engine.pressure(.water)),
                            "mode": .string(balance.mode.rawValue)]
                }, water: { [weak balance] in
                    guard let balance else { throw CodexClient.ClientError.notStarted }
                    return try balance.creditWaterFromVoice()
                        ? ["credited": true]
                        : ["credited": false, "reason": "less_than_20_minutes_since_last_glass"]
                }, mode: { [weak balance] mode in
                    guard let balance else { return ["changed": false] }
                    // The conversation owns the stage: the change is applied and saved, he says it himself.
                    let changed = balance.setMode(mode)
                    return changed
                        ? ["mode": .string(balance.mode.rawValue), "changed": true]
                        : ["mode": .string(balance.mode.rawValue), "changed": false, "refused": "escalation_in_progress"]
                }, breaks: { [weak balance] b in
                    balance?.queueBreak(b) ?? ["willStart": false]
                }, persuade: { [weak balance] m in
                    balance?.persuade(minutes: m) ?? ["deferred": false]
                }, focus: { [weak balance] m in
                    balance?.focusFromConversation(minutes: m) ?? ["focus": false]
                }, endFocus: { [weak balance] in
                    ["ended": .bool(balance?.endFocus() ?? false)]
                }, hide: { [weak balance] hidden in
                    balance?.hideout?.request(hidden) ?? ["changed": false]
                }, game: { [gameRelay] kind, length in
                    gameRelay.open(kind, length)
                })
        } catch {
            executor = nil
            reportedFailure = true
            balance.log("tools timer store unavailable")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.1
    }

    func execute(_ call: CodexToolCall) async -> CodexToolResult {
        let result = await run(call)
        // Slice 5b, decision 14: what was done, as a chip under the answer (refusals and failures in red).
        if let chip = ChatChips.chip(name: call.name, arguments: call.arguments, result: result) { onChip(call.threadId, chip) }
        return result
    }

    /// Slice 7a: `chilk_game` → the notebook (set by the app). A relay object: the executor is built in `init`, before
    /// `self` may be captured.
    final class GameRelay {
        var open: (GameKind?, Int?) -> CodexToolResult = { _, _ in .failure("Games unavailable") }
    }
    private let gameRelay = GameRelay()
    var openGame: (GameKind?, Int?) -> CodexToolResult {
        get { gameRelay.open }
        set { gameRelay.open = newValue }
    }
    /// Chips of the turn in flight, by thread (set by the app: the chat collects them).
    var onChip: (String, ChatChip) -> Void = { _, _ in }
    /// Chilk's memory (slice 5b, decision 17).
    var memory: MemoryStore?
    /// Slice 6c (decisions 11–13): the limits of `chilk_emote`; the clown's date is kept in `emotes.json`.
    private var emotes = EmoteGate(book: EmoteBook.load(from: Actions.emotesFile))
    private static var emotesFile: URL { AppState.directory.appendingPathComponent("emotes.json") }
    /// Set by the app: Chilk can show an emotion right now (thinking in a conversation, or posing for a chat turn).
    var canEmote: () -> Bool = { false }
    /// Set by the app: show it (he comes out from behind the edge by himself).
    var playEmote: (Emotion, Bool) -> Void = { _, _ in }

    private func emote(_ call: CodexToolCall) -> CodexToolResult {
        guard case .emote(let e, let strong)? = try? ChilkToolCatalog.parse(name: call.name, arguments: call.arguments)
        else { return .failure(ChilkToolCatalog.explain(name: call.name, arguments: call.arguments)) }
        switch emotes.request(e, turn: call.turnId, now: Date(), stageFree: canEmote()) {
        case .play:
            if e == .clown {
                do { try emotes.book.save(to: Self.emotesFile) } catch { balance?.log("emote: clown date not saved") }
            }
            playEmote(e, strong)
            return .ok(["played": true])
        case .onePerAnswer:
            return .failure("one_per_answer: only one emotion per answer. Nothing was shown; just answer in words.")
        case .clownResting:
            return .failure("not_now: the clown is resting. Nothing was shown and no other emotion replaces it; "
                            + "just answer in words.")
        case .busy:
            return .failure("chilk_busy: Chilk cannot show it right now. Nothing was shown; just answer in words.")
        }
    }

    private func remember(_ call: CodexToolCall) -> CodexToolResult {
        guard case .remember(let fact, let asked)? = try? ChilkToolCatalog.parse(name: call.name, arguments: call.arguments)
        else { return .failure(ChilkToolCatalog.explain(name: call.name, arguments: call.arguments)) }
        guard let memory else { return .failure("Memory unavailable") }
        switch memory.remember(fact, selfNoted: !asked) {
        case .added: return .ok(["added": true, "facts": .number(Double(memory.book.facts.count))])
        case .duplicate: return .ok(["added": false, "duplicate": true])
        case .full: return .failure("memory_full: 50 facts; the user can remove some in the chat window → «Память»")
        case .tooLong: return .failure("too_long: one short fact, at most 200 characters")
        case .empty: return .failure("empty fact")
        case .looksSecret: return .failure("looks_secret: passwords, codes, keys and card numbers are never kept")
        }
    }

    /// Slice 8a (decision 14): `tools.log` — tool, outcome code, seconds; never names, times, paths or texts.
    private let journal = ToolJournal(url: AppState.directory.appendingPathComponent("tools.log"))

    private func run(_ call: CodexToolCall) async -> CodexToolResult {
        let started = Date()
        func record(_ outcome: ToolJournal.Outcome) {
            journal.write(ToolJournal.line(at: started, tool: call.name, outcome: outcome,
                                           seconds: Date().timeIntervalSince(started)))
        }
        let kinds = Dictionary(files.grants.map { ($0.name, $0.kind) }, uniquingKeysWith: { first, _ in first })
        if let off = ChilkToolCatalog.switchedOff(name: call.name, arguments: call.arguments, switches: switches(),
                                                  kindOf: { kinds[$0] }) {
            record(.refused("switched_off"))
            balance?.log("tool \(call.name) refused: \(off.rawValue) switched off")
            return .failure("Switched off by the user in Chilk's tray → Инструменты (\(off.rawValue)). Nothing was done; "
                            + "tell the user it is switched off there.")
        }
        let result: CodexToolResult
        if let refused = ClockCheck.refusal(for: call) {
            result = refused                                     // 6d+: «в 3» — ночи или дня? Ask first.
            record(.refused(ToolJournal.code(of: refused.value["error"]?.string ?? "")))
            return result
        } else if call.name == "chilk_remember" {
            result = remember(call)
        } else if call.name == "chilk_emote" {
            result = emote(call)
        } else if ChilkFileToolExecutor.handles(call.name) {
            result = await files.execute(call)
        } else if ChilkReminderExecutor.handles(call.name) {
            result = await reminders.execute(name: call.name, arguments: call.arguments)
        } else if let executor {
            result = executor.execute(name: call.name, arguments: call.arguments)
        } else {
            result = .failure("Chilk actions unavailable: timer storage could not be loaded")
        }
        record(result.success ? .ok : .failed(ToolJournal.code(of: result.value["error"]?.string ?? "")))
        balance?.log("tool \(call.name) success=\(result.success)"
                     + (result.success ? "" : " \(result.value["error"]?.string ?? "")"))
        return result
    }

    /// A click on Chilk while a due bubble is up closes it (`false` = not about a timer).
    func clicked() -> Bool {
        guard case .dismiss(let id) = display.clicked() else { return false }
        finish(id, how: "click")
        return true
    }

    private func tick() {
        guard let executor else { return }
        do {
            let due = try executor.collectDue()
            if !due.isEmpty {
                onDue()
                for entry in due { balance?.log("timer due \(entry.id)") }
            }
        } catch { reportFailure() }

        if display.showing != nil, conversationActive() {
            display.interrupted()                         // he talks now; the bubble returns afterwards, unseen
            balance?.log("timer interrupted by conversation")
            return
        }
        let signals = balance?.lastSignals
        let next = executor.ready.first { !unsaved.contains($0.id) }
        let canPresent = !conversationActive() && balance?.canPresentScheduledNotice == true
        switch display.step(now: ProcessInfo.processInfo.systemUptime, idle: signals?.idle ?? 0,
                            locked: signals?.locked ?? false, canPresent: canPresent, next: next?.id) {
        case .none: break
        case .show:
            guard let next else { return }
            sim.call(line: Self.line(for: next))
            sim.say(Self.line(for: next), duration: .infinity)     // stays until the user is back (SPEC)
            sim.standOut = .peek
            balance?.log("timer presented \(next.id)")
        case .dismiss(let id):
            finish(id, how: "input")
        }
    }

    private func finish(_ id: String, how: String) {
        sim.clearBubble()
        sim.standOut = .docked
        do { _ = try executor?.acknowledge(id: id) } catch {
            unsaved.insert(id)
            reportFailure()
        }
        balance?.log("timer seen \(id) (\(how))")
        balance?.resume()                                  // its own prompt, if any, comes back
    }

    private func reportFailure() {
        guard !reportedFailure else { return }
        reportedFailure = true
        balance?.log("tools timer persistence failed")
    }

    /// A timer shows its title as Chilk's own line; a scheduled message is model-written, so it is cleaned.
    private static func line(for entry: LocalTimers.Entry) -> String {
        entry.message == entry.title ? Lines.timerDue(entry.title) : Dialogue.plain(entry.message)
    }

    func shutdown() { timer?.invalidate(); timer = nil }
}
