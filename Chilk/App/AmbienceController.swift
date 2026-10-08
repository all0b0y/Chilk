import AppKit
import ChilkCore

/// Slice 6f-1 (SPEC 22–23): the built-in display's brightness → a nightcap and sleep, a lamp, sunglasses.
/// DisplayServices (private, no permission) is read twice a second; only while Chilk lives on the built-in display.
@MainActor
final class AmbienceController {
    private let sim: CharacterSim
    private var watch = BrightnessWatch()
    private var cooldown = AmbienceCooldown()
    private var timer: Timer?
    private var rng = SystemRandom()
    private let env = ProcessInfo.processInfo.environment
    private let started = Date()
    /// The look he has on now (the sim drops the nightcap by itself when he wakes up).
    private(set) var look: Ambience?
    /// «Проверка ▸ Свет»: the look stays this long whatever the brightness.
    private var checkUntil = Date.distantPast

    var log: (String) -> Void = { _ in }
    /// Chilk is busy (a conversation, a notice, a request, the popover…): the roll is lost; asleep in the cap — wakes.
    var busy: () -> Bool = { false }
    var eyesPressure: () -> Double = { 0 }
    /// He lives on the built-in display (6e): otherwise the feature is off.
    var onBuiltin: () -> Bool = { true }

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private let getBrightness: GetBrightness? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: GetBrightness.self)
    }()

    init(sim: CharacterSim) {
        self.sim = sim
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.1
    }

    /// The built-in display's brightness (0…1), or nil (no built-in display / DisplayServices refused).
    /// CHILK_FAKE_BRIGHTNESS="0.46,0.05@5,0.95@15" (acceptance): the value from that many seconds after launch.
    private func brightness() -> Double? {
        if let raw = env["CHILK_FAKE_BRIGHTNESS"] {
            let elapsed = Date().timeIntervalSince(started)
            var value: Double?
            for item in raw.split(separator: ",") {
                let parts = item.split(separator: "@")
                guard let v = Double(parts[0]) else { continue }
                let at = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
                if elapsed >= at { value = v }
            }
            return value
        }
        guard let get = getBrightness else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &count)
        guard let builtin = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return nil }
        var b: Float = 0
        return get(builtin, &b) == 0 ? Double(b) : nil
    }

    private func userHere() -> Bool {
        if let fake = env["CHILK_FAKE_IDLE"].flatMap(Double.init) { return fake < 60 }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return idle < 60 && CGDisplayIsAsleep(CGMainDisplayID()) == 0
    }

    private func tick() {
        // Hidden: no light play (6d, decision 18); on an external display the feature is off.
        guard onBuiltin(), !sim.hidden else {
            watch = BrightnessWatch()                                   // back here: the first reading is only the place
            return takeOff("not on the built-in display or hidden")
        }
        // Away, locked or the display asleep: no rolls (the system dims by itself); the place is read afresh after.
        guard userHere() else { watch = BrightnessWatch(); return }
        guard let level = brightness() else { return }
        if look == .nightcap, !sim.props.contains(.nightcap) { look = nil; log("ambience: woke up, nightcap off") }
        if let l = look {
            if Date() >= checkUntil, !l.keeps(level: level, eyesPressure: eyesPressure()) {
                takeOff(String(format: "brightness %.2f", level))
            } else if l == .nightcap, sim.isAsleep, busy() {
                sim.wakeUp()                                    // his own request / a conversation wakes him
            }
        }
        let now = Date().timeIntervalSince(started)
        guard let settled = watch.feed(level, now: now) else { return }
        guard look == nil, !sim.isAsleep else { return }
        // Slice 9, decision 6: one scene in 10 minutes at most (a missed roll starts no pause).
        guard cooldown.ready(now: now) else {
            return log(String(format: "ambience: brightness settled at %.2f — cooldown, no roll", settled))
        }
        let roll = env["CHILK_DEMO_AMBIENCE_ROLL"].flatMap(Double.init) ?? rng.next()
        let coin = env["CHILK_DEMO_AMBIENCE_COIN"].flatMap(Double.init) ?? rng.next()
        let pick = Ambience.pick(level: settled, roll: roll, coin: coin, eyesPressure: eyesPressure())
        log(String(format: "ambience: brightness settled at %.2f, roll %.3f vs %.3f → %@", settled, roll,
                   Ambience.chance(level: settled), pick?.rawValue ?? "nothing"))
        guard let pick else { return }
        if busy() || sim.act != nil { return log("ambience: \(pick.rawValue) lost, Chilk busy") }
        put(pick)
        cooldown.played(now: now)
    }

    /// Put a look on (also «Проверка ▸ Свет» past the roll: `check` keeps it 20 s whatever the brightness).
    func put(_ a: Ambience, check: Bool = false) {
        if let l = look, l != a { takeOff("another look") }
        look = a
        if check { checkUntil = Date().addingTimeInterval(20) }
        switch a {
        case .nightcap: sim.putOnNightcap()
        case .lamp: sim.wear(.lamp)
        case .sunglasses: sim.wear(.sunglasses)
        }
        log("ambience: \(a.rawValue) on")
    }

    private func takeOff(_ why: String) {
        guard let l = look else { return }
        look = nil
        switch l {
        case .nightcap:
            if sim.isAsleep { sim.wakeUp() }
            sim.takeOff(.nightcap)
        case .lamp: sim.takeOff(.lamp)
        case .sunglasses: sim.takeOff(.sunglasses)
        }
        log("ambience: \(l.rawValue) off (\(why))")
    }
}
