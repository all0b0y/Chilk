import AppKit
import ChilkCore
import ChilkRender
import QuartzCore
import SwiftUI

/// Chilk on the hero card (slice 5a, decision 7): his own simulation and layer rig, drawn only while the popover is
/// open. The card's right edge plays the screen edge: he comes out from behind it, the way he left the real one.
/// Only a window onto the scene is shown (where he stands at `.out`), scaled down.
@MainActor
final class HeroView: NSView {
    let sim: CharacterSim
    private let metrics = Metrics.standard
    private let rig: LayerRig
    private let scene = CALayer()
    /// The part of the scene the card shows (canonical y-down scene coordinates).
    static let window = CGRect(x: 78, y: 58, width: 222, height: 228)
    /// The hero card's scale; the notebook (slice 7a) shows him bigger.
    static let cardScale: CGFloat = 0.6
    static var cardSize: CGSize { CGSize(width: window.width * cardScale, height: window.height * cardScale) }
    let scale: CGFloat
    var size: CGSize { CGSize(width: Self.window.width * scale, height: Self.window.height * scale) }

    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var comeOut: Timer?
    /// Read every frame: the sprout mirrors the user like the one at the edge.
    var fatigue: () -> Double = { 0 }
    /// The eyes mirror (slice 6a), shown at once when the popover opens.
    var eyeStrain: () -> Double = { 0 }

    init(scale: CGFloat = HeroView.cardScale) {
        self.scale = scale
        sim = CharacterSim(metrics: metrics)
        rig = LayerRig(metrics: metrics, palette: .peach, rasterScale: 2)
        super.init(frame: .zero)
        setFrameSize(size)
        let host = CALayer()
        host.masksToBounds = true                        // the card edge hides him, like the screen edge
        layer = host
        wantsLayer = true
        scene.anchorPoint = .zero
        scene.bounds = CGRect(origin: .zero, size: metrics.sceneSize)
        // Scene y-up: the window's bottom is at scene height − maxY.
        scene.position = CGPoint(x: -Self.window.minX * scale,
                                 y: -(metrics.height - Self.window.maxY) * scale)
        scene.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        scene.actions = ["position": NSNull(), "transform": NSNull()]
        rig.root.frame = CGRect(origin: .zero, size: metrics.sceneSize)
        scene.addSublayer(rig.root)
        host.addSublayer(scene)
        sim.reframe(x: metrics.awayX)
        sim.standOut = .away
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { size }

    /// The popover opened with him free: he waits behind the card edge while the edge Chilk ducks out of sight,
    /// then comes out. `present: false` (he is busy at the edge) keeps the card's sign instead.
    func start(enterAfter delay: TimeInterval) {
        sim.reframe(x: metrics.awayX)
        sim.standOut = .away
        sim.fatigue = fatigue()
        sim.eyeStrain = eyeStrain()
        sim.snapEyeStrain()
        sim.hourOfDay = Calendar.current.component(.hour, from: Date())
        comeOut?.invalidate()
        comeOut = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sim.standOut = .out }
        }
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = Self.moving
        link.add(to: .main, forMode: .common)
        self.link = link
        last = nil
        // SPEC «60 fps (30 fps в покое)»: 60 only while he comes out of the card's edge, then he just breathes.
        calm?.invalidate()
        calm = Timer.scheduledTimer(withTimeInterval: delay + 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.link?.preferredFrameRateRange = Self.resting }
        }
    }

    private static let moving = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    private static let resting = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
    private var calm: Timer?

    /// The popover closed: no frames, no CPU.
    func stop() {
        comeOut?.invalidate()
        calm?.invalidate()
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = min(1.0 / 30, max(0, now - (last ?? now)))
        last = now
        sim.fatigue = fatigue()
        sim.eyeStrain = eyeStrain()
        sim.step(dt: dt, pointer: pointer())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rig.apply(ChilkRenderer.placements(pose: sim.pose, metrics: metrics, mirrored: false))
        CATransaction.commit()
    }

    /// The mouse in scene coordinates, so his eyes follow it inside the popover too.
    private func pointer() -> CGPoint? {
        guard let window else { return nil }
        let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return CGPoint(x: Self.window.minX + local.x / scale,
                       y: Self.window.maxY - local.y / scale)
    }

    override func mouseDown(with event: NSEvent) { sim.poke() }
}

/// SwiftUI wrapper: the popover owns one `HeroView` for its lifetime and starts/stops it.
struct HeroPortrait: NSViewRepresentable {
    let view: HeroView
    func makeNSView(context: Context) -> HeroView { view }
    func updateNSView(_ nsView: HeroView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HeroView, context: Context) -> CGSize? { nsView.size }
}
