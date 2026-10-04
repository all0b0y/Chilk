import CoreGraphics

/// Which transient moods are active. Drives faces in the renderer.
public struct Mood: Sendable, Equatable {
    public var called = false
    public var dizzy = false
    public var annoyed = false
    public var yawning = false
    public var sleeping = false
    public var carried = false
    public init() {}
}

/// Little things Чилк does on his own, "по настроению", not on a timer the user can predict.
public enum Antic: CaseIterable, Sendable {
    case hop, leafFlick, glance, yawn, stretch, wiggle

    var duration: Double {
        switch self {
        case .hop: 0.6
        case .leafFlick: 0.8
        case .glance: 1.4
        case .yawn: 1.6
        case .stretch: 1.1
        case .wiggle: 1.0
        }
    }
}

/// How far out from behind the screen edge he stands (ladder stages, activities).
public enum StandOut: Sendable, Equatable {
    case docked, peek, out
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

    public var duration: Double {
        switch self {
        case .drink: 3.0
        case .stretches: 3.3
        case .lookAway: 4.0
        case .wave: 1.6
        case .pack: 2.4
        case .breathe(let s): s
        }
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
    public var hoveredButton: Int?
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
        CGPoint(x: x.value, y: metrics.ground + hop.value - metrics.radiusY * (1 - squash.value * 0.22))
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
        let dx = (Double(p.x) - Double(c.x)) / metrics.radiusX
        let dy = (Double(p.y) - Double(c.y)) / metrics.radiusY
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
        if blinkStart != nil { return "blink" }
        // A bubble needs 60 fps while it pops in (words arrive one by one) or out — not while it just stays.
        if time < bubbleUntil && (time - bubbleAt < 2 || bubbleUntil - time < 0.4) { return "bubble" }
        if isAsleep ? sleepLevel < 1 : sleepLevel > 0 { return "sleep transition" }
        if abs(x.velocity) > 4 { return "x moving" }
        if abs(hop.velocity) > 4 { return "hop" }
        if abs(squash.velocity) > 0.05 { return "squash" }
        if abs(mug.velocity) > 0.05 { return "mug" }
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

    public var isTalking: Bool { time < bubbleUntil }

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

        updateHover(pointer: pointer, center: center)

        // Dragging speed is clamped: a fast flick must tilt him, not spin him (and keep him inside his paint bounds).
        let carry = min(Self.maxCarrySpeed, max(-Self.maxCarrySpeed, carryVelocity))
        let stand: Double = switch standOut {
        case .docked: metrics.dockX
        case .peek: metrics.peekX
        case .out: metrics.outX
        }
        x.target = m.carried ? metrics.carryX : (m.called ? metrics.outX : (isHovering ? min(metrics.peekX, stand) : stand))
        tilt.target = (m.called ? 0 : -0.1) - x.velocity * 0.0011 - carry * 0.0006
            + (m.dizzy ? sin(t * 9) * 0.12 : 0) + sleepLevel * 0.08
        eyeScale.target = m.carried ? 1.28 : (eyesWide ? 1.25 : (isHovering ? 1.18 : (m.called ? 1.08 : 1)))

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
            lookY.target = idleLook.y
            if m.called { lookX.target = -0.15; lookY.target = 0.05 }
        }

        stepAct(t: t)

        // Antics "по настроению". At night (and when tired) yawns win far more often. Not during acts.
        if t >= anticUntil { currentAntic = nil }
        if !m.called && !m.dizzy && !m.carried && !drowsy && act == nil && t > nextAntic {
            let a = pickAntic()
            currentAntic = a
            anticStart = t
            anticUntil = t + a.duration
            switch a {
            case .hop: hop.impulse(-170); leaf.impulse(3)
            case .leafFlick: leaf.impulse(10)
            case .stretch: squash.impulse(-6); leaf.impulse(4)   // tall & thin, then settle
            case .glance, .yawn, .wiggle: break
            }
            nextAntic = t + rng.uniform(8, 15)
        }
        if currentAntic == .glance && !tracking { lookX.target = -0.85; lookY.target = -0.2 }
        if currentAntic == .wiggle {
            let k = t - anticStart
            tilt.target += sin(k * 14) * 0.13 * max(0, 1 - k / Antic.wiggle.duration)
        }
        tilt.target = min(Self.maxTilt, max(-Self.maxTilt, tilt.target))

        // Leaf: droops with fatigue and sleep, sways in a breeze, lags behind body motion (follow-through).
        leaf.target = -0.06 + fatigue * 0.35 + sleepLevel * 0.22
            + sin(t * 0.9 + phase) * 0.07 * (1 - sleepLevel * 0.6) + sin(t * 2.3) * 0.025
        leaf.velocity += -x.velocity * 0.0022 - hop.velocity * 0.0009 - carry * 0.0012

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
            lookX.step(half); lookY.step(half); eyeScale.step(half); leaf.step(half); mug.step(half)
        }
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
        }
    }

    private var beatIndex = 0

    /// Enter: cursor on the visible part of the body → he hops fully out from behind the edge.
    /// Stay: while the cursor is anywhere between his left side and the screen edge (he moved away from
    /// under it, that must not count as leaving). Leave: only after a short grace period (no flicker).
    private func updateHover(pointer: CGPoint?, center: CGPoint) {
        guard !isCarried, let p = pointer, p.x >= 0, p.y >= 0, Double(p.y) <= metrics.height, Double(p.x) <= metrics.width + 2 else {
            if isCarried { isHovering = false; hoverLostAt = nil } else { loseHover() }
            return
        }
        let px = Double(p.x), py = Double(p.y)
        let enter = contains(p)
        let stay = isHovering && px >= Double(center.x) - metrics.radiusX * 1.25
            && abs(py - Double(center.y)) <= metrics.radiusY * 1.5
        if enter || stay {
            hoverLostAt = nil
            if !isHovering {
                isHovering = true
                if !isAsleep { hop.impulse(-240); leaf.impulse(5) }   // "выпрыгивает"
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
        let period = 3.6 + fatigue * 1.8 + sleepLevel * 1.6
        let breathing = sin(t * .pi * 2 / period + phase) * (1 + sleepLevel * 0.6)
        let tired = min(1, max(0, (fatigue - 0.45) / 0.55))
        var open = lid * (1 - tired * 0.55) * (1 - sleepLevel)
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
        p.hop = hop.value
        p.scaleY = (1 - squash.value * 0.22) * (1 + breathing * 0.024) * (1 + inflate * 0.12)
        p.scaleX = (1 + squash.value * 0.16) * (1 - breathing * 0.012) * (1 + inflate * 0.1)
        p.tilt = tilt.value
        p.lookX = lookX.value
        p.lookY = lookY.value
        p.eyeScale = eyeScale.value
        p.eyeOpen = open
        p.leafAngle = leaf.value - inflate * 0.15
        p.fatigue = fatigue
        p.sleep = sleepLevel
        p.mood = m
        p.calledAge = t - calledAt
        p.props = props
        p.mugLift = min(1, max(0, mug.value))
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
