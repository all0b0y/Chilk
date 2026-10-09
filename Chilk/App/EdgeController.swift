import AppKit
import ChilkCore
import ChilkRender
import QuartzCore

/// Owns the edge panel and drives the character at the display refresh rate:
/// pointer → simulation → panel position → layer rig.
@MainActor
final class EdgeController: NSObject {
    let metrics = Metrics.standard
    let sim: CharacterSim

    private let panel: EdgePanel
    private let view: CharacterView
    private var placement: EdgePlacement {
        didSet { PlacementStore.save(placement) }
    }
    private var originX = Spring(0, stiffness: 110, damping: 17)
    private var originY = Spring(0, stiffness: 110, damping: 17)
    /// Logical scene placement is independent of the expanded paint window.
    private var sceneOrigin = CGPoint.zero
    private var viewport = SceneViewport(metrics: .standard, placements: [])
    private var sceneFrame: CGRect { CGRect(origin: sceneOrigin, size: metrics.sceneSize) }
    private var link: CADisplayLink?
    private var driverTimer: Timer?
    private var lastTimestamp: CFTimeInterval?
    private var drag: Drag?
    private var carryVelocity = 0.0
    private var lastBusy: Bool?
    /// Stage 3–4: he has left the edge for the middle of the screen (follows `sim.standOut == .center`).
    private var centered = false
    /// Stage 4: above the pause shade, which is above everything else.
    var raised = false {
        didSet { panel.level = raised ? NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1) : .floating }
    }
    /// Bubble buttons and clicks on the body go to the balance controller.
    var onButton: ((Int) -> Void)?
    /// Slice 10 (decision 18): the pinned card's buttons come to `onButton` from this index on.
    static let cardButtonBase = ChilkRenderer.cardButtonBase
    var onPoke: (() -> Void)?
    /// Slice 6d: released with more than half of him behind the edge / a hidden Chilk dragged back onto the screen.
    var onHideDrop: (() -> Void)?
    var onPullOut: (() -> Void)?
    private var pressedButton: Int?
    private struct Flight {
        var start: CFTimeInterval
        var duration: Double
        var from: CGPoint
        var mirrored: Bool
        var completion: () -> Void
    }
    private var flight: Flight?
    // Slice 6e: the monitor he lives on and the leap to another one.
    /// A monitor he can live on: a real screen, or the acceptance demo's virtual one.
    struct Display: Equatable {
        let id: String
        let frame: CGRect
        let visibleFrame: CGRect
        /// The Mac's own display (6f: its brightness drives the nightcap, the lamp and the sunglasses).
        var builtin = false
    }
    private var hop = ScreenHop()
    private var homeDisplay: Display?
    private var lastHopCheck: CFTimeInterval = 0
    private struct Leap {
        var start: CFTimeInterval
        var arc: HopArc
    }
    private var leap: Leap?
    /// Set by the app: Chilk is busy (a conversation, a notice, a request, the popover…) — a leap waits for the end.
    var hopBusy: () -> Bool = { false }
    var log: (String) -> Void = { _ in }
    /// Acceptance only: CHILK_DEMO_HOP=<s> — a virtual monitor to the right becomes active after <s> for 8 s.
    private lazy var demoHopAt: Double? = env["CHILK_DEMO_HOP"].flatMap(Double.init).map { CACurrentMediaTime() + $0 }

    // Slice 9d: the desktops (Spaces).
    /// Settings → Экран → «Жить на одном столе».
    var oneDesk: () -> Bool = { false }
    /// Set by the app: an overlay shown on every desktop holds him (the shade, the pause, a guided break, a game).
    var everywhere: () -> Bool = { false }
    /// Set by the app: the tray popover or a game has taken him (`.away` is theirs then, not the dive's) — he does not
    /// change desktops, and a dive's place is not given back over their head (review 9d).
    var heldElsewhere: () -> Bool = { false }
    private var desks = DeskKeeper()
    /// One desk: the marker of his home desktop, and the monitor it was put on.
    private var homeMarker: NSPanel?
    private var homeMarkerDisplay: String?
    /// 1: he is already behind the edge; the window moves to the active desktop on the next frame (after that pose is
    /// drawn, so the old one never flashes there).
    private var arriving = 0
    private var arrivedAt: CFTimeInterval?
    /// The dive home was ours (`standOut` set to `.away`): give him back his place afterwards.
    private var divedForDesk = false
    private var lastDeskStep: CFTimeInterval = 0
    private var lastDeskRead: CFTimeInterval = 0
    /// Read the desktops every step until then (after a switch and after his own moves); otherwise once a second.
    private var deskWatchUntil: CFTimeInterval = 0
    private var onActiveDesk = true
    private var homeDeskActive = true
    private var spaceObserver: NSObjectProtocol?
    /// The watchdog (review 9d): steps the desks while his window is not on the active desktop or one desk is on — his
    /// display link may stop there, and an errand must still bring him.
    private var deskWatchdog: Timer?
    /// Who is stepping the desks now (the log says whether a frame or a timer brought him).
    private var deskStepper = "frame"
    /// The desk demo's own clock (its steps must run while the demo stops the frames).
    private var demoTimer: Timer?
    /// Acceptance only (isolated state dir): CHILK_DEMO_DESKS="3:space,6:call,…" — virtual desktops (the agent
    /// cannot swipe): the same handler as a real switch runs; the window is made transparent while «not on» the
    /// virtual active desktop. Steps: `space` (the next desktop), `home`, `onedesk` / `follow` (the setting), `call`
    /// (his «called» line only), `hotkey` (the hotkey's path: a conversation), `cheer`, `due` (a water request), `notify`
    /// (posts the system's notification: the real observer, real desktops), `freeze` / `thaw` (stop / resume his frames,
    /// as on a desktop nobody sees).
    private struct DemoDesks {
        var steps: [(at: Double, action: String)]
        var active = 0, panel = 0, home = 0, next = 1
        var all = false
        /// After the first virtual switch; before it the real desktops are read.
        var virtual = false
    }
    private lazy var demoDesks: DemoDesks? = {
        guard AppState.isolated != nil, let raw = env["CHILK_DEMO_DESKS"], !raw.isEmpty else { return nil }
        let start = CACurrentMediaTime()
        let steps = raw.split(separator: ",").compactMap { part -> (Double, String)? in
            let bits = part.split(separator: ":", maxSplits: 1).map(String.init)
            guard bits.count == 2, let t = Double(bits[0]) else { return nil }
            return (start + t, bits[1])
        }
        return DemoDesks(steps: steps)
    }()
    /// Acceptance only: the desk demo's «onedesk» / «follow» and «due» steps (wired by the app to the settings and
    /// the balance — the same paths a click takes).
    var demoSetOneDesk: (Bool) -> Void = { _ in }
    var demoErrand: () -> Void = {}
    var demoHotkey: () -> Void = {}
    var demoCheer: () -> Void = {}

    private let env = ProcessInfo.processInfo.environment
    /// Measurement switch: behave as if the cursor were far away (no hover / gaze tracking).
    private lazy var ignorePointer = env["CHILK_IGNORE_POINTER"] != nil
    /// Frame rate while nothing moves fast (breathing, slow leaf sway). With the layer rig a frame costs
    /// almost nothing, so this is about smoothness, not CPU.
    private lazy var idleFPS = env["CHILK_IDLE_FPS"].flatMap(Double.init) ?? 30

    private struct Drag {
        var start: CGPoint          // mouse, screen coordinates
        var grabOffset: CGPoint     // mouse − panel origin
        var moved = false
        var lastX: CGFloat
    }

    var edge: Edge { placement.edge }
    /// Settings → screen (slice 5c): follow the active screen or stay on a pinned one.
    var screenChoice: () -> ScreenChoice = { .follow }
    /// His window on screen (the long-answer panel opens beside it).
    var windowFrame: NSRect { panel.frame }

    /// Slice 10 (Б6, decision 14): him plus the widest bubble beside him, on screen — a window that opens «beside him» («Лист
    /// дня», «Подробнее», «Изменить») goes past it, so a bubble never lands on the window. The widest bubble is the scene's
    /// width less 20 (`BubbleLayout`), `bubbleGap` clear of his body; 30 pt more for the windows' own overlap.
    var besideFrame: NSRect {
        // Review 10c: from the furthest he stands out with a bubble (`.out`), not where he is now — a sheet opened while he
        // is home must not get a bubble on it when he steps out; plus the lean out from behind the edge.
        let x = min(Double(sim.pose.x), metrics.outX)
        let far = x - metrics.radiusX - ChilkRenderer.bubbleGap - (metrics.width - 20) - 30
        var r = CGRect(x: far, y: 0, width: metrics.width - far, height: metrics.height)
        if isMirrored { r.origin.x = metrics.width - r.maxX }
        return screenRect(fromScene: r)
    }

    /// A rect of the scene (canonical y-down coordinates, already mirrored like `ChilkRenderer.buttonRects`) on the
    /// screen — the name field sits exactly over a bubble button slot (slice 5a).
    func screenRect(fromScene r: CGRect) -> NSRect {
        NSRect(x: sceneOrigin.x + r.minX, y: sceneOrigin.y + metrics.sceneSize.height - r.maxY, width: r.width, height: r.height)
    }

    /// Bubble buttons where they are right now (scene coordinates, mirrored for the left edge).
    var buttonRects: [(index: Int, rect: CGRect)] {
        ChilkRenderer.buttonRects(pose: sim.pose, metrics: metrics, mirrored: isMirrored)
    }

    override init() {
        sim = CharacterSim(metrics: metrics)
        placement = PlacementStore.load()
        panel = EdgePanel(size: metrics.sceneSize)
        view = CharacterView(frame: NSRect(origin: .zero, size: metrics.sceneSize),
                             vector: ProcessInfo.processInfo.environment["CHILK_CG_RENDER"] != nil)
        super.init()
        panel.contentView = view
        view.onMouseDown = { [weak self] _ in self?.mouseDown() }
        view.onMouseDragged = { [weak self] _ in self?.mouseDragged() }
        view.onMouseUp = { [weak self] _ in self?.mouseUp() }
        let origin = targetOrigin()
        originX = Spring(origin.x, stiffness: 110, damping: 17)
        originY = Spring(origin.y, stiffness: 110, damping: 17)
        sceneOrigin = origin
        present()
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.deskSwitched(demo: nil) }
        }
        if demoDesks != nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.runDemoDesks(now: CACurrentMediaTime()) }
            }
            RunLoop.main.add(timer, forMode: .common)
            demoTimer = timer
        }
    }

    func show() {
        panel.orderFrontRegardless()
        if env["CHILK_TIMER_DRIVER"] != nil {
            // Measurement mode: frames keep coming even while the display sleeps (CADisplayLink stops).
            restartTimer(fps: 60)
            return
        }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func callChilk() {
        sim.call(line: Lines.called.randomElement()!)
    }

    func move(to edge: Edge) {
        placement = EdgePlacement(edge: edge, verticalFraction: placement.verticalFraction)
    }

    // MARK: Frame loop

    @objc private func tick(_ link: CADisplayLink) {
        frame(now: link.timestamp)
    }

    private func frame(now: CFTimeInterval) {
        let cpuStart = stats == nil ? 0 : clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let gap = max(0, now - (lastTimestamp ?? now))
        let dt = min(1.0 / 30, gap)
        lastTimestamp = now
        if stats != nil, gap > 0 { stats?.gaps.append(gap) }

        if arriving == 1 { finishArrival(now: now) }
        if now - lastDeskStep >= 0.1 {
            lastDeskStep = now
            stepDesks(now: now)
        }
        if now - lastHopCheck >= 0.1, drag == nil, flight == nil, leap == nil, arriving == 0 {
            lastHopCheck = now
            stepHop(now: now)
        }
        if let l = leap {
            leapStep(l, now: now)
        } else if let f = flight {
            flyStep(f, now: now)
        } else if drag == nil {
            if (sim.standOut == .center) != centered {
                // Re-anchor without a jump (centred in his window, like when carried), then glide there.
                centered.toggle()
                _ = reframe(to: centered ? metrics.carryX : metrics.dockX, mirrored: isMirrored)
            }
            let target = targetOrigin()
            originX.target = target.x
            originY.target = target.y
            originX.step(dt / 2); originY.step(dt / 2)
            originX.step(dt / 2); originY.step(dt / 2)
            let origin = CGPoint(x: originX.value.rounded(), y: originY.value.rounded())
            sceneOrigin = origin
            carryVelocity = originX.velocity
        }

        let mirrored = isMirrored
        let raw = viewport.scenePoint(screenPoint: NSEvent.mouseLocation, sceneOrigin: sceneOrigin)
        var local = raw
        if mirrored { local.x = metrics.width - local.x }

        sim.step(dt: dt, pointer: ignorePointer ? nil : local, carryVelocity: mirrored ? -carryVelocity : carryVelocity)

        // Button plans and body hit testing stay in canonical scene coordinates as the canvas expands.
        let hit = ChilkRenderer.buttonRects(pose: sim.pose, metrics: metrics, mirrored: mirrored)
            .first { $0.rect.insetBy(dx: -2, dy: -2).contains(raw) }?.index
        if sim.hoveredButton != hit { sim.hoveredButton = hit }
        // The stretch hint's hops let clicks through to the window under him (6a, decision 5).
        let interactive = drag != nil || pressedButton != nil || hit != nil || (sim.contains(local) && !sim.passesClicks)
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }

        present()

        // 60 fps only while something moves fast.
        let busy = sim.isBusy || drag != nil || flight != nil || leap != nil || abs(originX.velocity) > 2
            || abs(originY.velocity) > 2
        if busy != lastBusy {
            let idle = Float(idleFPS)
            link?.preferredFrameRateRange = busy
                ? CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                : CAFrameRateRange(minimum: min(10, idle), maximum: idle, preferred: idle)
            if driverTimer != nil { restartTimer(fps: busy ? 60 : idleFPS) }
            lastBusy = busy
            stats?.switches += 1
        }
        if stats != nil { record(now: now, cpu: clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) }
        trace(now: now, dt: dt)
    }

    // MARK: Debug trace (CHILK_POSE_TRACE=/abs/path.tsv): one line per frame — the body's placement and the panel frame.
    // CHILK_DEMO_SLEEP=<s>[,<s>]: he falls asleep that many seconds after launch, then (optionally) wakes up — the
    // shake-at-sleep diagnosis (acceptance 2026-10-06).

    private lazy var traceHandle: FileHandle? = {
        guard let path = env["CHILK_POSE_TRACE"], path.hasPrefix("/") else { return nil }
        FileManager.default.createFile(atPath: path, contents: Data("t\tdt\ttx\tty\ta\tb\tc\td\tpx\tpy\tpw\tph\ttilt\thop\tsy\tsleep\n".utf8))
        return FileHandle(forWritingAtPath: path)
    }()
    private lazy var demoSleep: [Double] = (env["CHILK_DEMO_SLEEP"] ?? "").split(separator: ",")
        .compactMap { Double($0) }.map { CACurrentMediaTime() + $0 }

    private func trace(now: CFTimeInterval, dt: Double) {
        if let at = demoSleep.first, now >= at {
            if sim.isAsleep { sim.wakeUp() } else { sim.fallAsleep() }
            demoSleep.removeFirst()
        }
        guard let handle = traceHandle else { return }
        let p = sim.pose
        let plan = ChilkRenderer.placements(pose: p, metrics: metrics, mirrored: isMirrored)
        let t = plan.first { $0.slot == Slot.body }?.transform ?? .identity
        let e = plan.first { $0.slot == Slot.eye }?.transform ?? .identity
        let h = plan.first { $0.slot == Slot.hat }?.transform ?? .identity
        let f = panel.frame
        let line = String(format: "%.4f\t%.4f\t%.3f\t%.3f\t%.4f\t%.4f\t%.4f\t%.4f\t%.1f\t%.1f\t%.1f\t%.1f\t%.4f\t%.3f\t%.4f\t%.2f\t%.3f\t%.3f\t%.3f\t%.3f\t%d\n",
                          now, dt, t.tx, t.ty, t.a, t.b, t.c, t.d, f.minX, f.minY, f.width, f.height, p.tilt, p.hop, p.scaleY, p.sleep,
                          e.tx, e.ty, h.tx, h.ty, plan.count)
        handle.write(Data(line.utf8))
    }

    private func restartTimer(fps: Double) {
        driverTimer?.invalidate()
        let timer = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.frame(now: CACurrentMediaTime()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        driverTimer = timer
    }

    /// While dragged he turns to face the screen side he is closer to (he is centred in the panel then,
    /// so turning around never moves him).
    private var isMirrored: Bool {
        if drag?.moved == true {
            return sceneFrame.midX < visibleFrame.midX
        }
        return flight?.mirrored ?? (placement.edge == .left)
    }

    // MARK: Debug stats (CHILK_DEBUG=/abs/path.log): frames/s, CPU per frame, why 60 fps

    private struct Stats {
        var since: CFTimeInterval?
        var frames = 0
        var cpuNanos: UInt64 = 0
        var reasons: [String: Int] = [:]
        /// Frame pacing: raw intervals between frames, and how often the 60 / idle rate was switched.
        var gaps: [Double] = []
        var switches = 0
        var lastProps = ""
        var propChanges: [String] = []
    }

    private lazy var stats: Stats? = env["CHILK_DEBUG"] != nil ? Stats() : nil

    private func record(now: CFTimeInterval, cpu: UInt64) {
        guard var s = stats else { return }
        s.frames += 1
        s.cpuNanos += cpu
        let props = sim.props.map(\.rawValue).sorted().joined(separator: "+")
        if props != s.lastProps { s.propChanges.append(props.isEmpty ? "-" : props); s.lastProps = props }
        s.reasons[sim.busyReason ?? (drag != nil ? "drag" : (abs(originX.velocity) > 2 || abs(originY.velocity) > 2 ? "panel moving" : "idle")), default: 0] += 1
        defer { stats = s }
        guard let since = s.since else { s.since = now; return }
        let span = now - since
        guard span >= 2 else { return }
        let reasons = s.reasons.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let g = s.gaps.sorted()
        let pacing = g.isEmpty ? "" : String(format: " | gaps ms min %.1f med %.1f max %.1f, >40ms %d, >1/30 clamped %d, rate switches %d",
                                             g[0] * 1000, g[g.count / 2] * 1000, g[g.count - 1] * 1000,
                                             g.filter { $0 > 0.040 }.count, g.filter { $0 > 1.0 / 30 + 0.001 }.count, s.switches)
        let line = String(format: "%.0f s: frames %.1f/s, frame cpu %.3f ms, %@ | %@%@\n",
                          now, Double(s.frames) / span, Double(s.cpuNanos) / Double(max(1, s.frames)) / 1e6,
                          view.isVector ? "vector" : "rig", reasons, pacing)
        if let path = env["CHILK_DEBUG"], path.hasPrefix("/"),
           let h = FileHandle(forWritingAtPath: path) ?? (FileManager.default.createFile(atPath: path, contents: nil) ? FileHandle(forWritingAtPath: path) : nil) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            NSLog("chilk %@", line)
        }
        if !s.propChanges.isEmpty {
            let changes = "  props: \(s.propChanges.prefix(12).joined(separator: " → ")) (\(s.propChanges.count))\n"
            if let path = env["CHILK_DEBUG"], let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile(); h.write(Data(changes.utf8)); try? h.close()
            }
        }
        s = Stats(since: now, lastProps: s.lastProps)
    }

    // MARK: Mouse (only reaches us over the body)

    private func mouseDown() {
        if let i = sim.hoveredButton {
            pressedButton = i
            return
        }
        let m = NSEvent.mouseLocation
        guard flight == nil, leap == nil else { return }
        drag = Drag(start: m, grabOffset: CGPoint(x: m.x - sceneOrigin.x, y: m.y - sceneOrigin.y), lastX: sceneOrigin.x)
    }

    private func mouseDragged() {
        guard pressedButton == nil, var d = drag else { return }
        let m = NSEvent.mouseLocation
        if !d.moved && hypot(m.x - d.start.x, m.y - d.start.y) > 4 {
            // Picked up: centre him in the panel and move the panel the other way, so nothing jumps on screen
            // and the panel's edges (invisible away from the screen edge) never cut him.
            let shift = reframe(to: metrics.carryX, mirrored: isMirrored)
            d.grabOffset.x -= shift
            d.moved = true
            sim.isCarried = true
        }
        if d.moved {
            let screen = home.frame
            var origin = CGPoint(x: m.x - d.grabOffset.x, y: m.y - d.grabOffset.y)
            // Most of him can go behind either edge (6d: more than half hides him), a sliver stays to grab.
            let range = EdgePlacement.carryRangeX(screen: screen, panelWidth: metrics.sceneSize.width, radiusX: metrics.radiusX)
            origin.x = min(max(origin.x, range.lowerBound), range.upperBound)
            origin.y = min(max(origin.y, screen.minY), screen.maxY - metrics.sceneSize.height)
            carryVelocity = Double(origin.x - d.lastX) * 60
            d.lastX = origin.x
            sceneOrigin = origin
            originX.value = origin.x; originX.velocity = 0
            originY.value = origin.y; originY.velocity = 0
        }
        drag = d
        present()
    }

    private func mouseUp() {
        if let i = pressedButton {
            pressedButton = nil
            if sim.hoveredButton == i { onButton?(i) }
            return
        }
        guard let d = drag else { return }
        drag = nil
        if d.moved {
            sim.isCarried = false
            // He is centred, so the panel centre is his position: the nearer edge wins.
            placement = .dropped(panelOrigin: sceneOrigin, panelSize: metrics.sceneSize, visibleFrame: visibleFrame)
            let centreX = sceneOrigin.x + metrics.sceneSize.width / 2
            if EdgePlacement.hidingEdge(bodyCenterX: centreX, visibleFrame: visibleFrame) != nil {
                // Slice 6d: behind the edge. Re-anchor at his usual panel place (so the «пф!» is at the real screen
                // edge), then he dives the rest of the way.
                let standard = placement.panelOrigin(panelSize: metrics.sceneSize, visibleFrame: visibleFrame)
                let mirrored = placement.edge == .left
                let local = Double(mirrored ? standard.x + metrics.sceneSize.width - centreX : centreX - standard.x)
                _ = reframe(to: local, mirrored: mirrored)
                originX.velocity = 0
                onHideDrop?()
                return
            }
            _ = reframe(to: metrics.dockX, mirrored: placement.edge == .left)
            originX.velocity = carryVelocity * 0.5   // a little fling towards the edge
            if sim.hidden { onPullOut?() }
        } else {
            sim.poke()
            onPoke?()
        }
    }

    // MARK: Eye gymnastics flight

    /// A figure-eight over the screen, then back to exactly where he was.
    func fly(duration: Double, completion: @escaping () -> Void) {
        guard drag == nil, flight == nil, leap == nil else { return completion() }
        let mirrored = isMirrored
        // No one-off re-centering: the shared viewport already encloses every animated part.
        flight = Flight(start: CACurrentMediaTime(), duration: duration, from: sceneOrigin, mirrored: mirrored, completion: completion)
    }

    private func flyStep(_ f: Flight, now: CFTimeInterval) {
        let k = (now - f.start) / f.duration
        guard k < 1 else {
            flight = nil
            sceneOrigin = f.from
            originX.value = f.from.x
            originX.velocity = 0
            originY.value = f.from.y
            originY.velocity = 0
            carryVelocity = 0
            f.completion()
            return
        }
        let vf = visibleFrame
        let a = k * 4 * .pi                                        // two loops
        let anchorX = f.mirrored ? metrics.width - sim.positionX : sim.positionX
        let anchorY = metrics.height - Double(sim.bodyCenter.y)
        let eight = CGPoint(x: vf.midX - anchorX + vf.width * 0.3 * sin(a),
                            y: vf.midY - anchorY + vf.height * 0.22 * sin(2 * a) / 2)
        func smooth(_ x: Double) -> Double { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }
        let w = min(smooth(k / 0.15), smooth((1 - k) / 0.15))      // ease out of the edge and back into it
        let origin = CGPoint(x: (f.from.x + (eight.x - f.from.x) * w).rounded(), y: (f.from.y + (eight.y - f.from.y) * w).rounded())
        carryVelocity = Double(origin.x - sceneOrigin.x) * 60
        sceneOrigin = origin
        originX.value = origin.x
        originY.value = origin.y
    }

    /// Re-anchor the carry pose without a jump in screen coordinates. This is NOT a clipping fix:
    /// all poses (including the return to the edge) use the same paint viewport.
    private func reframe(to x: Double, mirrored: Bool) -> Double {
        let shift = metrics.panelShiftKeepingPlace(fromX: sim.positionX, toX: x, mirrored: mirrored)
        sim.reframe(x: x)
        var origin = sceneOrigin
        origin.x += shift
        sceneOrigin = origin
        originX.value = origin.x
        present()
        return shift
    }

    /// One paint rule for every state: render all parts, never crop at an invisible scene edge.
    /// The enlarged window and both renderers share the exact same plan and coordinate mapping.
    private func present() {
        // Review 10e: the pinned card knows how much screen there is over the scene (none — it goes under the bubble).
        sim.cardHeadroom = Double(homeVisibleFrame.maxY - (sceneOrigin.y + metrics.sceneSize.height))
        let plan = ChilkRenderer.placements(pose: sim.pose, metrics: metrics, mirrored: isMirrored)
        viewport = SceneViewport(metrics: metrics, placements: plan)
        let frame = viewport.panelFrame(sceneOrigin: sceneOrigin)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        view.show(plan: plan, viewport: viewport)
        demoSnapshot()
        CATransaction.commit()
    }

    /// Acceptance only: CHILK_DEMO_EDGE_SNAPSHOT=/dir writes the live rig every 0.3 s while an emotion plays or he is
    /// petted (slice 6c), at most 200 frames.
    private lazy var edgeSnapshots: URL? = env["CHILK_DEMO_EDGE_SNAPSHOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    private var lastEdgeSnapshot = 0.0
    private var edgeSnapshotCount = 0

    private func demoSnapshot() {
        guard let dir = edgeSnapshots, edgeSnapshotCount < 200 else { return }
        let m = sim.pose.mood
        // 6d: also while he peeks from behind the edge, the «пф!» is in the air, or hidden he is out for a while.
        let hidingShown = sim.standOut == .lurk || sim.pose.puffAge != nil || (sim.hidden && !sim.isHiddenHome)
        guard sim.isEmoting || m.petted || m.winking || hidingShown || leap != nil || (sim.act?.isDance ?? false) else { return }
        let now = CACurrentMediaTime()
        guard now - lastEdgeSnapshot >= (leap != nil ? 0.1 : 0.3) else { return }
        lastEdgeSnapshot = now
        edgeSnapshotCount += 1
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        view.snapshot(to: dir.appending(path: String(format: "edge-%03d.png", edgeSnapshotCount)))
        // 6d: where he is — the layer snapshot has no screen edge in it.
        let line = String(format: "%03d x=%.0f width=%.0f standOut=%@ hiddenHome=%d puff=%d origin=%.0f,%.0f act=%@\n", edgeSnapshotCount,
                          sim.positionX, metrics.width, "\(sim.standOut)", sim.isHiddenHome ? 1 : 0,
                          sim.pose.puffAge != nil ? 1 : 0, sceneOrigin.x, sceneOrigin.y, "\(sim.act.map { "\($0)" } ?? "-")")
        if let h = try? FileHandle(forWritingTo: dir.appending(path: "frames.txt")) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: dir.appending(path: "frames.txt"))
        }
    }

    // MARK: Another monitor (slice 6e)

    private func displays() -> [Display] {
        var list = NSScreen.screens.compactMap { s in
            Self.uuid(of: s).map { Display(id: $0, frame: s.frame, visibleFrame: s.visibleFrame, builtin: Self.isBuiltin(s)) }
        }
        if demoHopAt != nil, let main = list.first {
            let dx = main.frame.width
            list.append(Display(id: "demo-virtual", frame: main.frame.offsetBy(dx: dx, dy: 0),
                                visibleFrame: main.visibleFrame.offsetBy(dx: dx, dy: 0)))
        }
        return list
    }

    /// The monitor with the active window (the demo's virtual one during its 8 s).
    private func activeDisplay(now: CFTimeInterval) -> String? {
        if let at = demoHopAt, now >= at, now < at + 8 { return "demo-virtual" }
        return (NSScreen.main).flatMap(Self.uuid)
    }

    private func stepHop(now: CFTimeInterval) {
        let list = displays()
        var pinned: String?
        if case .pinned(let id, _) = screenChoice() { pinned = id }
        // Hidden at home nobody sees him move, whatever else is going on.
        // A peek or the «пф!» is seen: wait for it (only hidden at home he moves over unseen).
        let busy = !sim.isHiddenHome && (hopBusy() || centered || sim.act != nil || sim.isCarried
                                         || sim.standOut == .lurk || sim.pose.puffAge != nil)
        // 9d (decision 31): pinned, an errand still brings him to the active monitor (not stages 3–4: centred there).
        let errand = pinned != nil && onErrand && !onEveryDesk
        let step = hop.step(active: activeDisplay(now: now), connected: list.map(\.id), now: now, busy: busy,
                            hidden: sim.isHiddenHome, pinned: pinned, errand: errand)
        homeDisplay = list.first { $0.id == hop.home } ?? homeDisplay      // also picks up a new resolution
        switch step {
        case .stay:
            break
        case .move(let id):
            let o = targetOrigin()
            sceneOrigin = o
            originX.value = o.x; originX.velocity = 0
            originY.value = o.y; originY.velocity = 0
            present()
            log("screen: on \(id.prefix(8))\(sim.hidden ? " (hidden, moved over)" : "")")
            rehome()
        case .visit(let id):
            // He is needed there now: behind that monitor's edge at once, then he peeks out (no leap to wait for).
            let o = targetOrigin()
            sceneOrigin = o
            originX.value = o.x; originX.velocity = 0
            originY.value = o.y; originY.velocity = 0
            if !centered { sim.reframe(x: metrics.awayX) }
            present()
            log("screen: errand on \(id.prefix(8)) — peeks out there")
        case .hop(let id):
            let from = sceneOrigin, to = targetOrigin()
            let arc = HopArc(from: from, to: to)
            let dx = Double(to.x - from.x)
            sim.perform(.leap(seconds: arc.total, dir: (isMirrored ? -dx : dx) >= 0 ? 1 : -1))
            leap = Leap(start: now, arc: arc)
            log(String(format: "screen: leap to %@, %.2f s in the air, %.0f pt", String(id.prefix(8)), arc.flight,
                       hypot(dx, Double(to.y - from.y))))
        }
    }

    private func leapStep(_ l: Leap, now: CFTimeInterval) {
        let t = now - l.start
        let p = t >= l.arc.total ? l.arc.to : l.arc.point(at: t)
        sceneOrigin = CGPoint(x: p.x.rounded(), y: p.y.rounded())
        originX.value = p.x; originX.velocity = 0
        originY.value = p.y; originY.velocity = 0
        carryVelocity = 0
        // Decision 21: over a gap in the layout he is gone for a moment — the screens' real edge.
        let body = bodyOnScreen
        let over = displays().contains { $0.frame.insetBy(dx: -1, dy: -1).contains(body) }
        panel.alphaValue = over || t >= l.arc.total ? 1 : 0
        if t >= l.arc.total {
            leap = nil
            log("screen: landed")
            rehome()
        }
    }

    // MARK: Desktops (slice 9d, decisions 30–31)

    /// The one place that says he has business with the user (`DeskKeeper.onErrand`): something that waits for the
    /// user — a bubble with buttons or with no end, a request's pantomime, out of his spot for a talk or a card, stage 3.
    var onErrand: Bool { DeskKeeper.onErrand(standOut: sim.standOut, bubbleWaits: sim.bubbleWaits, act: sim.act) }

    /// Shown on every desktop as before 9d: stages 3–4 (in the middle / above the pause), the shade, a guided break or a
    /// game (the app: the court and the notebook hold him), the eye-gymnastics flight, the disco dance (the ball is on
    /// every desktop) — a swipe never reframes him mid-throw or mid-dance.
    private var onEveryDesk: Bool { everywhere() || centered || raised || flight != nil || sim.act?.isDance == true }

    /// The active desktop changed (a swipe, Mission Control, a full-screen app) — or the demo's virtual one did.
    private func deskSwitched(demo desk: Int?) {
        deskWatchUntil = CACurrentMediaTime() + 2
        readDesks()
        log("desk: switched\(desk.map { " (demo desk \($0))" } ?? "") — he is \(onActiveDesk ? "here" : "not here")"
            + (homeMarker != nil ? ", home \(homeDeskActive ? "is" : "is not") this desk" : ""))
        // Answer right away, not from the frame loop: his display link may be paused while his window is on a desktop
        // nobody sees.
        let now = CACurrentMediaTime()
        lastDeskStep = now
        deskStepper = "switch"
        stepDesks(now: now)
        deskStepper = "frame"
        // The system may still answer for the old desktop at the notification: read again a little later (frames or not).
        for delay in DeskKeeper.rereadsAfterSwitch {
            later(delay) { [weak self] in self?.watchdogStep(why: "re-read") }
        }
    }

    /// One step from a timer, not from a frame: read the desktops afresh and decide.
    private func watchdogStep(why: String) {
        let now = CACurrentMediaTime()
        let was = onActiveDesk
        lastDeskStep = now
        lastDeskRead = now
        readDesks()
        if was != onActiveDesk { log("desk: \(why) — he is \(onActiveDesk ? "here" : "not here") now") }
        deskStepper = why
        stepDesks(now: now)
        deskStepper = "frame"
    }

    /// The watchdog runs only while it is needed (`DeskKeeper.needsWatchdog`).
    private func updateWatchdog() {
        let need = DeskKeeper.needsWatchdog(onActive: onActiveDesk)
        if need, deskWatchdog == nil {
            let timer = Timer(timeInterval: DeskKeeper.watchdogInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.watchdogStep(why: "watchdog") }
            }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            deskWatchdog = timer
        } else if !need, let timer = deskWatchdog {
            timer.invalidate()
            deskWatchdog = nil
        }
    }

    /// A one-shot timer that also fires while a menu is open (`.common`).
    private func later(_ seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { action() } }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func readDesks() {
        if let d = demoDesks, d.virtual {
            onActiveDesk = d.all || d.panel == d.active
            homeDeskActive = homeMarker == nil || d.home == d.active
            let alpha: CGFloat = onActiveDesk ? 1 : 0
            if leap == nil, panel.alphaValue != alpha { panel.alphaValue = alpha }
        } else {
            onActiveDesk = panel.isOnActiveSpace
            homeDeskActive = homeMarker?.isOnActiveSpace ?? true
        }
    }

    private func stepDesks(now: CFTimeInterval) {
        let oneDesk = oneDesk()
        if oneDesk, homeMarker == nil {
            makeHome()
            log("desk: one desk — home is this desktop")
        } else if !oneDesk, let marker = homeMarker {
            marker.orderOut(nil)
            homeMarker = nil
            log("desk: follows you again")
        }
        if now < deskWatchUntil || now - lastDeskRead >= 1 {
            lastDeskRead = now
            readDesks()
        }
        let situation = DeskKeeper.Situation(
            mode: oneDesk ? .oneDesk : .follow, onActive: onActiveDesk, homeActive: homeDeskActive, errand: onErrand,
            everywhere: onEveryDesk,
            canMove: drag == nil && leap == nil && flight == nil && arriving == 0 && !heldElsewhere(), now: now)
        defer { updateWatchdog() }
        switch desks.step(situation) {
        case .stay:
            break
        case .allDesks:
            // An arrival in flight is dropped: on every desktop he is here already (and `.moveToActiveSpace` must never
            // meet `.canJoinAllSpaces`). A dive of ours is over too — he stays where the user is.
            arriving = 0
            giveBackHisPlace()          // a dive cut short by the dance or a flight must not leave him away (re-review 9d)
            panel.collectionBehavior = EdgePanel.allDesks
            demoDesks?.all = true
            log("desk: on every desktop (\(centered ? "stage 3–4" : flight != nil ? "flight" : "overlay"))")
        case .oneDeskAgain:
            panel.collectionBehavior = EdgePanel.oneDesk
            if var d = demoDesks { d.all = false; d.panel = d.active; demoDesks = d }
            log("desk: one desktop again — this one")
            watchDesks(now)
        case .arrive:
            // Behind the edge first; the window follows on the next frame and he peeks out (like after the popover).
            if !centered { sim.reframe(x: metrics.awayX) }
            present()
            arriving = 1
            // The window moves once this pose is drawn: the next frame, or this timer if frames are paused.
            later(1.0 / 30) { [weak self] in self?.finishArrival(now: CACurrentMediaTime()) }
            log("desk: comes here\(oneDesk ? (onErrand ? " on an errand" : " (home)") : "") — from behind the edge"
                + " [\(deskStepper)]")
        case .leave:
            if sim.standOut == .docked {
                sim.standOut = .away
                divedForDesk = true
            }
            log("desk: errand over — dives behind the edge")
        case .stopLeaving:
            giveBackHisPlace()
            log("desk: another errand — stays here")
        case .sendHome:
            if let marker = homeMarker { panel.move(toDeskOf: marker) }
            if var d = demoDesks { d.panel = d.home; demoDesks = d }
            giveBackHisPlace()
            watchDesks(now)
            readDesks()
            log("desk: went home [\(deskStepper)]")
        }
    }

    private func finishArrival(now: CFTimeInterval) {
        guard arriving == 1 else { return }
        arriving = 0
        if !centered { sim.reframe(x: metrics.awayX) }
        present()
        panel.moveToActiveDesk()
        if var d = demoDesks { d.panel = d.active; demoDesks = d }
        watchDesks(now)
        readDesks()
        arrivedAt = now
        // The user's log should show it if the system did not take him over (the keeper then tries again).
        if !onActiveDesk { log("desk: the window is still not on this desktop after the move") }
    }

    private func watchDesks(_ now: CFTimeInterval) { deskWatchUntil = max(deskWatchUntil, now + 1) }

    /// After our dive: back at his spot — unless the popover or a game took him meanwhile (their `.away`, not ours).
    private func giveBackHisPlace() {
        if divedForDesk, sim.standOut == .away, !heldElsewhere() { sim.standOut = .docked }
        divedForDesk = false
    }

    /// One desk: home is the active desktop on the monitor he lives on.
    private func makeHome() {
        homeMarker?.orderOut(nil)
        homeMarker = EdgePanel.homeMarker(at: home.frame.origin)
        homeMarkerDisplay = home.id
        if var d = demoDesks { d.home = d.active; demoDesks = d }
        watchDesks(CACurrentMediaTime())
    }

    /// He moved to another monitor for good (6e): one desk — home is the desktop he landed on.
    private func rehome() {
        guard homeMarker != nil, homeMarkerDisplay != home.id else { return }
        makeHome()
        log("desk: home moved with him to this monitor's desktop")
    }

    /// The desk demo: virtual switches and errands, plus how far out he is 0.4 s after an arrival.
    private func runDemoDesks(now: CFTimeInterval) {
        if let at = arrivedAt, now - at >= 0.4 {
            arrivedAt = nil
            log(String(format: "desk: %@ 0.4 s after arriving (x %.0f; his spot %.0f, behind the edge %.0f)",
                       sim.positionX < metrics.awayX - 40 ? "peeking out" : "still behind the edge",
                       sim.positionX, metrics.dockX, metrics.awayX))
        }
        guard var d = demoDesks, let step = d.steps.first, now >= step.at else { return }
        d.steps.removeFirst()
        demoDesks = d
        switch step.action {
        case "space":
            d.virtual = true
            d.active = d.next
            d.next += 1
            demoDesks = d
            deskSwitched(demo: d.active)
        case "home":
            d.virtual = true
            d.active = d.home
            demoDesks = d
            deskSwitched(demo: d.active)
        case "notify":                                     // the real observer: the system's notification, posted here
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        case "onedesk": demoSetOneDesk(true)
        case "follow": demoSetOneDesk(false)
        case "call": callChilk()
        case "hotkey": demoHotkey()
        case "cheer": demoCheer()
        case "due": demoErrand()
        case "freeze":
            link?.isPaused = true
            driverTimer?.invalidate()
            driverTimer = nil
            log("desk demo: frames stopped (as on a desktop nobody sees)")
        case "thaw":
            link?.isPaused = false
            if link == nil { restartTimer(fps: 60) }
            log("desk demo: frames again")
        default: log("desk demo: unknown step \(step.action)")
        }
    }

    // MARK: Geometry

    private var visibleFrame: CGRect { home.visibleFrame }

    /// The monitor he lives on (6e: `ScreenHop` — the active one after a leap, or the pinned one while connected).
    private var home: Display {
        if let d = homeDisplay { return d }
        let s = NSScreen.main ?? NSScreen.screens[0]
        return Display(id: Self.uuid(of: s) ?? "", frame: s.frame, visibleFrame: s.visibleFrame, builtin: Self.isBuiltin(s))
    }

    /// He lives on the Mac's own display (6f).
    var homeIsBuiltin: Bool { home.builtin }

    /// 6f-2: his body centre on screen (AppKit, y-up) and the top of his screen's visible frame (the disco ball).
    var bodyOnScreen: CGPoint { screenPoint(scene: sim.bodyCenter) }
    var screenTop: CGFloat { visibleFrame.maxY }
    /// 7b: the visible frame of the monitor he lives on (the basketball hoop and the ball's flight stay on it).
    var homeVisibleFrame: CGRect { visibleFrame }

    /// A point of his scene (y down, docked to the right) on screen (AppKit, y up), mirrored at the left edge.
    func screenPoint(scene c: CGPoint) -> CGPoint {
        let x = isMirrored ? metrics.width - Double(c.x) : Double(c.x)
        return CGPoint(x: Double(sceneOrigin.x) + x, y: Double(sceneOrigin.y) + metrics.height - Double(c.y))
    }

    private static func isBuiltin(_ s: NSScreen) -> Bool {
        guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(CGDirectDisplayID(n.uint32Value)) != 0
    }

    private static var uuids: [CGDirectDisplayID: String] = [:]

    /// A display's UUID survives reconnects and reboots (unlike its number).
    static func uuid(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let id = CGDirectDisplayID(number.uint32Value)
        if let hit = uuids[id] { return hit }
        guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        let text = CFUUIDCreateString(nil, u) as String
        uuids[id] = text
        return text
    }

    private func targetOrigin() -> CGPoint {
        if centered {
            // The whole screen, not the visible frame: the pause hides the Dock and the menu bar.
            let f = home.frame
            return CGPoint(x: (f.midX - metrics.sceneSize.width / 2).rounded(), y: (f.midY - metrics.sceneSize.height / 2).rounded())
        }
        return placement.panelOrigin(panelSize: metrics.sceneSize, visibleFrame: visibleFrame)
    }
}

enum PlacementStore {
    private static let key = "edgePlacement"

    static func load() -> EdgePlacement {
        guard let data = UserDefaults.standard.data(forKey: key),
              let p = try? JSONDecoder().decode(EdgePlacement.self, from: data) else { return .default }
        return p
    }

    static func save(_ p: EdgePlacement) {
        if let data = try? JSONEncoder().encode(p) { UserDefaults.standard.set(data, forKey: key) }
    }
}
