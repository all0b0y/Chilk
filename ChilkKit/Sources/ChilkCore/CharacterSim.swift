import CoreGraphics

/// Which transient moods are active. Drives faces in the renderer.
public struct Mood: Sendable, Equatable {
    public var called = false
    public var dizzy = false
    public var annoyed = false
    public var yawning = false
    public var sleeping = false
    public var carried = false
    /// The emergency exit with no exits left: half-closed eyes, a frown, the sprout droops.
    public var sad = false
    /// «Ликует» (slice 6a): ^ ^ eyes and a wide-open mouth while he jumps with his hands up.
    public var cheering = false
    /// The stretch hint's hops: a straight, busy face — no smile, so it never reads as joy.
    public var focused = false
    /// «Хап!» — the speck is caught; then chewing.
    public var chomping = false
    public var chewing = false
    /// «Лежит» (slice 6b): on his side, half-closed eyes, a frown.
    public var slumped = false
    public init() {}
}

/// «Лежит» (slice 6b): he turns onto his side about his feet, head away from the screen edge, and is lifted so the
/// turned body still rests on the floor. Shared by the simulation (hit tests) and the renderer (the frame plan).
public enum Lying {
    /// Extra rotation when fully lying (y-down: negative = the head goes left, into the screen).
    public static let turn = -Double.pi / 2

    public static func eased(_ level: Double) -> Double {
        let c = min(1, max(0, level))
        return c * c * (3 - 2 * c)
    }

    /// `angle`: total rotation about the feet; `lift`: up (negative) so the body touches the floor; `dx`, `dy`: body
    /// centre from the feet; `halfHeight`: half the turned body's height. `rx`, `ry`: body radii with the scale.
    public static func frame(lying: Double, tilt: Double, rx: Double, ry: Double)
        -> (angle: Double, lift: Double, dx: Double, dy: Double, halfHeight: Double) {
        guard lying > 0.001 else { return (tilt, 0, 0, -ry, ry) }
        let a = tilt + turn * lying
        let h = ((rx * sin(a)) * (rx * sin(a)) + (ry * cos(a)) * (ry * cos(a))).squareRoot()
        let lift = -(h - ry * cos(a))
        return (a, lift, ry * sin(a), lift - ry * cos(a), h)
    }
}

/// Little things Чилк does on his own, "по настроению", not on a timer the user can predict.
/// Slice 6a (decision 1): none of them may look like a need's hint — «потягивание» (= «размяться») and «взгляд в
/// сторону» (= «глаза») are gone, «чешет листик» and «ловит пылинку» took their place.
public enum Antic: CaseIterable, Sendable {
    case hop, leafFlick, yawn, wiggle, scratchLeaf, catchSpeck

    public var duration: Double {
        switch self {
        case .hop: 0.6
        case .leafFlick: 0.8
        case .yawn: 1.6
        case .wiggle: 1.0
        case .scratchLeaf: 1.8
        case .catchSpeck: 2.8
        }
    }
}

/// How far out from behind the screen edge he stands (ladder stages, activities). `center`: stage 3–4, he has
/// left the edge and stands in the middle of the screen (the app moves the window; he is centred in it).
/// `away`: entirely behind the edge — he went into the tray popover (slice 5a).
public enum StandOut: Sendable, Equatable {
    case docked, peek, out, center, away
}

/// Things he can hold or wear. Order = drawing order (behind → front).
public enum Prop: String, CaseIterable, Sendable, Hashable {
    case backpack, hat, mug
}

/// Directed performances for the balance ladder and the breaks (В18). Unlike antics they are asked for.
public enum Act: Sendable, Equatable {
    /// Sips from a mug (water hint / celebration).
    case drink
    /// Three big stretches (stretch hint).
    case stretches
    /// Gazes into the distance and blinks slowly (eyes hint).
    case lookAway
    /// Waves and hops (going for a walk).
    case wave
    /// Puts the backpack on (end of day).
    case pack
    /// Breathes with the user: 4 s in, 6 s out.
    case breathe(seconds: Double)
    /// Waits for Codex: looks up, the sprout twirls, a little «хм» bob.
    case think(seconds: Double)
    /// The stretch hint (slice 6a, decision 5): 5–6 chaotic hops near the edge with a straight face, then back.
    case hops
    /// «Ликует» (decision 6): vertical jumps on the spot, hands up, ^ ^, the leaves spin, confetti on the last jump.
    case cheer

    public var duration: Double {
        switch self {
        case .drink: 3.0
        case .stretches: 3.3
        case .lookAway: 4.0
        case .wave: 1.6
        case .pack: 2.4
        case .breathe(let s): s
        case .think(let s): s
        case .hops: 4.2
        case .cheer: 2.2
        }
    }
}

/// A little hand, only when he needs one. Figure space: `x` in body half-widths (+ = towards the screen edge),
/// `y` in body half-heights from the body centre (− = up), `angle` in radians.
public struct Hand: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var angle: Double
    /// `true`: a short arm growing out from behind the body (its base at x, y; `angle` 0 = straight up), not a
    /// floating mitten — raised arms must read as arms, not as ears or balls.
    public var arm: Bool
    public init(x: Double, y: Double, angle: Double, arm: Bool = false) {
        self.x = x; self.y = y; self.angle = angle; self.arm = arm
    }
}

/// Everything the renderer needs for one frame. Scene coordinates, y-down, docked to the right.
public struct CharacterPose: Sendable, Equatable {
    public var time: Double = 0
    public var phase: Double = 0
    /// Horizontal centre of the body and hop height (negative = up).
    public var x: Double = 0
    public var hop: Double = 0
    /// Breathing + squash & stretch, applied around the feet.
    public var scaleX: Double = 1
    public var scaleY: Double = 1
    public var tilt: Double = 0
    /// Gaze in [-1, 1].
    public var lookX: Double = 0
    public var lookY: Double = 0
    public var eyeScale: Double = 1
    /// 1 = open, 0 = closed (blink, tiredness, yawning, sleep).
    public var eyeOpen: Double = 1
    public var leafAngle: Double = 0
    public var fatigue: Double = 0
    /// 0 = awake, 1 = fast asleep (drives "z z z").
    public var sleep: Double = 0
    /// Tiredness shown by posture (slice 6a, decision 3): 0 = upright, 1 = sagging. Never by the eyes.
    public var sag: Double = 0
    /// The eyes mirror (decision 4): 0 = fine, 1 = eyes at ¾ with clear lavender bags under them.
    public var eyeStrain: Double = 0
    public var hands: [Hand] = []
    /// The speck he is about to catch (scene coordinates).
    public var speck: CGPoint?
    /// Extra spin of the two leaves around the stem tip (propeller while cheering).
    public var leafSpin: Double = 0
    /// Seconds since the confetti burst, while it is still in the air; `confettiOrigin` in scene coordinates.
    public var confettiAge: Double?
    public var confettiOrigin: CGPoint = .zero
    /// Clicks go through him (the hops hint must never catch a click meant for the window under him).
    public var passThrough = false
    /// «Лежит» (slice 6b): 0 = standing, 1 = on his side (eased).
    public var lying: Double = 0
    public var mood = Mood()
    /// Seconds since he was called (happy ^ ^ eyes right after).
    public var calledAge: Double = 99
    /// Speech bubble: text, seconds since it appeared and until it goes.
    public var bubble: String?
    public var bubbleAge: Double = 0
    public var bubbleRemaining: Double = 0
    /// Buttons under the bubble text and the one under the cursor.
    public var buttons: [String] = []
    public var hoveredButton: Int?
    public var props: Set<Prop> = []
    /// 0 = mug held at his side, 1 = at his mouth.
    public var mugLift: Double = 0
    /// Listening: ears popped up (0…1, springy) and twitching with the voice.
    public var earsUp: Double = 0
    public var earWiggle: Double = 0
    /// Waiting for a follow-up: the ears slowly droop as the window closes (0 → 1).
    public var earsDroop: Double = 0
    public init() {}
}

/// The living character, frame by frame. Deterministic given `rng` and the inputs,
/// so every behaviour from the motion prototype is unit-tested here and only drawn by the app.
@MainActor
public final class CharacterSim {
    public let metrics: Metrics
    public private(set) var time: Double = 0
    /// 0 = fresh, 1 = sat way too long. Driven by `BalanceEngine.leafFatigue`.
    public var fatigue: Double = 0 { didSet { fatigue = min(1, max(0, fatigue)) } }
    /// 0…1, driven by `BalanceEngine.eyeStrain` (slice 6a). Shown gradually; a big drop (rested eyes) blinks twice.
    public var eyeStrain: Double = 0 { didSet { eyeStrain = min(1, max(0, eyeStrain)) } }
    /// Local hour (0–23). At night he yawns a lot more.
    public var hourOfDay = 12
    /// The user is holding him (dragging the panel).
    public var isCarried = false {
        didSet {
            guard oldValue != isCarried else { return }
            if isCarried { eyeScale.impulse(3) } else { squash.impulse(6); leaf.impulse(4) }   // landing
        }
    }
    /// Ladder stages and activities bring him out from behind the edge.
    public var standOut: StandOut = .docked
    /// Eye gymnastics: «следи за мной».
    public var eyesWide = false
    /// Emergency exit with none left: he is sad while the button is held.
    public var isSad = false
    /// «Лежит» (slice 6b): every need of the user is empty — he lies on his side at the edge until a rest.
    public var slumped = false
    public var hoveredButton: Int?
    /// Listening to the user: little ears pop up; `hearing` (0…1, voice level) makes them twitch.
    public var listening = false
    public var hearing: Double = 0
    public var earsDroop: Double = 0 { didSet { earsDroop = min(1, max(0, earsDroop)) } }
    public private(set) var isHovering = false
    public private(set) var currentAntic: Antic?
    public private(set) var isAsleep = false
    public private(set) var act: Act?
    public private(set) var props: Set<Prop> = []

    // Motion springs (stiffness/damping copied from the approved prototype).
    private var x: Spring
    private var hop = Spring(0, stiffness: 160, damping: 11)
    private var squash = Spring(0, stiffness: 330, damping: 10)
    private var tilt = Spring(-0.1, stiffness: 120, damping: 12)
    private var lookX = Spring(0, stiffness: 230, damping: 22)
    private var lookY = Spring(0, stiffness: 230, damping: 22)
    private var eyeScale = Spring(1, stiffness: 260, damping: 16)
    private var leaf = Spring(0, stiffness: 55, damping: 4.2)
    private var mug = Spring(0, stiffness: 90, damping: 14)
    private var ears = Spring(0, stiffness: 240, damping: 11)
    private var sleepLevel = 0.0

    private var rng: any RandomSource
    private let phase: Double
    private var blinkAt: Double
    private var blinkStart: Double?
    private var doubleBlink = false
    private var nextSaccade = 0.0
    private var idleLook = (x: 0.0, y: 0.0)
    private var nextAntic: Double
    private var anticStart = 0.0
    private var anticUntil = 0.0
    private var calledAt = -99.0
    private var calledUntil = -99.0
    private var annoyedUntil = -99.0
    private var dizzyUntil = -99.0
    private var pokes: [Double] = []
    private var hoverLostAt: Double?
    private var bubbleText: String?
    private var bubbleButtons: [String] = []
    private var bubbleAt = -99.0
    private var bubbleUntil = -99.0
    private var actStart = 0.0
    private var actBeats = 0
    private var actProps: Set<Prop> = []
    private var anticBeats = 0
    // Slice 6a: a real jump is a ballistic arc (a spring impulse only bobs ~10 pt), optionally from x to x.
    private var jump: (start: Double, duration: Double, height: Double, fromX: Double, toX: Double?)?
    private var jumpY = 0.0
    private var jumpVelocity = 0.0
    private var hopTilt = 0.0
    /// Where the hops hint keeps him after the last landing (nil = his usual place).
    private var hopX: Double?
    private var confettiAt: Double?
    private var confettiOrigin = CGPoint.zero
    private var strainShown = 0.0
    private var strainBlinked = false
    private var lieLevel = 0.0
    private var nextSigh = 0.0

    public static let calledDuration = 4.4
    public static let dizzyDuration = 2.6
    public static let annoyedDuration = 0.9
    public static let tripleClickWindow = 1.3
    /// Seconds to doze off / to wake up.
    public static let fallAsleepDuration = 2.5
    public static let wakeUpDuration = 0.3
    /// Pointer farther than this (points) → he stops tracking it and looks around himself.
    public static let gazeRange = 520.0
    /// Hover ends this long after the cursor really left.
    public static let hoverGrace = 0.3
    /// Carry speed (points/s) beyond which dragging faster changes nothing; max body tilt (radians).
    public static let maxCarrySpeed = 700.0
    public static let maxTilt = 0.55
    /// One breath: in for 4 s, out for 6 s.
    public static let inhale = 4.0, exhale = 6.0
    /// The hops hint stays within this distance of the screen edge (body centre; ~300 pt with the body).
    public static let hopsZone = 230.0
    /// The eyes mirror: slow to show (minutes of strain), quick to clear (~1 s after a rest).
    public static let strainRise = 0.25, strainFall = 1.2
    /// «Лежит»: down in ~0.8 s, up slowly in ~1.5 s («медленно встаёт»).
    public static let lieDown = 0.8, getUp = 1.5
    nonisolated public static let confettiLife = 1.4

    public init(metrics: Metrics = .standard, rng: any RandomSource = SystemRandom()) {
        self.metrics = metrics
        var r = rng
        self.phase = r.uniform(0, 6)
        self.blinkAt = r.uniform(1, 4)
        self.nextAntic = r.uniform(6, 11)
        self.rng = r
        self.x = Spring(metrics.dockX, stiffness: 90, damping: 13)
    }

    // MARK: Queries

    public var bodyCenter: CGPoint {
        let ry = metrics.radiusY * (1 - squash.value * 0.22)
        let lie = Lying.frame(lying: Lying.eased(lieLevel), tilt: tilt.value, rx: metrics.radiusX, ry: ry)
        guard lieLevel > 0.001 else { return CGPoint(x: x.value, y: metrics.ground + hop.value + jumpY - ry) }
        return CGPoint(x: x.value + lie.dx, y: metrics.ground + hop.value + jumpY + lie.dy)
    }

    /// Horizontal position inside the panel (scene points, docked-right orientation).
    public var positionX: Double { x.value }

    /// Re-anchors him inside the panel instantly (no motion, no velocity). The caller moves the panel by
    /// `Metrics.panelShiftKeepingPlace` in the same frame, so on screen nothing changes.
    public func reframe(x newX: Double) {
        x.value = newX
        x.target = newX
        x.velocity = 0
    }

    /// Hit test against the body ellipse (scene coordinates).
    public func contains(_ p: CGPoint) -> Bool {
        let c = bodyCenter
        var px = Double(p.x) - Double(c.x), py = Double(p.y) - Double(c.y)
        if lieLevel > 0.001 {                                   // into the turned body's own axes
            let a = Lying.frame(lying: Lying.eased(lieLevel), tilt: tilt.value, rx: metrics.radiusX, ry: metrics.radiusY).angle
            (px, py) = (px * cos(a) + py * sin(a), -px * sin(a) + py * cos(a))
        }
        let dx = px / metrics.radiusX
        let dy = py / metrics.radiusY
        return dx * dx + dy * dy < 1.05 * 1.05
    }

    public var mood: Mood {
        var m = Mood()
        m.called = time < calledUntil
        m.dizzy = time < dizzyUntil
        m.annoyed = time < annoyedUntil
        m.yawning = currentAntic == .yawn && time < anticUntil
        m.sleeping = sleepLevel > 0.6
        m.carried = isCarried
        m.sad = isSad
        m.slumped = lieLevel > 0.4
        if let a = act {
            let k = time - actStart
            m.cheering = a == .cheer && k < 1.7
            m.focused = a == .hops
        }
        if currentAntic == .catchSpeck, time < anticUntil {
            let k = time - anticStart
            m.chomping = k >= 1.45 && k < 1.62
            m.chewing = k >= 1.62 && k < 2.6
        }
        return m
    }

    public var isNight: Bool { hourOfDay >= 23 || hourOfDay < 6 }

    /// Breathing exercise: which half of the breath and how far into it (0…1).
    public var breath: (inhaling: Bool, progress: Double, count: Int)? {
        guard case .breathe = act else { return nil }
        let k = time - actStart
        let cycle = Self.inhale + Self.exhale
        let inCycle = k.truncatingRemainder(dividingBy: cycle)
        let count = Int(k / cycle)
        return inCycle < Self.inhale
            ? (true, inCycle / Self.inhale, count)
            : (false, (inCycle - Self.inhale) / Self.exhale, count)
    }

    /// `true` while something moves fast enough to need 60 fps; otherwise ~30 fps is indistinguishable
    /// (breathing, slow leaf sway) and halves the drawing cost.
    public var isBusy: Bool { busyReason != nil }

    /// Why he needs 60 fps right now (`nil` = 30 fps is enough). Exposed for the debug overlay/log.
    public var busyReason: String? {
        let m = mood
        if m.called { return "called" }
        if m.dizzy { return "dizzy" }
        if m.annoyed { return "annoyed" }
        if m.carried { return "carried" }
        if isHovering { return "hover" }
        if let a = act, a != .breathe(seconds: a.duration) { return "act" }
        if let a = currentAntic { return "antic \(a)" }
        if jump != nil { return "jump" }
        if let c = confettiAt, time - c < Self.confettiLife { return "confetti" }
        if blinkStart != nil { return "blink" }
        // A bubble needs 60 fps while it pops in (words arrive one by one) or out — not while it just stays.
        if time < bubbleUntil && (time - bubbleAt < 2 || bubbleUntil - time < 0.4) { return "bubble" }
        if isAsleep ? sleepLevel < 1 : sleepLevel > 0 { return "sleep transition" }
        if abs(x.velocity) > 4 { return "x moving" }
        if abs(hop.velocity) > 4 { return "hop" }
        if abs(squash.velocity) > 0.05 { return "squash" }
        if abs(mug.velocity) > 0.05 { return "mug" }
        if abs(ears.velocity) > 0.05 || (listening && hearing > 0.05) { return "ears" }
        if abs(lookX.velocity) + abs(lookY.velocity) > 0.25 { return "eyes moving" }
        if abs(leaf.velocity) > 0.35 { return "leaf swinging" }
        if abs(lookX.value - lookX.target) + abs(lookY.value - lookY.target) > 0.05 { return "eyes settling" }
        return nil
    }

    // MARK: Inputs

    /// "Чилк!" — hop out, happy face, speech bubble.
    public func call(line: String) {
        if isAsleep { wakeUp() }
        calledAt = time
        calledUntil = time + Self.calledDuration
        currentAntic = nil
        hop.impulse(-300)
        leaf.impulse(5)
        say(line, duration: Self.calledDuration)
    }

    /// Show a speech bubble where he stands. Words arrive one by one.
    /// With buttons the bubble stays until `clearBubble()` unless a duration is given.
    public func say(_ text: String, duration: Double? = nil, buttons: [String] = []) {
        bubbleText = text
        bubbleButtons = buttons
        bubbleAt = time
        bubbleUntil = time + (duration ?? (buttons.isEmpty ? 3.5 : .infinity))
        hoveredButton = nil
    }

    /// Replace the words in place (countdowns, «вдох / выдох») without popping the bubble again.
    public func updateBubble(_ text: String) {
        guard time < bubbleUntil else { return say(text, duration: .infinity) }
        bubbleText = text
    }

    /// Buttons under the bubble that is already showing (a long answer gets «Подробнее»), without popping it again.
    public func setBubbleButtons(_ buttons: [String]) {
        guard time < bubbleUntil else { return }
        bubbleButtons = buttons
        hoveredButton = nil
    }

    public var isTalking: Bool { time < bubbleUntil }

    /// Clicks go through him while the stretch hint hops around (a click there is meant for the window under him).
    public var passesClicks: Bool { act == .hops }

    /// Shows the eyes mirror at once (the popover hero is a fresh Чилк every time it opens).
    public func snapEyeStrain() {
        strainShown = eyeStrain
        strainBlinked = true
    }

    /// The bubble shrinks away.
    public func clearBubble() {
        guard time < bubbleUntil else { return }
        bubbleUntil = min(bubbleUntil, time + 0.3)
        bubbleButtons = []
        hoveredButton = nil
    }

    /// A click on the body: jelly squash + "><". Three quick ones → dizzy.
    public func poke() {
        if isAsleep { wakeUp() }
        squash.impulse(7.5)
        leaf.impulse(6)
        annoyedUntil = time + Self.annoyedDuration
        pokes = pokes.filter { time - $0 < Self.tripleClickWindow } + [time]
        if pokes.count >= 3 {
            dizzyUntil = time + Self.dizzyDuration
            annoyedUntil = -99
            pokes.removeAll()
        }
    }

    /// The user went away: he slowly dozes off ("z z z").
    public func fallAsleep() {
        guard !isAsleep else { return }
        isAsleep = true
        currentAntic = nil
    }

    /// The user is back: eyes pop open, a little hop.
    public func wakeUp() {
        guard isAsleep else { return }
        isAsleep = false
        hop.impulse(-190)
        leaf.impulse(7)
        eyeScale.impulse(2.5)
    }

    public func perform(_ a: Act) {
        if isAsleep { wakeUp() }
        stopAct()
        act = a
        actStart = time
        actBeats = 0
        currentAntic = nil
    }

    public func stopAct() {
        props.subtract(actProps)
        actProps = []
        act = nil
        mug.target = 0
        hopX = nil
        hopTilt = 0
        if jump?.toX != nil { jump = nil; jumpY = 0 }          // a hop across lands where it is, not mid-air later
    }

    /// Starts an antic now (the tray's «Проверка ▸ Выходка», tests). Not while asleep, carried or in an act.
    public func startAntic(_ a: Antic) {
        guard !isAsleep, !isCarried, act == nil else { return }
        beginAntic(a, at: time)
        nextAntic = max(nextAntic, time + a.duration + 6)
    }

    public func wear(_ p: Prop) {
        guard !props.contains(p) else { return }
        props.insert(p)
        hop.impulse(-120)
        squash.impulse(3)
    }

    public func takeOff(_ p: Prop) {
        props.remove(p)
        actProps.remove(p)
    }

    /// - Parameters:
    ///   - pointer: mouse position in scene coordinates, `nil` when unknown.
    ///   - carryVelocity: horizontal velocity (points/s) when the user drags the whole panel; tilts him into the motion.
    public func step(dt: Double, pointer: CGPoint?, carryVelocity: Double = 0) {
        time += dt
        let t = time
        let m = mood
        let center = bodyCenter

        sleepLevel += isAsleep ? dt / Self.fallAsleepDuration : -dt / Self.wakeUpDuration
        sleepLevel = min(1, max(0, sleepLevel))
        let drowsy = sleepLevel > 0.05
        lieLevel = min(1, max(0, lieLevel + (slumped ? dt / Self.lieDown : -dt / Self.getUp)))
        let lying = Lying.eased(lieLevel)
        if slumped { currentAntic = nil }

        updateHover(pointer: pointer, center: center)

        // Dragging speed is clamped: a fast flick must tilt him, not spin him (and keep him inside his paint bounds).
        let carry = min(Self.maxCarrySpeed, max(-Self.maxCarrySpeed, carryVelocity))
        let stand: Double = switch standOut {
        case .docked: metrics.dockX
        case .peek: metrics.peekX
        case .out: metrics.outX
        case .center: metrics.carryX
        case .away: metrics.awayX
        }
        // A call brings him out even from behind the edge (the tray then takes him back from the popover).
        x.target = m.carried || standOut == .center ? metrics.carryX
            : (m.called ? metrics.outX
               : (standOut == .away ? stand : (isHovering ? min(metrics.peekX, stand) : stand)))
        if let h = hopX, !m.carried { x.target = h }              // between the hops he stays where he landed
        let sag = sagLevel
        tilt.target = (m.called ? 0 : -0.1) - x.velocity * 0.0011 - carry * 0.0006
            + (m.dizzy ? sin(t * 9) * 0.12 : 0) + sleepLevel * 0.08 - sag * 0.07
        eyeScale.target = m.carried ? 1.28 : (eyesWide ? 1.25 : (isHovering ? 1.18 : (m.called || listening ? 1.1 : 1)))
        ears.target = listening ? 1 : 0

        // Gaze: follow the pointer when it is around, otherwise little idle saccades. Asleep: head down.
        var tracking = false
        if let p = pointer, !drowsy, !eyesWide {
            let dx = Double(p.x) - Double(center.x)
            let dy = Double(p.y) - (Double(center.y) - 6)
            let dist = (dx * dx + dy * dy).squareRoot()
            if dist < Self.gazeRange {
                tracking = true
                let f = min(1, dist / 140)
                lookX.target = dist > 0 ? dx / dist * f : 0
                lookY.target = dist > 0 ? dy / dist * f * 0.8 : 0
            }
        }
        if drowsy {
            lookX.target = -0.1
            lookY.target = 0.35
        } else if eyesWide {
            lookX.target = -0.2
            lookY.target = -0.1
        } else if !tracking {
            if t > nextSaccade {
                idleLook = (rng.uniform(-0.7, 0.4), rng.uniform(-0.3, 0.3))
                nextSaccade = t + rng.uniform(1.4, 3.8)
            }
            lookX.target = idleLook.x
            lookY.target = idleLook.y + sag * 0.3                       // tired: the gaze drops a little (6a)
            if m.called || listening { lookX.target = -0.2; lookY.target = 0.05 }
        }
        if lying > 0 { lookY.target += lying * 0.25 }

        stepAct(t: t)

        // Antics "по настроению". At night (and when tired) yawns win far more often. Not during acts; fewer when tired.
        if t >= anticUntil { currentAntic = nil }
        if !m.called && !m.dizzy && !m.carried && !drowsy && act == nil && lieLevel == 0 && t > nextAntic {
            beginAntic(pickAntic(), at: t)
            nextAntic = t + rng.uniform(8, 15) * (1 + sag * 0.8)
        }
        // Lying: a heavy sigh now and then (6b).
        if lieLevel >= 1, t > nextSigh {
            if nextSigh > 0 { squash.impulse(-3.2); leaf.impulse(-2) }
            nextSigh = t + rng.uniform(5, 8)
        }
        if currentAntic == .wiggle {
            let k = t - anticStart
            tilt.target += sin(k * 14) * 0.13 * max(0, 1 - k / Antic.wiggle.duration)
        }
        stepAntic(t: t)
        tilt.target = min(Self.maxTilt, max(-Self.maxTilt, tilt.target))

        // Leaf: droops with fatigue and sleep, sways in a breeze, lags behind body motion (follow-through).
        leaf.target = -0.06 + fatigue * 0.35 + sleepLevel * 0.22 + (isSad ? 0.3 : 0) + lying * 0.5
            + sin(t * 0.9 + phase) * 0.07 * (1 - sleepLevel * 0.6) + sin(t * 2.3) * 0.025
        if case .think = act { leaf.target += sin((t - actStart) * 2.4) * 0.3 }
        leaf.velocity += -x.velocity * 0.0022 - (hop.velocity + jumpVelocity) * 0.0009 - carry * 0.0012

        // Blink: random 2.2–5.8 s, 20 % double. Not while dozing.
        if blinkStart == nil && t > blinkAt && !drowsy {
            blinkStart = t
            doubleBlink = rng.next() < 0.2
        }
        if let start = blinkStart, t - start > 0.25 {
            if doubleBlink { doubleBlink = false; blinkStart = t } else { blinkStart = nil; blinkAt = t + rng.uniform(2.2, 5.8) }
        }

        let half = dt / 2
        for _ in 0..<2 {
            x.step(half); hop.step(half); squash.step(half); tilt.step(half)
            lookX.step(half); lookY.step(half); eyeScale.step(half); leaf.step(half); mug.step(half); ears.step(half)
        }
        stepJump(t: t)
        stepStrain(dt: dt, t: t)
    }

    /// Choreography of the directed acts: beats at fixed times inside the act.
    private func stepAct(t: Double) {
        guard let a = act else { return }
        let k = t - actStart
        if k >= a.duration { return stopAct() }
        func beat(_ at: Double, _ body: () -> Void) {
            if k >= at && actBeats == beatIndex { body(); actBeats += 1 }
            beatIndex += 1
        }
        beatIndex = 0
        switch a {
        case .drink:
            beat(0) { props.insert(.mug); if !props.contains(.mug) { return }; actProps.insert(.mug) }
            beat(0.35) { mug.target = 1 }                       // up to the mouth
            beat(2.1) { mug.target = 0; squash.impulse(2.5) }   // "ах!"
            if mug.value > 0.6 { tilt.target -= 0.08 * mug.value; lookY.target = -0.25 }
        case .stretches:
            beat(0) { squash.impulse(-6.5); leaf.impulse(5) }
            beat(1.1) { squash.impulse(-6.5); leaf.impulse(5) }
            beat(2.2) { squash.impulse(-7.5); leaf.impulse(6) }
        case .lookAway:
            lookX.target = -0.95
            lookY.target = -0.4
            beat(1.8) { blinkStart = t; doubleBlink = false }
            beat(3.0) { blinkStart = t; doubleBlink = true }
        case .wave:
            beat(0) { hop.impulse(-200); leaf.impulse(6) }
            tilt.target += sin(k * 12) * 0.16 * max(0, 1 - k / a.duration)
        case .pack:
            beat(0.5) { if !props.contains(.backpack) { wear(.backpack) } }
            beat(1.4) { squash.impulse(4) }
        case .breathe:
            lookY.target = 0.15
        case .think:
            lookX.target = 0.55
            lookY.target = -0.65
            if k >= Double(actBeats) * 1.6 { hop.impulse(-45); actBeats += 1 }   // «хм…»
        case .hops:
            // 5 chaotic hops near the edge, the 6th back home; a straight face, eyes where he is going.
            for (i, at) in [0.0, 0.65, 1.3, 1.95, 2.6].enumerated() {
                beat(at) {
                    let lo = metrics.width - Self.hopsZone, hi = metrics.peekX
                    var to = rng.uniform(lo, hi)
                    for _ in 0..<6 where abs(to - x.value) < 45 { to = rng.uniform(lo, hi) }
                    startJump(height: rng.uniform(30, 58), duration: rng.uniform(0.44, 0.54), to: to)
                    hopTilt = rng.uniform(-0.3, 0.3) * (i % 2 == 0 ? 1 : -1)
                    leaf.impulse(rng.uniform(-10, 10))
                }
            }
            beat(3.25) { startJump(height: 34, duration: 0.5, to: standX); hopTilt = 0 }
            beat(3.8) { hopX = nil }
            if let to = jump?.toX { lookX.target = to < x.value ? -0.7 : 0.5; lookY.target = 0.1 }
            tilt.target += hopTilt * (jump == nil ? 0.3 : 1)
        case .cheer:
            // Vertical jumps on the spot (never sideways: that is the stretch hint), confetti at the top of the last.
            beat(0) { startJump(height: 44, duration: 0.46); squash.impulse(4) }
            beat(0.55) { startJump(height: 48, duration: 0.46) }
            beat(1.1) { startJump(height: 54, duration: 0.48) }
            beat(1.34) {
                confettiAt = t
                let c = bodyCenter
                confettiOrigin = CGPoint(x: Double(c.x), y: Double(c.y) - metrics.radiusY * 1.05)
            }
            lookX.target = -0.15
            lookY.target = -0.2
        }
    }

    private var beatIndex = 0

    /// His usual place for the current `standOut` (where the hops end).
    private var standX: Double {
        switch standOut {
        case .docked: metrics.dockX
        case .peek: metrics.peekX
        case .out: metrics.outX
        case .center: metrics.carryX
        case .away: metrics.awayX
        }
    }

    /// Tiredness as posture (6a, decision 3): nothing until ~half-way, full sag when the sprout is wilted.
    private var sagLevel: Double { min(1, max(0, (fatigue - 0.45) / 0.55)) }

    private func startJump(height: Double, duration: Double, to toX: Double? = nil) {
        jump = (time, duration, height, x.value, toX)
        if let toX { hopX = toX }
    }

    /// The ballistic arc on top of the springs; a hop across also carries x (the spring alone lags behind).
    private func stepJump(t: Double) {
        guard let j = jump else { jumpY = 0; jumpVelocity = 0; return }
        let u = (t - j.start) / j.duration
        if u >= 1 {
            jump = nil
            jumpY = 0
            jumpVelocity = 0
            if let to = j.toX { x.value = to; x.velocity = 0; x.target = to }
            squash.impulse(4.5)
            leaf.impulse(4)
            return
        }
        jumpY = -4 * j.height * u * (1 - u)
        jumpVelocity = -4 * j.height * (1 - 2 * u) / j.duration
        if let to = j.toX {
            x.value = j.fromX + (to - j.fromX) * u
            x.velocity = (to - j.fromX) / j.duration
        }
    }

    private func beginAntic(_ a: Antic, at t: Double) {
        currentAntic = a
        anticStart = t
        anticUntil = t + a.duration
        anticBeats = 0
        switch a {
        case .hop: hop.impulse(-170); leaf.impulse(3)
        case .leafFlick: leaf.impulse(10)
        case .yawn, .wiggle, .scratchLeaf, .catchSpeck: break
        }
    }

    /// «Чешет листик» and «ловит пылинку» (6a, decision 2): the two neutral antics.
    private func stepAntic(t: Double) {
        guard let a = currentAntic, t < anticUntil else { return }
        let k = t - anticStart
        switch a {
        case .scratchLeaf:
            lookX.target = -0.1
            lookY.target = -0.6
            if k >= 0.35 && k < 1.45 && k >= 0.35 + Double(anticBeats) * 0.14 {    // scratch-scratch: the leaf twitches
                leaf.impulse(anticBeats % 2 == 0 ? 2.2 : -2.2)
                anticBeats += 1
            }
        case .catchSpeck:
            if let s = speckPoint(k: k) {
                let c = bodyCenter
                lookX.target = max(-1, min(1, (Double(s.x) - Double(c.x)) / 60))
                lookY.target = max(-1, min(1, (Double(s.y) - Double(c.y) + 6) / 60))
            }
            if k >= 1.45 && anticBeats == 0 { hop.impulse(-150); squash.impulse(-3); anticBeats = 1 }   // «хап!»
        default:
            break
        }
    }

    /// The speck drifts lazily from up-left towards his mouth over 1.45 s, then he has it.
    private func speckPoint(k: Double) -> CGPoint? {
        guard k < 1.45 else { return nil }
        let c = bodyCenter
        let e = 0.5 - 0.5 * cos(min(1, k / 1.45) * .pi)
        let from = (x: -84.0, y: -78.0), to = (x: -10.0, y: 12.0)
        let wobble = sin(k * 5.5) * 12 * (1 - e)
        return CGPoint(x: Double(c.x) + from.x + (to.x - from.x) * e + wobble * 0.4,
                       y: Double(c.y) + from.y + (to.y - from.y) * e + wobble)
    }

    /// Hands only when he needs them: both up while cheering, one rubbing the stem while he scratches the leaf.
    private var hands: [Hand] {
        let t = time
        if act == .cheer, t - actStart < 1.7 {
            let w = sin((t - actStart) * 16) * 0.16                    // both arms up, waving
            return [Hand(x: -0.8, y: -0.28, angle: -0.95 + w, arm: true), Hand(x: 0.8, y: -0.28, angle: 0.95 - w, arm: true)]   // ＼(^o^)／
        }
        guard currentAntic == .scratchLeaf, t < anticUntil else { return [] }
        let k = t - anticStart
        let side = Hand(x: -1.0, y: 0.3, angle: 0.2), stem = Hand(x: -0.3, y: -0.98, angle: -0.9)
        func mix(_ a: Hand, _ b: Hand, _ u: Double) -> Hand {
            let c = min(1, max(0, u)), e = c * c * (3 - 2 * c)
            return Hand(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e, angle: a.angle + (b.angle - a.angle) * e)
        }
        if k < 0.35 { return [mix(side, stem, k / 0.35)] }
        if k < 1.45 {
            let rub = sin(k * 34)
            return [Hand(x: stem.x + rub * 0.07, y: stem.y, angle: stem.angle + rub * 0.15)]
        }
        return [mix(stem, side, min(1, (k - 1.45) / 0.35))]
    }

    /// The eyes mirror follows `eyeStrain` slowly up and quickly down; a rest (a big drop) blinks twice.
    private func stepStrain(dt: Double, t: Double) {
        if eyeStrain + 0.25 < strainShown, !strainBlinked {
            blinkStart = t
            doubleBlink = true
            strainBlinked = true
        }
        if strainShown <= eyeStrain + 0.05 { strainBlinked = false }
        strainShown = eyeStrain > strainShown
            ? min(eyeStrain, strainShown + Self.strainRise * dt)
            : max(eyeStrain, strainShown - Self.strainFall * dt)
    }

    /// Enter: cursor on the visible part of the body → he hops fully out from behind the edge.
    /// Stay: while the cursor is anywhere between his left side and the screen edge (he moved away from
    /// under it, that must not count as leaving). Leave: only after a short grace period (no flicker).
    private func updateHover(pointer: CGPoint?, center: CGPoint) {
        // The nominal scene is not a screen edge. A roaming / returning body can extend past it
        // and still be visible and interactive; physical screen coordinates already bound the cursor.
        guard !isCarried, let p = pointer else {
            if isCarried { isHovering = false; hoverLostAt = nil } else { loseHover() }
            return
        }
        let px = Double(p.x), py = Double(p.y)
        let enter = contains(p)
        let stay = isHovering && px >= Double(center.x) - metrics.radiusX * 1.25
            && px <= max(metrics.width + 2, Double(center.x) + metrics.radiusX * 1.25)
            && abs(py - Double(center.y)) <= metrics.radiusY * 1.5
        if enter || stay {
            hoverLostAt = nil
            if !isHovering {
                isHovering = true
                if !isAsleep && !slumped { hop.impulse(-240); leaf.impulse(5) }   // "выпрыгивает"; lying, he does not
            }
        } else {
            loseHover()
        }
    }

    private func loseHover() {
        guard isHovering else { return }
        if hoverLostAt == nil { hoverLostAt = time }
        if time - hoverLostAt! >= Self.hoverGrace { isHovering = false; hoverLostAt = nil }
    }

    private func pickAntic() -> Antic {
        let all = Antic.allCases
        let weights = all.map { $0 == .yawn ? (isNight ? 6.0 : 1.0) + fatigue * 2 : 1.0 }
        var roll = rng.uniform(0, weights.reduce(0, +))
        for (a, w) in zip(all, weights) {
            if roll < w { return a }
            roll -= w
        }
        return all[all.count - 1]
    }

    // MARK: Output

    public var pose: CharacterPose {
        let t = time
        let lying = Lying.eased(lieLevel)
        let period = 3.6 + fatigue * 1.8 + sleepLevel * 1.6 + lying * 2.2
        let breathing = sin(t * .pi * 2 / period + phase) * (1 + sleepLevel * 0.6 + lying * 1.0)   // slow and heavy
        let sag = sagLevel
        // Slice 6a: tiredness no longer closes the eyes — only sleep, blinks and yawns do.
        var open = lid * (1 - sleepLevel) * (1 - lying * 0.5)          // lying: half-closed (6b)
        let m = mood
        if m.yawning { open = min(open, 0.1) }

        // Breathing exercise: inflate on the in-breath, deflate on the out-breath (eased).
        var inflate = 0.0
        if let b = breath {
            let e = 0.5 - 0.5 * cos(b.progress * .pi)
            inflate = b.inhaling ? e : 1 - e
            open = min(open, 1 - inflate * 0.5)
        }
        if mug.value > 0.7 { open = min(open, 0.05) }          // eyes shut while sipping: ^ ^

        var p = CharacterPose()
        p.time = t
        p.phase = phase
        p.x = x.value
        p.hop = hop.value + jumpY
        p.scaleY = (1 - squash.value * 0.22) * (1 + breathing * 0.024) * (1 + inflate * 0.12) * (1 - sag * 0.07)
        p.scaleX = (1 + squash.value * 0.16) * (1 - breathing * 0.012) * (1 + inflate * 0.1) * (1 + sag * 0.06)
        p.tilt = tilt.value
        p.lookX = lookX.value
        p.lookY = lookY.value
        p.eyeScale = eyeScale.value
        p.eyeOpen = open
        p.leafAngle = leaf.value - inflate * 0.15
        p.fatigue = fatigue
        p.sleep = sleepLevel
        p.sag = sag
        p.eyeStrain = strainShown
        p.hands = hands
        p.speck = currentAntic == .catchSpeck && t < anticUntil ? speckPoint(k: t - anticStart) : nil
        if act == .cheer, t - actStart < 1.7 {
            let u = (t - actStart) / 1.7
            p.leafSpin = 6 * .pi * (1 - (1 - u) * (1 - u))           // a propeller, slowing to whole turns
        }
        if let c = confettiAt, t - c < Self.confettiLife {
            p.confettiAge = t - c
            p.confettiOrigin = confettiOrigin
        }
        p.passThrough = act == .hops
        p.lying = lying
        p.mood = m
        p.calledAge = t - calledAt
        p.props = props
        p.mugLift = min(1, max(0, mug.value))
        p.earsUp = max(0, ears.value)
        p.earWiggle = listening ? sin(t * 22) * 0.14 * min(1, hearing) : 0
        p.earsDroop = earsDroop
        if t < bubbleUntil, let text = bubbleText {
            p.bubble = text
            p.bubbleAge = t - bubbleAt
            p.bubbleRemaining = bubbleUntil - t
            p.buttons = bubbleButtons
            p.hoveredButton = hoveredButton
        }
        return p
    }

    private var lid: Double {
        guard let start = blinkStart else { return 1 }
        let k = time - start
        if k < 0.07 { return 1 - k / 0.07 }
        if k < 0.11 { return 0 }
        return min(1, max(0, (k - 0.11) / 0.12))
    }
}
