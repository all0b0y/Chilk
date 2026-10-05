import AppKit
import ChilkCore
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
    var ownsStage: Bool { display.showing != nil }

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
        let result: CodexToolResult
        if ChilkFileToolExecutor.handles(call.name) {
            result = await files.execute(call)
        } else if ChilkReminderExecutor.handles(call.name) {
            result = await reminders.execute(name: call.name, arguments: call.arguments)
        } else if let executor {
            result = executor.execute(name: call.name, arguments: call.arguments)
        } else {
            result = .failure("Chilk actions unavailable: timer storage could not be loaded")
        }
        balance?.log("tool \(call.name) success=\(result.success)")
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
                NSApp.requestUserAttention(.informationalRequest)
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
