import AppKit
import ChilkCore
import ChilkRender
import CoreAudio

/// Slice 6f-2 (SPEC 24–25): music → the disco. The sound of each process comes from Core Audio's process objects
/// (macOS 14+, no permission): an app is «playing» while it runs audio output. Checked once a second.
@MainActor
final class DiscoController {
    private let sim: CharacterSim
    private let edge: EdgeController
    private var disco = Disco()
    private var timer: Timer?
    private var rng = SystemRandom()
    private let env = ProcessInfo.processInfo.environment
    private let started = Date()
    private let ball = DiscoBallWindow()
    private var dancing = false

    var log: (String) -> Void = { _ in }
    var busy: () -> Bool = { false }
    /// Apps marked «Музыка» in Settings → Приложения.
    var marked: () -> Set<String> = { [] }
    /// A call or a video now (the balance's signals).
    var callOrVideo: () -> Bool = { false }

    init(sim: CharacterSim, edge: EdgeController) {
        self.sim = sim
        self.edge = edge
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.2
    }

    private var free: Bool {
        !busy() && sim.act == nil && !sim.hidden && !sim.isAsleep && !sim.isCarried && sim.standOut == .docked
    }

    private func tick() {
        if dancing {
            if !(sim.act?.isDance ?? false) { return finish("done") }
            // A request, a call, or hidden meanwhile (decision 18: no disco behind the edge): the dance stops.
            if busy() || sim.hidden { sim.stopAct(); return finish("interrupted") }
            return
        }
        // Within the hour after a dance, or hidden, the sound is not even looked at.
        let wall = Date().timeIntervalSince1970
        let music = !sim.hidden && !disco.resting(now: wall) && musicPlaying() && !callOrVideo()
        // The roll is drawn into a local: reading `disco` inside its own mutating call is an exclusivity trap.
        let r = env["CHILK_DEMO_DISCO_ROLL"].flatMap(Double.init) ?? rng.next()
        var rolled = false
        let go = disco.tick(seconds: 1, music: music, free: free, now: wall) { rolled = true; return r }
        if rolled { log(String(format: "disco: %.0f s of music, roll %.2f vs %.2f", disco.musicFor, r, Disco.chance)) }
        if go { dance(why: "music") }
    }

    /// The dance under the ball (also «Проверка ▸ Диско», past the music and the roll).
    func dance(why: String) {
        guard !dancing else { return }
        guard !sim.hidden else { return log("disco: hidden, no dance") }
        let seconds = env["CHILK_DEMO_DANCE_SECONDS"].flatMap(Double.init)
            ?? rng.uniform(Disco.dance.lowerBound, Disco.dance.upperBound)
        dancing = true
        sim.perform(.dance(seconds: seconds))
        ball.show(over: { [weak edge] in edge?.bodyOnScreen ?? .zero }, top: { [weak edge] in edge?.screenTop ?? 0 },
                  snapshot: env["CHILK_DEMO_DISCO_SNAPSHOT"].map { URL(fileURLWithPath: $0) })
        log(String(format: "disco: dance %.0f s (%@), ball window %@ over his body at %@, edge window %@", seconds, why,
                   NSStringFromRect(ball.frame), NSStringFromPoint(edge.bodyOnScreen), NSStringFromRect(edge.windowFrame)))
    }

    private func finish(_ how: String) {
        dancing = false
        ball.hide()
        log("disco: \(how), the ball goes up")
    }

    // MARK: Who is playing

    /// CHILK_FAKE_MUSIC=<s> (acceptance): music plays from that many seconds after launch.
    private func musicPlaying() -> Bool {
        if let from = env["CHILK_FAKE_MUSIC"].flatMap(Double.init) { return Date().timeIntervalSince(started) >= from }
        let marks = marked()
        return Self.playingBundles().contains { MusicApps.isMusic($0, marked: marks) }
    }

    private static func playingBundles() -> [String] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { o in
            var running: UInt32 = 0
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var s = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(o, &a, 0, nil, &s, &running) == noErr, running != 0 else { return nil }
            var bundle: Unmanaged<CFString>?
            a.mSelector = kAudioProcessPropertyBundleID
            s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(o, &a, 0, nil, &s, &bundle) == noErr, let b = bundle else { return nil }
            return b.takeRetainedValue() as String
        }
    }
}

/// The ball's own click-through window: from the top of his screen down over him; it comes down in 1 s, hangs
/// turning while he dances, goes up in 1 s.
@MainActor
final class DiscoBallWindow {
    private let panel: NSPanel
    private let view = BallView()
    private var timer: Timer?
    private var shownAt = 0.0
    private var hidingAt: Double?
    private var over: () -> CGPoint = { .zero }
    private var top: () -> CGFloat = { 0 }
    private var snapshot: URL?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = view
    }

    func show(over: @escaping () -> CGPoint, top: @escaping () -> CGFloat, snapshot: URL?) {
        self.over = over
        self.top = top
        self.snapshot = snapshot
        shownAt = CACurrentMediaTime()
        hidingAt = nil
        layout()
        panel.orderFrontRegardless()
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.animate() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func hide() { if hidingAt == nil { hidingAt = CACurrentMediaTime() } }
    var frame: NSRect { panel.frame }

    private func layout() {
        let body = over(), height = max(120, top() - body.y - 70)
        panel.setFrame(NSRect(x: body.x - DiscoBall.width / 2, y: body.y + 70, width: DiscoBall.width, height: height),
                       display: false)
    }

    private func animate() {
        let now = CACurrentMediaTime()
        layout()
        let hang = Double(panel.frame.height) - DiscoBall.radius - 50
        var drop = hang * min(1, (now - shownAt) / 1.0)
        if let h = hidingAt {
            let u = (now - h) / 1.0
            if u >= 1 { timer?.invalidate(); timer = nil; panel.orderOut(nil); return }
            drop = hang * (1 - u)
        }
        view.drop = drop
        view.time = now - shownAt
        view.needsDisplay = true
        if let url = snapshot, now - shownAt >= 3 {                      // acceptance: one picture mid-dance
            snapshot = nil
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }

    private final class BallView: NSView {
        var drop = 0.0
        var time = 0.0
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            DiscoBall.draw(in: ctx, width: Double(bounds.width), drop: drop, time: time)
        }
    }
}
