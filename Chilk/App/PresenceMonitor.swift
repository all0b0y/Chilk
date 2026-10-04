import AppKit
import ChilkCore

/// Once a second: local hour (night yawns) and "is the user at the Mac?" from the system-wide
/// idle time — no permissions. Away → he dozes off; back → wakes up and maybe greets.
@MainActor
final class PresenceMonitor {
    private let sim: CharacterSim
    private var tracker = PresenceTracker()
    private var timer: Timer?
    /// Balance can replace the greeting («Как прогулка?») and tidy up props when the user is back.
    var greetingOverride: (() -> String?)?
    var onWake: (() -> Void)?

    init(sim: CharacterSim) {
        self.sim = sim
        if let away = ProcessInfo.processInfo.environment["CHILK_AWAY_AFTER"].flatMap(Double.init) {
            tracker.awayAfter = away             // e.g. 10 s for manual testing
        }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = 0.3
    }

    private func poll() {
        let hour = Calendar.current.component(.hour, from: Date())
        sim.hourOfDay = hour
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        switch tracker.update(idleSeconds: idle, now: Date()) {
        case .wentAway:
            sim.fallAsleep()
        case .returned(let absence):
            wake(after: absence, hour: hour)
        case nil:
            break
        }
    }

    /// Also used by the Dock "Проверка" menu.
    func wake(after absence: TimeInterval, hour: Int) {
        sim.wakeUp()
        onWake?()
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
