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
    // Slice 6c: emotions from Codex and petting.
    /// «Смеётся»: ^ ^ with tears, a «D» mouth.
    public var laughing = false
    /// Slice 6f-2: dancing under the disco ball (^ ^).
    public var dancing = false
    /// The clown's stone face: heavy lids, a flat mouth, eyes on the user.
    public var deadpan = false
    /// «Обиделся» after the «><»: turned away towards the edge, a frown.
    public var sulking = false
    /// Being petted: ^ ^, a brighter blush.
    public var petted = false
    /// One eye shut for a moment when the petting ends.
    public var winking = false
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
    /// `roll`: any other rotation about the feet that must rest on the floor (6c: on his back, laughing).
    public static func frame(lying: Double, tilt: Double, rx: Double, ry: Double, roll: Double = 0)
        -> (angle: Double, lift: Double, dx: Double, dy: Double, halfHeight: Double) {
        guard lying > 0.001 || abs(roll) > 0.001 else { return (tilt, 0, 0, -ry, ry) }
        let a = tilt + turn * lying + roll
        let h = ((rx * sin(a)) * (rx * sin(a)) + (ry * cos(a)) * (ry * cos(a))).squareRoot()
        let lift = -(h - ry * cos(a))
        return (a, lift, ry * sin(a), lift - ry * cos(a), h)
    }

    /// Whether the frame is turned enough to need the lifted plan (shadow and bubble follow the body).
    public static func turned(lying: Double, roll: Double) -> Bool { lying > 0.001 || abs(roll) > 0.001 }
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
/// `lurk`: hidden behind the edge, he leans out to peek (slice 6d).
public enum StandOut: Sendable, Equatable {
    case docked, peek, out, center, away, lurk
}

/// Things he can hold or wear. Order = drawing order (behind → front).
public enum Prop: String, CaseIterable, Sendable, Hashable {
    case backpack, hat, mug
    /// Slice 6f-1: the light around him — a nightcap to sleep in, a lamp beside him, sunglasses.
    case nightcap, lamp, sunglasses
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
    // Slice 6c (decisions 12–14): emotions Codex asks for.
    /// «Смеётся»: leans back and shakes, tears, a slapping hand, «ХА» from behind the edge; `strong` — on his back,
    /// kicking his feet, then up again.
    case laugh(strong: Bool)
    /// The rare clown: a pause, a slow look, a red nose and a wig, a stone face, off again. Silent.
    case clown
    /// «Обиделся»: «><», «хмф» — then turned away.
    case sulk
    /// «Голова кругом»: the dizzy face of three pokes.
    case spin
    /// «Грустит»: the sad face, the sprout droops.
    case mope
    /// Slice 6e: the leap to another monitor — the app flies the window along a `HopArc`; he crouches, flies with his
    /// hands tucked and the sprout fluttering, lands squashed. `dir`: +1 towards the screen edge, −1 into the screen.
    case leap(seconds: Double, dir: Double)
    /// Slice 6f-2: the disco dance — sways on the beat, arms up in turn, a spin now and then, no jumps; a bow at the end.
    case dance(seconds: Double)

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
        case .laugh(let strong): strong ? 3.6 : 2.5
        case .clown: 3.5
        case .sulk: 2.2
        case .spin: 2.6
        case .mope: 2.8
        case .leap(let s, _): s
        case .dance(let s): s
        }
    }

    /// An emotion (slice 6c): he comes out to show it; petting and antics wait.
    public var isEmotion: Bool {
        switch self {
        case .cheer, .laugh, .clown, .sulk, .spin, .mope: true
        default: false
        }
    }

    /// Slice 6f-2: the disco dance (shown out from behind the edge like an emotion).
    public var isDance: Bool {
        if case .dance = self { return true }
        return false
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
    /// 6b «измотан» (0…1): the deepest sag, half-closed eyes, heavy sighs, a slow sway — standing, no flip.
    public var exhausted: Double = 0
    // Slice 6c
    /// On his back while laughing hard: extra rotation about the feet (radians, + = towards the edge).
    public var roll: Double = 0
    /// Seconds into the tears / the «ХА ХА ХА» of a laugh (nil = none); `haCount` words in all.
    public var tearAge: Double?
    public var haAge: Double?
    public var haCount = 3
    /// Kicking feet (seconds into the kicking), only on his back.
    public var feet: Double?
    /// The clown's red nose (0…1, scale) and wig (0…1, opacity) with its drop from above (points, negative = up).
    public var clownNose: Double = 0
    public var clownWig: Double = 0
    public var wigDrop: Double = 0
    /// The blush glows while he is petted (0…1).
    public var blushHot: Double = 0
    /// Slice 6d: the «пф!» puff when he dives behind the edge — seconds since, and where (scene coordinates).
    public var puffAge: Double?
    public var puffOrigin: CGPoint = .zero
    /// Slice 6e: 0…1 — the window is flying him to another monitor (no floor under him: the shadow fades).
    public var airborne: Double = 0
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
    /// Slice 6d: he lives behind the screen edge — `standOut == .docked` («home») is then out of sight, `.lurk` peeks.
    /// Everything that brings him out (`.peek`, `.out`, `.center`, a call) still does, and home is behind the edge again.
    public var hidden = false
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
    /// Breathing phase, integrated in `step` (acceptance 2026-10-06): the period follows sleep, fatigue and exhaustion,
    /// and `sin(time · 2π / period)` made every period change after a long run a phase jump of hundreds of radians.
    private var breathPhase = 0.0

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
    private var lieLevel = 0.0
    private var nextSigh = 0.0
    // Slice 6c: petting.
    private var strokeX = StrokeAxis(), strokeY = StrokeAxis()
    private var reversals: [Double] = []
    private var lastReversal = -99.0
    private var pettingSince: Double?
    private var pettingLean = 0.0
    private var winkAt = -99.0
    private var blushHotLevel = 0.0
    private var clownGaze = (x: 0.0, y: 0.0)
    // Slice 6f-1
    private var nightcapSleepAt: Double?
    private var sleptInNightcap = false
    // Slice 6d
    private var wasHome = false
    private var diveAt = -99.0
    private var diveFrom = 0.0
    private var puffPending = false
    private var puffAt: Double?
    private var puffOriginPoint = CGPoint.zero

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
    /// Petting (backlog item 2): this many turns of a stroke (each ≥ `strokeTravel` points) inside `pettingWindow`
    /// seconds; it lasts while turns keep coming within `pettingHold`. Then a wink, if it lasted `winkAfter`.
    public static let pettingTurns = 3, pettingWindow = 1.5, pettingHold = 0.9, strokeTravel = 10.0
    public static let winkAfter = 1.0, winkDuration = 0.5
    nonisolated public static let confettiLife = 1.4
    nonisolated public static let puffLife = 0.6
    /// Slice 6f-2: the dance's beat (120 bpm) and the bow at its end.
    public static let danceBeat = 0.5
    public static let danceBow = 1.4
    /// Diving behind the edge: slowly, then a dash (ease-in), leaning in so the sprout goes last.
    public static let diveDuration = 0.8

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
        let r = roll
        // «Измотан» (acceptance 2026-10-06) stands: only the laugh's fall (`roll`) turns him.
        let lie = Lying.frame(lying: 0, tilt: tilt.value, rx: metrics.radiusX, ry: ry, roll: r)
        guard Lying.turned(lying: 0, roll: r) else { return CGPoint(x: x.value, y: metrics.ground + hop.value + jumpY - ry) }
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
        if Lying.turned(lying: 0, roll: roll) {                 // into the turned body's own axes
            let a = Lying.frame(lying: 0, tilt: tilt.value, rx: metrics.radiusX, ry: metrics.radiusY,
                                roll: roll).angle
            (px, py) = (px * cos(a) + py * sin(a), -px * sin(a) + py * cos(a))
        }
        let dx = px / metrics.radiusX
        let dy = py / metrics.radiusY
        return dx * dx + dy * dy < hitScale * hitScale
    }

    private var hitScale = 1.05

    public var mood: Mood {
        var m = Mood()
        m.called = time < calledUntil
        m.dizzy = time < dizzyUntil || act == .spin
        m.annoyed = time < annoyedUntil || (act == .sulk && time - actStart < 0.7)
        m.yawning = currentAntic == .yawn && time < anticUntil
        m.sleeping = sleepLevel > 0.6
        m.carried = isCarried
        m.sad = isSad || act == .mope
        m.slumped = lieLevel > 0.4
        if let a = act {
            let k = time - actStart
            m.cheering = a == .cheer && k < 1.7
            m.dancing = a.isDance && k < a.duration - Self.danceBow
            m.focused = a == .hops
            if case .laugh = a { m.laughing = k < a.duration - 0.2 }
            m.deadpan = a == .clown && k >= 1.7 && k < 3.2
            m.sulking = a == .sulk && k >= 0.7
        }
        if currentAntic == .catchSpeck, time < anticUntil {
            let k = time - anticStart
            m.chomping = k >= 1.45 && k < 1.62
            m.chewing = k >= 1.62 && k < 2.6
        }
        m.petted = pettingSince != nil
        m.winking = time - winkAt < Self.winkDuration
        return m
    }

    public var isNight: Bool { hourOfDay >= 23 || hourOfDay < 6 }

    /// Slice 6d: at home behind the edge — out of sight (a call or being carried brings him out).
    public var isHiddenHome: Bool { hidden && standOut == .docked && time >= calledUntil && !isCarried }

    /// Hidden and peeking or at home: hovering does not pull him out, petting and antics wait.
    private var tucked: Bool { hidden && (standOut == .docked || standOut == .lurk) && time >= calledUntil && !isCarried }

    /// At launch, hidden: already behind the edge, no dive and no puff.
    public func snapHidden() {
        guard hidden else { return }
        x.value = metrics.awayX
        x.target = metrics.awayX
        x.velocity = 0
        wasHome = true
    }

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
        if let p = puffAt, time - p < Self.puffLife { return "puff" }
        if blinkStart != nil { return "blink" }
        if m.winking || blushHotLevel > 0.01 { return "petting" }
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
    public var passesClicks: Bool {
        if case .leap = act { return true }                              // 6e: clicks go through while he flies
        return act == .hops && !hopsTakeClicks
    }

    /// The hops are the intro of a stretch request (6a): a click on him shows the bubble at once, so he takes clicks.
    public var hopsTakeClicks = false

    /// A credited eye rest (6a, decision 4): a double blink, and the mirror fades as `eyeStrain` drops.
    public func eyesRested() {
        blinkStart = time
        doubleBlink = true
    }

    /// Shows the eyes mirror at once (the popover hero is a fresh Чилк every time it opens).
    public func snapEyeStrain() {
        strainShown = eyeStrain
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

    /// Slice 6f-1: dark — the nightcap instead of the hat, a yawn, then asleep; waking up takes the cap off.
    public func putOnNightcap() {
        props.remove(.hat)
        wear(.nightcap)
        nightcapSleepAt = time + Antic.yawn.duration + 0.4
        if act == nil, !isAsleep { beginAntic(.yawn, at: time) }
    }

    private func stepNightcap(t: Double) {
        guard props.contains(.nightcap) else { nightcapSleepAt = nil; sleptInNightcap = false; return }
        if let at = nightcapSleepAt, t >= at {
            nightcapSleepAt = nil
            fallAsleep()
            sleptInNightcap = true
        }
        if sleptInNightcap, !isAsleep {                                     // woken up: off with the cap
            sleptInNightcap = false
            props.remove(.nightcap)
        }
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
        if a.isEmotion { endPetting(wink: false) }
    }

    /// Slice 6c (decision 11): an emotion Codex asked for, played at once.
    public func emote(_ e: Emotion, strong: Bool) {
        perform(Self.emotionAct(e, strong: strong))
    }

    /// The scene of each emotion (its length is how long the words' bubble must stay for it).
    public nonisolated static func emotionAct(_ e: Emotion, strong: Bool) -> Act {
        switch e {
        case .cheer: .cheer
        case .laugh: .laugh(strong: strong)
        case .clown: .clown
        case .offended: .sulk
        case .dizzy: .spin
        case .sad: .mope
        }
    }

    /// How long a bubble takes to show all its words (they arrive one by one: 0.45 s, then 0.08 s each, 0.2 s fade).
    public nonisolated static func revealTime(_ text: String) -> Double {
        0.65 + Double(max(0, text.split(whereSeparator: \.isWhitespace).count - 1)) * 0.08
    }

    /// Seconds until every word of the current bubble is on screen (0 when none shows).
    public var bubbleRevealLeft: Double {
        guard isTalking else { return 0 }
        return max(0, Self.revealTime(bubbleText ?? "") - (time - bubbleAt))
    }

    /// An emotion is playing (the voice answer waits for it; a second one is not started over it).
    public var isEmoting: Bool { act?.isEmotion ?? false }

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
        if p == .hat { props.remove(.nightcap) }                     // 6f: never two hats; off to the walk
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
        breathPhase = (breathPhase + dt * .pi * 2 / breathPeriod).truncatingRemainder(dividingBy: .pi * 2)
        let drowsy = sleepLevel > 0.05
        lieLevel = min(1, max(0, lieLevel + (slumped ? dt / Self.lieDown : -dt / Self.getUp)))
        let lying = Lying.eased(lieLevel)
        if slumped { currentAntic = nil }

        updateHover(pointer: pointer, center: center)
        stepPetting(pointer: pointer, center: center, t: t, dt: dt)

        // Dragging speed is clamped: a fast flick must tilt him, not spin him (and keep him inside his paint bounds).
        let carry = min(Self.maxCarrySpeed, max(-Self.maxCarrySpeed, carryVelocity))
        let stand: Double = switch standOut {
        case .docked: metrics.dockX
        case .peek: metrics.peekX
        case .out: metrics.outX
        case .center: metrics.carryX
        case .away: metrics.awayX
        case .lurk: metrics.lurkX
        }
        // A call brings him out even from behind the edge (the tray then takes him back from the popover).
        x.target = m.carried || standOut == .center ? metrics.carryX
            : (m.called ? metrics.outX
               : (standOut == .away ? stand : (isHovering ? min(metrics.peekX, stand) : stand)))
        // Slice 6d: hidden, home is behind the edge and a peek stays there — hovering does not pull him out.
        if tucked { x.target = standOut == .lurk ? metrics.lurkX : metrics.awayX }
        if let h = hopX, !m.carried { x.target = h }              // between the hops he stays where he landed
        // An emotion is shown out from behind the edge (6c); falling on his back needs a little more room.
        if let a = act, a.isEmotion || a.isDance, !m.carried {
            x.target = min(x.target, a == .laugh(strong: true) ? metrics.peekX - 40 : metrics.peekX)
        }
        let sag = postureSag
        tilt.target = (m.called ? 0 : -0.1) - x.velocity * 0.0011 - carry * 0.0006
            + (m.dizzy ? sin(t * 9) * 0.12 : 0) + sleepLevel * 0.08 - sag * 0.07
            + lying * sin(t * .pi * 2 / 5.5 + phase) * 0.07              // «измотан»: a slow, heavy sway
        stepHiding(t: t)
        stepNightcap(t: t)
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
        if !m.called && !m.dizzy && !m.carried && !drowsy && act == nil && lieLevel == 0 && pettingSince == nil
            && !tucked && t > nextAntic {
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
        leaf.target = -0.06 + fatigue * 0.35 + sleepLevel * 0.22 + (m.sad ? 0.3 : 0) + lying * 0.5
            + sin(t * 0.9 + phase) * 0.07 * (1 - sleepLevel * 0.6) + sin(t * 2.3) * 0.025
        if case .think = act { leaf.target += sin((t - actStart) * 2.4) * 0.3 }
        if pettingSince != nil {                                     // petted: the sprout sways happily, he leans in
            leaf.target += sin(t * 7) * 0.22
            tilt.target += pettingLean
        }
        if act == .clown, t - actStart >= 1.7 { leaf.target = -0.06; blinkAt = max(blinkAt, t + 1) }   // stone still
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
        case .laugh(let strong):
            // Bursts out, leans back towards the edge and shakes (the shake itself is in the pose); hard: on his back.
            beat(0) { squash.impulse(4.5); hop.impulse(-140); leaf.impulse(6) }
            if strong {
                beat(0.5) { squash.impulse(-3) }
                beat(0.85) { squash.impulse(5); leaf.impulse(-6) }          // lands on his back
                beat(3.25) { hop.impulse(-150); leaf.impulse(5) }            // up again
            }
            let env = Self.envelope(k, length: a.duration, rise: 0.25, fall: 0.35)
            tilt.target += (strong && k > 0.5 ? 0 : 0.24 * env) + sin(k * 30) * 0.035 * env
            lookX.target = -0.1
            lookY.target = -0.25
        case .clown:
            // A pause, a slow look at the user, nose, wig, a stone face (slice 6c, decision 13). Silent.
            beat(0) { clownGaze = (lookX.value, lookY.value) }
            let u = Self.ease((k - 0.35) / 0.6)
            lookX.target = clownGaze.x * (1 - u)
            lookY.target = clownGaze.y * (1 - u) + 0.05 * u
            beat(1.65) { squash.impulse(2.5) }                                 // the wig lands
            if k >= 1.7 && k < 3.2 { tilt.target = -0.02 }
        case .sulk:
            beat(0) { squash.impulse(5); leaf.impulse(-4) }                    // «хмф»
            if k >= 0.7 { lookX.target = 0.9; lookY.target = -0.15; tilt.target += 0.12 }
        case .spin:
            beat(0) { squash.impulse(4); leaf.impulse(6) }
        case .mope:
            beat(0.6) { squash.impulse(-3) }                                   // a sigh
            lookX.target = -0.1
            lookY.target = 0.35
        case .leap(let s, let dir):
            let landAt = s - HopArc.land
            beat(0) { squash.impulse(6) }                                       // crouch
            beat(HopArc.crouch) { squash.impulse(-7); leaf.impulse(9 * dir) }   // push off
            if k >= HopArc.crouch && k < landAt {
                tilt.target += 0.22 * dir                                      // leaning into the flight
                lookX.target = dir > 0 ? 0.7 : -0.7
                lookY.target = 0.1
                if k >= HopArc.crouch + Double(actBeats - 2) * 0.11 + 0.11 {   // the sprout flutters in the wind
                    leaf.impulse((actBeats % 2 == 0 ? 7 : -7) - 3 * dir)
                    actBeats += 1
                }
            }
            if k >= landAt, actBeats < 1000 { squash.impulse(8); leaf.impulse(-6 * dir); actBeats = 1000 }   // landing
        case .dance(let s):
            let beat = Self.danceBeat, bowAt = s - Self.danceBow
            if k < bowAt {
                let b = Int(k / beat)
                if b + 1 > actBeats { actBeats = b + 1; squash.impulse(2.2); leaf.impulse(b % 2 == 0 ? 4.5 : -4.5) }
                let sway = sin(k * .pi / beat)
                tilt.target += sway * 0.16                                     // one side per beat
                lookX.target = sway * 0.4
                lookY.target = -0.1
            } else {
                if actBeats < 10_000 { squash.impulse(3); leaf.impulse(-5); actBeats = 10_000 }
                tilt.target = -0.45                                            // a bow
                lookY.target = 0.6
            }
        }
    }

    /// 0 → 1 over `rise`, 1 → 0 over the last `fall` seconds of `length`.
    static func envelope(_ k: Double, length: Double, rise: Double, fall: Double) -> Double {
        min(1, max(0, k / rise), max(0, (length - k) / fall))
    }

    static func ease(_ u: Double) -> Double {
        let c = min(1, max(0, u))
        return c * c * (3 - 2 * c)
    }

    /// On his back while laughing hard (6c): over in 0.35 s, ~1.9 s down, up in 0.5 s. Towards the edge (+).
    private var roll: Double {
        guard act == .laugh(strong: true) else { return 0 }
        let k = time - actStart
        return 1.35 * (Self.ease((k - 0.5) / 0.35) - Self.ease((k - 2.75) / 0.5))
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
        case .lurk: metrics.lurkX
        }
    }

    /// Tiredness as posture (6a, decision 3): nothing until ~half-way, full sag when the sprout is wilted.
    private var sagLevel: Double { min(1, max(0, (fatigue - 0.45) / 0.55)) }
    /// The pose's sag: fatigue's, or deeper when «измотан» (6b) — lower than the most tired he is otherwise.
    private var postureSag: Double { max(sagLevel, Lying.eased(lieLevel) * 1.35) }

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
        if case .leap(let s, let dir) = act, t - actStart > HopArc.crouch, t - actStart < s - HopArc.land {
            // 6e: short arms swept back against the flight (floating mittens read as balls).
            let back = dir > 0 ? -2.25 : 2.25
            return [Hand(x: -0.78, y: 0.12, angle: back, arm: true), Hand(x: 0.78, y: 0.12, angle: back, arm: true)]
        }
        if case .dance(let s) = act, t - actStart < s - Self.danceBow {
            // 6f-2: one arm up per beat, in turn, waving a little.
            let k = t - actStart
            let left = Int(k / Self.danceBeat) % 2 == 0
            let w = sin(k * 14) * 0.15
            return [left ? Hand(x: -0.8, y: -0.28, angle: -0.95 + w, arm: true) : Hand(x: 0.8, y: -0.28, angle: 0.95 - w, arm: true)]
        }
        if act == .cheer, t - actStart < 1.7 {
            let w = sin((t - actStart) * 16) * 0.16                    // both arms up, waving
            return [Hand(x: -0.8, y: -0.28, angle: -0.95 + w, arm: true), Hand(x: 0.8, y: -0.28, angle: 0.95 - w, arm: true)]   // ＼(^o^)／
        }
        if case .laugh(let strong) = act {
            // Slaps the screen edge with his palm — not while on his back (the feet kick then).
            let k = t - actStart
            guard k > 0.25, k < (strong ? 0.5 : act!.duration - 0.3) else { return [] }
            let slap = abs(sin((k - 0.25) * .pi / 0.34))                   // down on every beat
            return [Hand(x: 0.98, y: 0.05 + slap * 0.4, angle: -0.5 + slap * 0.6)]
        }
        if act == .clown {
            // The hand brings the nose up to his face, then goes back.
            let k = t - actStart
            let side = Hand(x: -1.0, y: 0.35, angle: 0.2), face = Hand(x: -0.12, y: 0.2, angle: -0.3)
            func mix(_ a: Hand, _ b: Hand, _ u: Double) -> Hand {
                let e = Self.ease(u)
                return Hand(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e, angle: a.angle + (b.angle - a.angle) * e)
            }
            if k >= 0.9 && k < 1.25 { return [mix(side, face, (k - 0.9) / 0.35)] }
            if k >= 1.25 && k < 1.6 { return [mix(face, side, (k - 1.25) / 0.35)] }
            return []
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

    /// The eyes mirror follows `eyeStrain` slowly up and quickly down (the rest's double blink — `eyesRested`).
    private func stepStrain(dt: Double, t: Double) {
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
                if !isAsleep && !slumped && !isEmoting && !tucked { hop.impulse(-240); leaf.impulse(5) }   // "выпрыгивает"
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

    // MARK: Petting (slice 6c, backlog item 2)

    /// Turns of a stroke along one axis: a turn counts once the cursor went `strokeTravel` points one way and as far
    /// back. Jitter never adds up to a turn.
    struct StrokeAxis {
        private var anchor: Double?
        private var direction = 0

        mutating func feed(_ v: Double, travel: Double) -> Bool {
            guard let a = anchor else { anchor = v; return false }
            let d = v - a
            if direction == 0 {
                if abs(d) >= travel { direction = d > 0 ? 1 : -1; anchor = v }
                return false
            }
            if Double(direction) * d > 0 { anchor = v; return false }   // further the same way: the extreme moves
            guard abs(d) >= travel else { return false }
            direction = -direction
            anchor = v
            return true
        }
    }

    private var canBePetted: Bool {
        !isAsleep && sleepLevel < 0.05 && !isCarried && !slumped && lieLevel == 0 && act == nil && !eyesWide && !tucked
    }

    // MARK: Hiding (slice 6d)

    /// Home behind the edge: dives in leaning towards the screen (the sprout disappears last) with a «пф!» as he
    /// vanishes; leaving home he hops out. Peeking, he leans out from behind the edge.
    private func stepHiding(t: Double) {
        let home = isHiddenHome
        if home && !wasHome {
            if x.value - metrics.radiusX * 1.15 >= metrics.width {
                // Already out of sight (back from the popover, where he ducked behind the edge): no dive, no «пф!».
                diveAt = -99
                puffPending = false
            } else {
                diveAt = t
                diveFrom = x.value
                puffPending = true
            }
            currentAntic = nil
        } else if !home && wasHome {
            hop.impulse(-240)
            leaf.impulse(5)
            puffPending = false
        }
        wasHome = home
        let k = t - diveAt
        if home, k < Self.diveDuration {
            // A scripted slide (a spring would snap him away in ~0.2 s): slow at first, then a dash behind the edge.
            let u = k / Self.diveDuration
            let to = metrics.awayX
            x.value = diveFrom + (to - diveFrom) * u * u
            x.velocity = 2 * (to - diveFrom) * u / Self.diveDuration
            x.target = x.value
            tilt.target -= 0.5 * Self.envelope(k, length: Self.diveDuration, rise: 0.15, fall: 0.25)
        }
        // The puff comes once he is out of sight (leaning in, his drawn body is ~25 pt further in than `x`).
        if home, puffPending, x.value - metrics.radiusX * 1.15 >= metrics.width {
            puffPending = false
            puffAt = t
            let c = bodyCenter
            puffOriginPoint = CGPoint(x: metrics.width - 2, y: Double(c.y) - metrics.radiusY * 0.4)
        }
        if tucked, standOut == .lurk { tilt.target -= 0.42 }                 // leaning out from behind the edge
    }

    private func stepPetting(pointer: CGPoint?, center: CGPoint, t: Double, dt: Double) {
        hitScale = 1.15
        let inside = pointer.map(contains) ?? false
        hitScale = 1.05
        if canBePetted, inside, let p = pointer {
            let rx = Double(p.x) - Double(center.x), ry = Double(p.y) - Double(center.y)
            let turnedX = strokeX.feed(rx, travel: Self.strokeTravel)
            let turnedY = strokeY.feed(ry, travel: Self.strokeTravel)
            if turnedX || turnedY { reversals.append(t); lastReversal = t }
            pettingLean = max(-1, min(1, rx / metrics.radiusX)) * 0.09        // he leans into the hand
        } else {
            strokeX = StrokeAxis()
            strokeY = StrokeAxis()
        }
        reversals.removeAll { t - $0 > Self.pettingWindow }
        if pettingSince == nil, canBePetted, reversals.count >= Self.pettingTurns {
            pettingSince = t
            currentAntic = nil
            leaf.impulse(4)
            squash.impulse(-2)
        }
        if pettingSince != nil, !canBePetted || t - lastReversal > Self.pettingHold { endPetting(wink: canBePetted) }
        let target = pettingSince != nil ? 1.0 : 0.0
        blushHotLevel = target > blushHotLevel ? min(target, blushHotLevel + dt * 3) : max(target, blushHotLevel - dt * 2.5)
    }

    /// The petting is over; a wink if it lasted (never when an emotion or sleep cut it).
    private func endPetting(wink: Bool) {
        guard let since = pettingSince else { return }
        if wink, time - since >= Self.winkAfter { winkAt = time; leaf.impulse(3) }
        pettingSince = nil
        reversals.removeAll()
        pettingLean = 0
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

    /// Seconds per breath: slower when tired, asleep or exhausted.
    private var breathPeriod: Double { 3.6 + fatigue * 1.8 + sleepLevel * 1.6 + Lying.eased(lieLevel) * 2.2 }

    public var pose: CharacterPose {
        let t = time
        let lying = Lying.eased(lieLevel)
        let breathing = sin(breathPhase + phase) * (1 + sleepLevel * 0.6 + lying * 1.0)   // slow and heavy
        let sag = postureSag
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
        p.fatigue = max(fatigue, Lying.eased(lieLevel))       // «измотан»: the sprout wilts all the way
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
        if case .leap(let s, _) = act {
            p.passThrough = true
            p.airborne = Self.envelope(t - actStart - HopArc.crouch, length: s - HopArc.crouch - HopArc.land, rise: 0.12, fall: 0.12)
        }
        if case .dance(let s) = act {
            // A spin every 6 s from the 3rd: he turns round in 0.7 s (seen from the front: thin, then the other way).
            let k = t - actStart, ph = (k - 3).truncatingRemainder(dividingBy: 6)
            if k >= 3, k < s - Self.danceBow - 0.2, ph < 0.7 {
                let c = cos(ph / 0.7 * 2 * .pi)
                p.scaleX *= c < 0 ? min(-0.08, c) : max(0.08, c)
            }
        }
        p.lying = 0                                                     // no flip on his side any more
        p.exhausted = lying
        if let a = puffAt, t - a < Self.puffLife {
            p.puffAge = t - a
            p.puffOrigin = puffOriginPoint
        }
        // Slice 6c: the emotions' extras.
        p.roll = roll
        p.blushHot = blushHotLevel
        if pettingSince != nil {                                         // melts a little
            p.scaleY *= 0.97
            p.scaleX *= 1.02
        }
        if let a = act {
            let k = t - actStart
            switch a {
            case .laugh(let strong):
                let env = Self.envelope(k, length: a.duration, rise: 0.2, fall: 0.3)
                p.scaleY *= 1 + sin(k * 38) * 0.035 * env                   // shaking with laughter
                p.scaleX *= 1 - sin(k * 38) * 0.022 * env
                if !(strong && k > 0.5 && k < 3.25) { p.hop -= abs(sin(k * 12)) * 4 * env }   // chuckling bounces
                if k > 0.2 && k < a.duration - 0.15 { p.tearAge = k - 0.2 }
                p.haAge = k - 0.2
                p.haCount = strong ? 6 : 3
                if strong, k > 0.75, k < 2.9 { p.feet = k - 0.75 }
            case .clown:
                if k < 1.25 { p.clownNose = 0 }
                else if k < 3.2 { p.clownNose = min(1, (k - 1.25) / 0.12) }
                else { p.clownNose = max(0, 1 - (k - 3.2) / 0.15) }
                if k >= 1.35 && k < 3.2 {
                    p.clownWig = 1
                    p.wigDrop = -40 * (1 - Self.ease((k - 1.35) / 0.3))
                } else if k >= 3.2 {
                    let u = min(1, (k - 3.2) / 0.28)
                    p.clownWig = 1 - u
                    p.wigDrop = -30 * Self.ease(u)
                }
                if k >= 1.7 && k < 3.2 {                                 // heavy lids, one slow blink
                    let blink = max(0, 1 - abs(k - 2.55) / 0.22)
                    p.eyeOpen = min(p.eyeOpen, 0.62 * (1 - blink))
                }
            case .sulk where k >= 0.7:
                p.scaleX *= 1.04                                          // puffed up
            case .mope:
                p.scaleY *= 0.96
                p.scaleX *= 1.03
            default:
                break
            }
        }
        p.mood = m
        p.calledAge = t - calledAt
        p.props = props
        p.mugLift = min(1, max(0, mug.value))
        p.earsUp = max(0, ears.value)
        p.earWiggle = listening ? sin(t * 22) * 0.14 * min(1, hearing) : 0
        p.earsDroop = earsDroop
        if t < bubbleUntil, let text = bubbleText, !isHiddenHome {     // 6d: no bubble from behind the edge
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
