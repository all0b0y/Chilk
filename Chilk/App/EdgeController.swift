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
    private var link: CADisplayLink?
    private var driverTimer: Timer?
    private var lastTimestamp: CFTimeInterval?
    private var drag: Drag?
    private var carryVelocity = 0.0
    private var lastBusy: Bool?
    /// Bubble buttons and clicks on the body go to the balance controller.
    var onButton: ((Int) -> Void)?
    var onPoke: (() -> Void)?
    private var pressedButton: Int?
    private struct Flight {
        var start: CFTimeInterval
        var duration: Double
        var from: CGPoint
        var mirrored: Bool
        var completion: () -> Void
    }
    private var flight: Flight?

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
        panel.setFrameOrigin(origin)
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

        if let f = flight {
            flyStep(f, now: now)
        } else if drag == nil {
            let target = targetOrigin()
            originX.target = target.x
            originY.target = target.y
            originX.step(dt / 2); originY.step(dt / 2)
            originX.step(dt / 2); originY.step(dt / 2)
            let origin = CGPoint(x: originX.value.rounded(), y: originY.value.rounded())
            if origin != panel.frame.origin { panel.setFrameOrigin(origin) }
            carryVelocity = originX.velocity
        }

        let mirrored = isMirrored
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        var local = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
        if mirrored { local.x = metrics.sceneSize.width - local.x }

        sim.step(dt: dt, pointer: ignorePointer ? nil : local, carryVelocity: mirrored ? -carryVelocity : carryVelocity)

        // Bubble buttons: hover highlight and hit testing (rects are panel coordinates, already mirrored).
        let raw = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
        let hit = ChilkRenderer.buttonRects(pose: sim.pose, metrics: metrics, mirrored: mirrored)
            .first { $0.rect.insetBy(dx: -2, dy: -2).contains(raw) }?.index
        if sim.hoveredButton != hit { sim.hoveredButton = hit }
        let interactive = drag != nil || pressedButton != nil || hit != nil || sim.contains(local)
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }

        view.show(pose: sim.pose, mirrored: mirrored)

        // 60 fps only while something moves fast.
        let busy = sim.isBusy || drag != nil || flight != nil || abs(originX.velocity) > 2 || abs(originY.velocity) > 2
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
            return panel.frame.midX < visibleFrame.midX
        }
        return placement.edge == .left
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
        drag = Drag(start: m, grabOffset: CGPoint(x: m.x - panel.frame.minX, y: m.y - panel.frame.minY), lastX: panel.frame.minX)
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
            let screen = (NSScreen.main ?? NSScreen.screens[0]).frame
            var origin = CGPoint(x: m.x - d.grabOffset.x, y: m.y - d.grabOffset.y)
            origin.x = min(max(origin.x, screen.minX - metrics.sceneSize.width / 2), screen.maxX - metrics.sceneSize.width / 2)
            origin.y = min(max(origin.y, screen.minY), screen.maxY - metrics.sceneSize.height)
            carryVelocity = Double(origin.x - d.lastX) * 60
            d.lastX = origin.x
            panel.setFrameOrigin(origin)
            originX.value = origin.x; originX.velocity = 0
            originY.value = origin.y; originY.velocity = 0
        }
        drag = d
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
            placement = .dropped(panelOrigin: panel.frame.origin, panelSize: metrics.sceneSize, visibleFrame: visibleFrame)
            _ = reframe(to: metrics.dockX, mirrored: placement.edge == .left)
            originX.velocity = carryVelocity * 0.5   // a little fling towards the edge
        } else {
            sim.poke()
            onPoke?()
        }
    }

    // MARK: Eye gymnastics flight

    /// A figure-eight over the screen, then back to exactly where he was.
    func fly(duration: Double, completion: @escaping () -> Void) {
        guard drag == nil, flight == nil else { return completion() }
        let mirrored = isMirrored
        _ = reframe(to: metrics.carryX, mirrored: mirrored)        // centred: the panel edges never cut him
        flight = Flight(start: CACurrentMediaTime(), duration: duration, from: panel.frame.origin, mirrored: mirrored, completion: completion)
    }

    private func flyStep(_ f: Flight, now: CFTimeInterval) {
        let k = (now - f.start) / f.duration
        guard k < 1 else {
            flight = nil
            panel.setFrameOrigin(f.from)
            _ = reframe(to: metrics.dockX, mirrored: f.mirrored)
            originX.velocity = 0
            originY.value = panel.frame.origin.y
            originY.velocity = 0
            carryVelocity = 0
            f.completion()
            return
        }
        let vf = visibleFrame
        let a = k * 4 * .pi                                        // two loops
        let eight = CGPoint(x: vf.midX - metrics.width / 2 + vf.width * 0.3 * sin(a),
                            y: vf.midY - metrics.height / 2 + vf.height * 0.22 * sin(2 * a) / 2)
        func smooth(_ x: Double) -> Double { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }
        let w = min(smooth(k / 0.15), smooth((1 - k) / 0.15))      // ease out of the edge and back into it
        let origin = CGPoint(x: (f.from.x + (eight.x - f.from.x) * w).rounded(), y: (f.from.y + (eight.y - f.from.y) * w).rounded())
        carryVelocity = Double(origin.x - panel.frame.origin.x) * 60
        panel.setFrameOrigin(origin)
        originX.value = origin.x
        originY.value = origin.y
    }

    /// Moves him inside the panel and the panel the opposite way; returns the panel shift.
    /// The new pose is pushed right away so the panel move and the figure move land in the same frame.
    private func reframe(to x: Double, mirrored: Bool) -> Double {
        let shift = metrics.panelShiftKeepingPlace(fromX: sim.positionX, toX: x, mirrored: mirrored)
        sim.reframe(x: x)
        var origin = panel.frame.origin
        origin.x += shift
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrameOrigin(origin)
        view.show(pose: sim.pose, mirrored: mirrored)
        CATransaction.commit()
        originX.value = origin.x
        return shift
    }

    // MARK: Geometry

    private var visibleFrame: CGRect { (NSScreen.main ?? NSScreen.screens[0]).visibleFrame }

    private func targetOrigin() -> CGPoint {
        placement.panelOrigin(panelSize: metrics.sceneSize, visibleFrame: visibleFrame)
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
