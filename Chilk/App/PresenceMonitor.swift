import AppKit
import ChilkCore

/// Once a second: local hour (night yawns) and "is the user at the Mac?" from the system-wide
/// idle time — no permissions. Away → he dozes off; back → wakes up and maybe greets.
///
/// Slice 10 (SPEC «Срез 10», decisions 15–17): his own deed counts too — while he leads, talks or asks he does not doze,
/// the three minutes count from its end, and a wait without a time limit (a card, a timed message) keeps him up ten.
@MainActor
final class PresenceMonitor {
    /// Who holds the stage when the user is back (review 10d).
    enum ReturnStage {
        /// Nobody: the greeting or the return line now.
        case free
        /// Another bubble (a timed notice, a request, the popover…): the line waits until the stage is free — at most
        /// `pendingFor` — so «Доброе утро» is not lost under a notice left from the night.
        case later
        /// A conversation (the user already talks to him) or the walk «со мной» (its end says «Как прогулка?»): no line.
        case never
    }

    private let sim: CharacterSim
    private var tracker = PresenceTracker()
    private var timer: Timer?
    /// Balance can replace the greeting («Как прогулка?») and tidy up props when the user is back.
    var greetingOverride: (() -> String?)?
    var onWake: (() -> Void)?
    /// What he is doing now (the app reads it from whoever holds him). Not his walks or the night's «Сон» (decision 16).
    var deed: () -> PresenceTracker.Deed = { .none }
    var returnStage: () -> ReturnStage = { .free }
    var log: (String) -> Void = { _ in }
    /// A return line the stage was not free for, and when it was due.
    private var pendingLine: (text: String, duration: Double, at: Date)?
    private static let pendingFor: TimeInterval = 300
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
        let isolated = AppState.isolated != nil
        if isolated, let wait = env["CHILK_WAIT_AWAKE"].flatMap(Double.init) {
            tracker.waitAwake = wait
        }
        fakeAwayFor = isolated ? env["CHILK_FAKE_PRESENCE_IDLE"].flatMap(Double.init) : nil
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
            pendingLine = nil
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
            sayPendingLine()
        }
    }

    /// Also used by the Dock "Проверка" menu.
    func wake(after absence: TimeInterval, hour: Int) {
        sim.wakeUp()
        onWake?()
        pendingLine = nil
        let line: (text: String, duration: Double)? = if let override = greetingOverride?() { (override, 4) } else {
            switch Greeting.after(absence: absence, hour: hour) {
            case .goodMorning: (Lines.goodMorning.randomElement()!, 4)
            case .welcomeBack: (Lines.welcomeBack.randomElement()!, 3.5)
            case nil: nil
            }
        }
        guard let line else { return }
        switch returnStage() {
        case .free: sim.say(line.text, duration: line.duration)
        case .later:
            log("presence: the stage is busy, «\(line.text)» waits for it")
            pendingLine = (line.text, line.duration, Date())
        case .never: break                         // it would cover their bubble or come after the user spoke
        }
    }

    private func sayPendingLine() {
        guard let p = pendingLine else { return }
        switch returnStage() {
        case .free:
            pendingLine = nil
            guard Date().timeIntervalSince(p.at) < Self.pendingFor else { return }
            sim.say(p.text, duration: p.duration)
        case .later:
            if Date().timeIntervalSince(p.at) >= Self.pendingFor { pendingLine = nil }
        case .never:
            pendingLine = nil                       // a conversation began: a greeting after it would be late
        }
    }
}
