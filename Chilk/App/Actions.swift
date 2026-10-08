import AppKit
import ChilkCore
import ChilkApple
import ChilkBrain

/// Test state is separate from both personal balance aggregates and the official Chilk Codex login.
enum AppState {
    /// An acceptance run with its own state (CHILK_STATE_DIR set and non-empty): demo hooks act only then.
    static var isolated: URL? { StateDir.isolated(in: ProcessInfo.processInfo.environment) }
    static var directory: URL { isolated ?? CodexSetup.defaultDataDir }
}

@MainActor
final class Actions {
    let executor: ChilkToolExecutor?
    let files: Files
    /// CHILK_FAKE_REMINDERS=1 | seed: a fake list in the state dir (slice 9b: `seed` plans three things for tomorrow).
    let reminders = ChilkReminderExecutor(store: ProcessInfo.processInfo.environment["CHILK_FAKE_REMINDERS"] != nil
                                          ? FakeReminders(seedDay: ["seed": 1, "seed-today": 0, "seed-yesterday": -1][ProcessInfo.processInfo.environment["CHILK_FAKE_REMINDERS"] ?? ""])
                                          : EventKitReminders())
    /// Slice 8e: Chilk's own «Чилк» calendar (CHILK_FAKE_CALENDAR=1 | seed: a fake in the state dir for acceptance runs).
    private let calendar = ChilkCalendarExecutor(store: ProcessInfo.processInfo.environment["CHILK_FAKE_CALENDAR"] != nil
                                                 ? FakeCalendar(seed: ProcessInfo.processInfo.environment["CHILK_FAKE_CALENDAR"] == "seed")
                                                 : EventKitCalendar())
    /// Slice 8f: Chilk's own «Чилк» folder in Apple Notes (CHILK_FAKE_NOTES=1 | seed: a fake in the state dir).
    private let notes = ChilkNotesExecutor(store: ProcessInfo.processInfo.environment["CHILK_FAKE_NOTES"] != nil
                                           ? FakeNotes(seed: ProcessInfo.processInfo.environment["CHILK_FAKE_NOTES"] == "seed")
                                           : AppleNotes())
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
        if call.name == "chilk_clock_open" {
            if let clock { clock.openClock() }
            result = clock == nil ? .failure("clock_unavailable") : .ok([
                "opened": "Clock",
                "note": "Chilk cannot cancel, pause or resume Clock timers himself (macOS); the user does it in Clock."])
        } else if ChilkReminderExecutor.proposes(call.name) || ChilkCalendarExecutor.proposes(call.name)
                    || ChilkNotesExecutor.proposes(call.name) || call.name == "chilk_schedule" || call.name == "chilk_timer" {
            result = await propose(call)                        // 8c: a card first; «Да» writes it
        } else if call.name == "chilk_remember" {
            result = remember(call)
        } else if call.name == "chilk_emote" {
            result = emote(call)
        } else if call.name == "chilk_plan" {
            result = await plan(call)
        } else if call.name == "chilk_plan_show" {
            if case .planShow(let day)? = try? ChilkToolCatalog.parse(name: call.name, arguments: call.arguments) {
                let d = day ?? Calendar.current.startOfDay(for: Date())
                showPlan(d)
                result = .ok(["shown": true, "day_text": .string(PlanDay.title(d, now: Date(), calendar: .current))])
            } else { result = .failure(ChilkToolCatalog.explain(name: call.name, arguments: call.arguments)) }
        } else if ChilkFileToolExecutor.handles(call.name) {
            result = await files.execute(call)
        } else if ChilkReminderExecutor.handles(call.name) {
            result = await reminders.execute(name: call.name, arguments: call.arguments)
        } else if ChilkCalendarExecutor.handles(call.name) {
            result = await calendar.execute(name: call.name, arguments: call.arguments)
        } else if ChilkNotesExecutor.handles(call.name) {
            result = await notes.execute(name: call.name, arguments: call.arguments)
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

    /// Slice 9b: the day plan being collected (set by the app).
    var planner: Planner?
    /// Slice 9b (decision 16): «Лист дня» for a day — asked by voice, or after «Да» on a plan card (set by the app).
    var showPlan: (Date) -> Void = { _ in }
    var onPlanWritten: (Date) -> Void = { _ in }

    private func plan(_ call: CodexToolCall) async -> CodexToolResult {
        guard case .plan(let action, let day, let items)? = try? ChilkToolCatalog.parse(name: call.name, arguments: call.arguments)
        else { return .failure(ChilkToolCatalog.explain(name: call.name, arguments: call.arguments)) }
        guard let planner else { return .failure("plan_unavailable: nothing was planned") }
        return await planner.handle(action, day: day, items: items, channel: ClockCheck.turnChannel == .chat ? .chat : .voice)
    }

    // MARK: Confirmation cards (slice 8c, decisions 3–8)

    /// Set by the app.
    weak var cards: CardDesk?
    /// Slice 8d: Clock timers through the shortcut «Чилк».
    var clock: ClockTimers?

    /// `chilk_reminder` / `chilk_schedule` / `chilk_reminder_change` / `chilk_timer` / `chilk_event` / `chilk_event_change`
    /// → a card built from the values that would be
    /// written. Nothing is written here.
    private func propose(_ call: CodexToolCall) async -> CodexToolResult {
        guard let cards else { return .failure("cards_unavailable: nothing was done") }
        let action: ChilkAction
        do { action = try ChilkToolCatalog.parse(name: call.name, arguments: call.arguments) }
        catch { return .failure(ChilkToolCatalog.explain(name: call.name, arguments: call.arguments)) }
        let now = Date()
        func future(_ d: Date) -> Bool { d > now.addingTimeInterval(30) }
        // Decision 8: an hour said without утра / дня / вечера / ночи is a day hour — 00:00–05:59 only when the words
        // say so. The model guessed night for «в три» (dictated «напомнив три»): the app takes 15:00, the card marks it.
        func daytime(_ d: Date) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .autoupdatingCurrent
            guard ClockCheck.guess(for: d).part, cal.component(.hour, from: d) < 6 else { return d }
            balance?.log("card: an open hour taken as day (+12 h)")
            return d.addingTimeInterval(12 * 3600)
        }
        let kind: ActionCard.Kind
        var date: Date?
        // Slice 8e: an all-day event has no part of day to guess (only «завтра» after midnight can be a guess).
        var wholeDay = false
        let passed = CodexToolResult.failure("time_passed: that time has already passed; ask the user for a future time")
        switch action {
        case .reminder(let title, let said):
            let at = daytime(said)
            guard future(at) else { return .failure("time_passed: that time has already passed; ask the user for a future time") }
            kind = .reminder(title: title, due: at)
            date = at
        case .schedule(let said, let title, let message):
            let at = daytime(said)
            guard future(at) else { return .failure("time_passed: that time has already passed; ask the user for a future time") }
            kind = .message(title: title, text: message, at: at)
            date = at
        case .reminderChange(let id, let change):
            let found: ReminderInfo
            do { found = try await reminders.lookup(id: id) } catch ReminderAccessError.denied {
                return .failure("no_access: no access to Reminders. The user can allow it in System Settings → Privacy & Security → Reminders → Чилк")
            } catch ReminderAccessError.notFound {
                return .failure("not_found: no reminder with this id in the «Чилк» list; list them with chilk_reminders")
            } catch { return .failure("reminders_unreachable: could not reach Apple Reminders; nothing was changed") }
            let change = switch change {
            case .move(let d): ReminderChange.move(daytime(d))
            case .moveRename(let d, let t): ReminderChange.moveRename(daytime(d), t)
            default: change
            }
            switch change {
            case .move(let d), .moveRename(let d, _):
                guard future(d) else { return .failure("time_passed: that time has already passed; ask the user for a future time") }
                date = d
            default: break
            }
            switch change {
            case .move(let d): kind = .reminderChange(id: id, oldTitle: found.title, oldDue: found.due, title: found.title, due: d)
            case .rename(let t): kind = .reminderChange(id: id, oldTitle: found.title, oldDue: found.due, title: t, due: found.due)
            case .moveRename(let d, let t): kind = .reminderChange(id: id, oldTitle: found.title, oldDue: found.due, title: t, due: d)
            case .done: kind = .reminderComplete(id: id, title: found.title, due: found.due)
            case .delete: kind = .reminderDelete(id: id, title: found.title, due: found.due)
            }
        case .timer(let seconds, let title):
            kind = .timer(title: title.trimmingCharacters(in: .whitespacesAndNewlines), seconds: seconds)
        case .event(let title, let said, let minutes, let allDay):
            if allDay {
                let slot = ActionCard.allDaySlot(movedTo: said, start: said, end: said)
                guard slot.start >= Calendar.current.startOfDay(for: now) else { return passed }
                kind = .event(title: title, start: slot.start, end: slot.end, allDay: true)
                date = slot.start
                wholeDay = true
            } else {
                let at = daytime(said)
                guard future(at) else { return passed }
                kind = .event(title: title, start: at, end: at.addingTimeInterval(Double(minutes) * 60), allDay: false)
                date = at
            }
        case .eventChange(let id, let change):
            // Only an event of the «Чилк» calendar (the store checks it), never a repeating one.
            let found: EventInfo
            do { found = try await calendar.lookup(id: id) } catch { return .failure(ChilkCalendarExecutor.failure(error)) }
            guard !found.recurring else { return .failure(ChilkCalendarExecutor.failure(CalendarAccessError.recurring)) }
            // A move keeps the length unless a new one is said; a whole day moves by whole days. Only a new start must lie
            // ahead: lengthening an event that is on now is fine.
            // Just the day («перенеси на пятницу»): the event keeps its time of day; there is no hour to correct.
            let dayOnly = ChilkToolCatalog.dateOnly(call.arguments["at"]?.string ?? "") != nil
            func moved(_ d: Date, _ minutes: Int?) -> (start: Date, end: Date)? {
                ActionCard.movedSlot(start: found.start, end: found.end, allDay: found.allDay,
                                     to: found.allDay || dayOnly ? d : daytime(d), minutes: minutes, now: now, dayOnly: dayOnly)
            }
            let unchanged = CodexToolResult.failure("nothing_to_change: the event already is like that; no card was made")
            wholeDay = found.allDay
            switch change {
            case .move(let d, let m), .moveRename(let d, let m, _):
                guard let slot = moved(d, m) else { return passed }
                var title = found.title
                if case .moveRename(_, _, let t) = change { title = t }
                guard slot.start != found.start || slot.end != found.end || title != found.title else { return unchanged }
                kind = .eventChange(id: id, oldTitle: found.title, oldStart: found.start, oldEnd: found.end, allDay: found.allDay,
                                    title: title, start: slot.start, end: slot.end)
                if slot.start != found.start { date = slot.start }
            case .rename(let t):
                guard t != found.title else { return unchanged }
                kind = .eventChange(id: id, oldTitle: found.title, oldStart: found.start, oldEnd: found.end, allDay: found.allDay,
                                    title: t, start: found.start, end: found.end)
            case .delete:
                kind = .eventDelete(id: id, title: found.title, start: found.start, end: found.end, allDay: found.allDay)
            }
        case .note(let title, let text):
            kind = .note(title: title, text: text)
        case .noteChange(let id, let change):
            // Only a note of the «Чилк» folder (the store checks it); a locked one is never changed.
            let found: NoteInfo
            do { found = try await notes.lookup(id: id) } catch { return .failure(ChilkNotesExecutor.failure(error)) }
            guard !found.locked else { return .failure(ChilkNotesExecutor.failure(NotesAccessError.locked)) }
            switch change {
            case .append(let text):
                // Notes rewrites the whole body even to append: pictures, checklists and tables would be lost.
                guard !found.rich else { return .failure(ChilkNotesExecutor.failure(NotesAccessError.rich)) }
                kind = .noteAppend(id: id, title: found.title, text: text)
            case .rewrite(let title, let text):
                guard !found.rich else { return .failure(ChilkNotesExecutor.failure(NotesAccessError.rich)) }
                // The model writes at most 2000 characters: a longer note would lose its end without anyone seeing it.
                guard found.text.count <= 2000 else { return .failure(ChilkNotesExecutor.failure(NotesAccessError.tooLong)) }
                guard (title ?? found.title) != found.title || text != found.text else {
                    return .failure("nothing_to_change: the note already is like that; no card was made")
                }
                kind = .noteRewrite(id: id, oldTitle: found.title, oldText: found.text, title: title ?? found.title, text: text)
            case .delete:
                kind = .noteDelete(id: id, title: found.title)
            }
        default:
            return .failure("Unsupported action")
        }
        let guess = date.map { ClockCheck.guess(for: $0) } ?? (part: false, day: false)
        let card = ActionCard(kind: kind, guessedPart: guess.part && !wholeDay, guessedDay: guess.day)
        cards.propose(card)
        return .ok(["awaiting_confirmation": true, "card": .string(card.summary()),
                    "note": "Nothing is done yet. The user confirms the card with Да, changes it, or says Нет."])
    }

    /// After the card's «Да»: writes exactly the card's values. Returns the line Chilk says.
    func commit(_ card: ActionCard) async -> (ok: Bool, line: String) {
        let started = Date()
        let format = { (d: Date) in card.whenText(d, now: started) }
        // Switched off in the tray after the card was proposed: nothing is written.
        let ability: ChilkAbility = switch card.kind {
        case .message: .timers
        case .timer: .clock
        case .event, .eventChange, .eventDelete: .calendar
        case .note, .noteAppend, .noteRewrite, .noteDelete: .notes
        default: .reminders
        }
        guard switches().isOn(ability) else {
            return (false, String(localized: "Не сделал: это выключено в «Инструментах»"))
        }
        let result: CodexToolResult
        let line: String
        let tool: String
        /// Slice 9b (decision 12): some of a plan's items were written — he names the rest.
        var partial: String?
        switch card.kind {
        case .plan(let day, let items, _):
            tool = "card_plan"
            let entries = PlanDay.entries(day: day, items: items, now: started, calendar: .current)
            var failed: [String] = []
            var failure: CodexToolResult?
            for entry in entries {
                let r = await reminders.create(title: entry.title, due: entry.due, timed: entry.timed)
                if !r.success { failed.append(entry.title); failure = r }
            }
            let written = entries.count - failed.count
            let dayText = PlanDay.title(day, now: started, calendar: .current, accusative: true)
            let things = RussianPlural.form(written, String(localized: "дело"), String(localized: "дела"), String(localized: "дел"))
            if written > 0 { onPlanWritten(day) }
            if failed.isEmpty {
                result = .ok(["created": .number(Double(written))])
                line = String(localized: "Готово: план на \(dayText) — \(written) \(things) в «Напоминаниях»")
            } else if written == 0 {
                result = failure ?? .failure("reminders_unreachable")
                line = ""
            } else {
                result = .ok(["created": .number(Double(written)), "failed": .number(Double(failed.count))])
                line = String(localized: "Записал \(written) из \(entries.count). Не записалось: \(failed.joined(separator: ", "))")
                partial = line
            }
        case .reminder(let title, let due):
            tool = "card_reminder"
            result = await reminders.create(title: title, due: due)
            line = String(localized: "Готово: «\(title)» — \(format(due))")
        case .message(let title, let text, let at):
            tool = "card_message"
            let iso = ISO8601DateFormatter()
            iso.timeZone = .current
            result = executor?.execute(name: "chilk_schedule", arguments: ["at": .string(iso.string(from: at)),
                                                                           "title": .string(title), "message": .string(text)])
                ?? .failure("timers_unavailable")
            line = String(localized: "Готово: скажу «\(Dialogue.plain(text))» — \(format(at))")
        case .reminderChange(let id, let old, let oldDue, let title, let due):
            tool = "card_reminder_change"
            // Only what the card changes: a rename keeps the time and the alarm as they are.
            result = await reminders.change(id: id, title: title == old ? nil : title, due: due != oldDue ? due : nil)
            line = String(localized: "Готово: «\(title)» изменено")
        case .reminderComplete(let id, let title, _):
            tool = "card_reminder_done"
            result = await reminders.complete(id: id)
            line = String(localized: "Готово: «\(title)» выполнено")
        case .reminderDelete(let id, let title, _):
            tool = "card_reminder_delete"
            result = await reminders.delete(id: id)
            line = String(localized: "Готово: «\(title)» удалено")
        case .timer(let title, let seconds):
            tool = "card_clock_timer"
            let length = ActionCard.duration(seconds)
            switch await clock?.start(seconds: seconds, confirmedAt: started) ?? .failed {
            case .started:
                result = .ok(["started": true])
                line = String(localized: "Таймер «\(title)» — \(length). Прозвонят «Часы»")
            case .notAdded:
                result = .failure("shortcut_missing")
                line = String(localized: "Не поставил: нет команды «Чилк». Добавь её в окне «Быстрых команд» и попроси ещё раз")
            case .notPrepared:
                result = .failure("shortcut_unprepared")
                line = String(localized: "Не поставил: не смог подготовить команду «Чилк» — нет интернета?")
            case .failed:
                result = .failure("clock_failed")
                line = String(localized: "Не получилось — «Часы» не ответили")
            }
        case .event(let title, let start, let end, let allDay):
            tool = "card_event"
            result = await calendar.create(title: title, start: start, end: end, allDay: allDay)
            line = String(localized: "Готово: «\(title)» — \(card.spanText(start: start, end: end, allDay: allDay, now: started))")
        case .eventChange(let id, let old, let oldStart, let oldEnd, _, let title, let start, let end):
            tool = "card_event_change"
            // Only what the card changes: a rename keeps the slot as it is.
            result = await calendar.change(id: id, title: title == old ? nil : title, start: start != oldStart ? start : nil,
                                           end: end != oldEnd ? end : nil)
            line = String(localized: "Готово: «\(title)» изменено")
        case .eventDelete(let id, let title, _, _, _):
            tool = "card_event_delete"
            result = await calendar.delete(id: id)
            line = String(localized: "Готово: «\(title)» удалено")
        case .note(let title, let text):
            tool = "card_note"
            result = await notes.create(title: title, text: text)
            line = String(localized: "Готово: заметка «\(title)» — «Заметки» → «Чилк»")
        case .noteAppend(let id, let title, let text):
            tool = "card_note_append"
            result = await notes.append(id: id, text: text)
            line = String(localized: "Готово: дописал в «\(title)»")
        case .noteRewrite(let id, _, _, let title, let text):
            tool = "card_note_rewrite"
            result = await notes.rewrite(id: id, title: title, text: text)
            line = String(localized: "Готово: заметка «\(title)» изменена")
        case .noteDelete(let id, let title):
            tool = "card_note_delete"
            result = await notes.delete(id: id)
            line = String(localized: "Готово: заметка «\(title)» удалена")
        }
        journal.write(ToolJournal.line(at: started, tool: tool,
                                       outcome: result.success ? .ok : .failed(ToolJournal.code(of: result.value["error"]?.string ?? "")),
                                       seconds: Date().timeIntervalSince(started)))
        balance?.log("card \(tool) success=\(result.success)" + (partial == nil ? "" : " (partly)"))
        if let partial { return (false, partial) }
        if result.success { return (true, line) }
        if case .timer = card.kind { return (false, line) }
        let code = ToolJournal.code(of: result.value["error"]?.string ?? "")
        switch card.kind {
        case .event, .eventChange, .eventDelete:
            switch code {
            case "no_access": return (false, String(localized: "Не получилось: нет доступа к «Календарю» — разреши в Настройках"))
            case "recurring_event":
                return (false, String(localized: "Не получилось: это повторяющееся событие — поменяй его в «Календаре»"))
            case "not_found": return (false, String(localized: "Не получилось: этого события уже нет в календаре «Чилк»"))
            default: return (false, String(localized: "Не получилось — ничего не изменилось"))
            }
        case .note, .noteAppend, .noteRewrite, .noteDelete:
            switch code {
            case "no_access": return (false, String(localized: "Не получилось: нет доступа к «Заметкам» — разреши в Настройках"))
            case "not_found": return (false, String(localized: "Не получилось: этой заметки уже нет в папке «Чилк»"))
            case "note_locked": return (false, String(localized: "Не получилось: заметка закрыта паролем — измени её в «Заметках»"))
            case "note_rich_content":
                return (false, String(localized: "Не получилось: в заметке картинки, списки или таблицы — измени её в «Заметках»"))
            case "notes_timeout":
                return (false, String(localized: "Не знаю, получилось ли: «Заметки» не ответили — загляни в папку «Чилк»"))
            default: return (false, String(localized: "Не получилось — ничего не изменилось"))
            }
        default:
            return (false, code == "no_access" ? String(localized: "Не получилось: нет доступа к «Напоминаниям» — разреши в Настройках")
                                               : String(localized: "Не получилось — ничего не изменилось"))
        }
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
