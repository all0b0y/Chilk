import AppKit
import ChilkCore

/// Once a second: local hour (night yawns) and "is the user at the Mac?" from the system-wide
/// idle time — no permissions. Away → he dozes off; back → wakes up and maybe greets.
///
/// Slice 10 (SPEC «Срез 10», decisions 15–17): his own deed counts too — while he leads, talks or asks he does not doze,
/// the three minutes count from its end, and a wait without a time limit (a card, a timed message) keeps him up ten.
@MainActor
final class PresenceMonitor {
    private let sim: CharacterSim
    private var tracker = PresenceTracker()
    private var timer: Timer?
    /// Balance can replace the greeting («Как прогулка?») and tidy up props when the user is back.
    var greetingOverride: (() -> String?)?
    var onWake: (() -> Void)?
    /// What he is doing now (the app reads it from whoever holds him). Not his walks or the night's «Сон» (decision 16).
    var deed: () -> PresenceTracker.Deed = { .none }
    /// Someone else holds the stage when the user is back (a conversation, the walk «со мной», a notice): he wakes up
    /// without a greeting — it would cover their bubble.
    var quietReturn: () -> Bool = { false }
    var log: (String) -> Void = { _ in }
    /// Acceptance only (CHILK_FAKE_PRESENCE_IDLE=<s>, isolated runs): no input for the first <s> seconds after launch,
    /// then the user is back — the mouse of the person at the Mac does not count.
    private let fakeAwayFor: TimeInterval?
    private let launched = Date()

    init(sim: CharacterSim) {
        self.sim = sim
        let env = ProcessInfo.processInfo.environment
        if let away = env["CHILK_AWAY_AFTER"].flatMap(Double.init) {
            tracker.awayAfter = away             // e.g. 10 s for manual testing
        }
        if let wait = env["CHILK_WAIT_AWAKE"].flatMap(Double.init) {
            tracker.waitAwake = wait
        }
        fakeAwayFor = AppState.isolated != nil ? env["CHILK_FAKE_PRESENCE_IDLE"].flatMap(Double.init) : nil
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = 0.3
    }

    private var idleSeconds: TimeInterval {
        if let away = fakeAwayFor {
            let since = Date().timeIntervalSince(launched)
            return since < away ? since : 0
        }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func poll() {
        let hour = Calendar.current.component(.hour, from: Date())
        sim.hourOfDay = hour
        let idle = idleSeconds
        let doing = deed()
        switch tracker.update(idleSeconds: idle, now: Date(), deed: doing) {
        case .wentAway:
            log(String(format: "presence: away (idle %.0f s, %@), he dozes off", idle, String(describing: doing)))
            sim.fallAsleep()
        case .returned(let absence):
            log(String(format: "presence: back after %.0f s (%@)", absence, String(describing: doing)))
            wake(after: absence, hour: hour)
        case .roused:
            log("presence: his own \(doing) wakes him, the user is still away")
            sim.wakeUp()
        case .dozedOff:
            log("presence: quiet again, he dozes off")
            sim.fallAsleep()
        case nil:
            break
        }
    }

    /// Also used by the Dock "Проверка" menu.
    func wake(after absence: TimeInterval, hour: Int) {
        sim.wakeUp()
        onWake?()
        if quietReturn() {
            _ = greetingOverride?()                  // a return line said now would cover their bubble: dropped
            return
        }
        if let line = greetingOverride?() {
            sim.say(line, duration: 4)
            return
        }
        switch Greeting.after(absence: absence, hour: hour) {
        case .goodMorning: sim.say(Lines.goodMorning.randomElement()!, duration: 4)
        case .welcomeBack: sim.say(Lines.welcomeBack.randomElement()!, duration: 3.5)
        case nil: break
        }
    }
}
