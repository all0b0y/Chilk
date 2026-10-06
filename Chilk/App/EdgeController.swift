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
        let dt = min(1.0 / 30, max(0, now - (lastTimestamp ?? now)))
        lastTimestamp = now

        if now - lastHopCheck >= 0.1, drag == nil, flight == nil, leap == nil {
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
        }
        if stats != nil { record(now: now, cpu: clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) }
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
    }

    private lazy var stats: Stats? = env["CHILK_DEBUG"] != nil ? Stats() : nil

    private func record(now: CFTimeInterval, cpu: UInt64) {
        guard var s = stats else { return }
        s.frames += 1
        s.cpuNanos += cpu
        s.reasons[sim.busyReason ?? (drag != nil ? "drag" : (abs(originX.velocity) > 2 || abs(originY.velocity) > 2 ? "panel moving" : "idle")), default: 0] += 1
        defer { stats = s }
        guard let since = s.since else { s.since = now; return }
        let span = now - since
        guard span >= 2 else { return }
        let reasons = s.reasons.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let line = String(format: "%.0f s: frames %.1f/s, frame cpu %.3f ms, %@ | %@\n",
                          now, Double(s.frames) / span, Double(s.cpuNanos) / Double(max(1, s.frames)) / 1e6,
                          view.isVector ? "vector" : "rig", reasons)
        if let path = env["CHILK_DEBUG"], path.hasPrefix("/"),
           let h = FileHandle(forWritingAtPath: path) ?? (FileManager.default.createFile(atPath: path, contents: nil) ? FileHandle(forWritingAtPath: path) : nil) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            NSLog("chilk %@", line)
        }
        s = Stats(since: now)
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
        let busy = !sim.isHiddenHome && (hopBusy() || centered || sim.act != nil || sim.isCarried)
        let step = hop.step(active: activeDisplay(now: now), connected: list.map(\.id), now: now, busy: busy,
                            hidden: sim.hidden, pinned: pinned)
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
        if t >= l.arc.total {
            leap = nil
            log("screen: landed")
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
    var bodyOnScreen: CGPoint {
        let c = sim.bodyCenter
        let x = isMirrored ? metrics.width - Double(c.x) : Double(c.x)
        return CGPoint(x: Double(sceneOrigin.x) + x, y: Double(sceneOrigin.y) + metrics.height - Double(c.y))
    }
    var screenTop: CGFloat { visibleFrame.maxY }

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
