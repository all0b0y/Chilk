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
    private weak var balance: BalanceController?
    private let sim: CharacterSim
    private var timer: Timer?
    private var ownsUntil = Date.distantPast
    private var reportedFailure = false
    var ownsStage: Bool { Date() < ownsUntil }

    init(balance: BalanceController, sim: CharacterSim) {
        self.balance = balance
        self.sim = sim
        do {
            executor = try ChilkToolExecutor(file: AppState.directory.appendingPathComponent("timers.json"),
                status: { [weak balance] in
                    guard let balance else { return [:] }
                    return ["sittingMinutes": .number(Double(balance.sittingMinutes)),
                            "waterPressure": .number(balance.engine.pressure(.water))]
                }, water: { [weak balance] in
                    guard let balance else { throw CodexClient.ClientError.notStarted }
                    try balance.creditWaterFromVoice()
                    return ["credited": true]
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

    func execute(_ call: CodexToolCall) -> CodexToolResult {
        guard let executor else { return .failure("Chilk actions unavailable: timer storage could not be loaded") }
        let result = executor.execute(name: call.name, arguments: call.arguments)
        balance?.log("tool \(call.name) success=\(result.success)")
        return result
    }

    private func tick() {
        guard let executor else { return }
        do {
            let due = try executor.collectDue()
            if !due.isEmpty {
                NSApp.requestUserAttention(.informationalRequest)
                for entry in due { balance?.log("timer due \(entry.id)") }
            }
            guard !ownsStage, balance?.canPresentScheduledNotice == true, let notice = executor.ready.first else { return }
            // A short local bubble, no cloud call at the deadline, no interference with a conversation.
            sim.call(line: notice.message)
            ownsUntil = Date().addingTimeInterval(6)
            _ = try executor.acknowledge(id: notice.id)
            balance?.log("timer presented \(notice.id)")
        } catch {
            if !reportedFailure {
                reportedFailure = true
                balance?.log("tools timer persistence failed")
            }
        }
    }

    func shutdown() { timer?.invalidate(); timer = nil }
}
