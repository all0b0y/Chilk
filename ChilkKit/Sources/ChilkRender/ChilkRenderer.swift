import ChilkCore
import CoreGraphics
import Foundation

/// Draws Чилк. The scene is a list of `Placement`s (which part, where, how faded) computed from the pose;
/// both renderers consume the same list:
/// - `drawScene` — vector CoreGraphics (AppIcon, previews, reference for tests);
/// - `LayerRig` — one CALayer per part with a pre-rasterised bitmap, moved only by transforms (the app).
/// All CoreGraphics entry points expect a **y-down** context, like the HTML prototype canvas.
public enum ChilkRenderer {

    // MARK: Scene plan

    /// - Parameter mirrored: `true` when docked to the LEFT edge (the simulation always thinks "right").
    public static func placements(pose p: CharacterPose, metrics m: Metrics, mirrored: Bool) -> [Placement] {
        var out: [Placement] = []
        out.reserveCapacity(24)
        let mirror: CGAffineTransform = mirrored ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: m.width, ty: 0) : .identity

        // «Лежит» (6b) / on his back laughing (6c): turned about the feet and lifted back onto the floor.
        let lie = Lying.frame(lying: p.lying, tilt: p.tilt, rx: m.radiusX * p.scaleX, ry: m.radiusY * p.scaleY, roll: p.roll)
        let turned = Lying.turned(lying: p.lying, roll: p.roll)
        // Contact shadow: shrinks and fades while he is in the air; gone while the window flies him (6e leap).
        let lift = clamp(-p.hop / 70)
        out.append(Placement(slot: Slot.contactShadow, part: .contactShadow,
                             transform: mirror.translatedBy(x: p.x + (turned ? lie.dx : 0), y: m.ground + 3)
                                .scaledBy(x: p.scaleX * (1 - lift * 0.35), y: 1 - lift * 0.35),
                             alpha: (1 - lift * 0.6) * (1 - p.airborne)))

        let figure = mirror.translatedBy(x: p.x, y: m.ground + p.hop + lie.lift).rotated(by: lie.angle)
            .scaledBy(x: p.scaleX, y: p.scaleY).translatedBy(x: 0, y: -m.radiusY)
        figurePlacements(into: &out, pose: p, metrics: m, lineScale: 1, base: figure)

        // Slice 6a: the speck he is about to catch and the confetti of «ликует» live in scene space.
        if let s = p.speck {
            out.append(Placement(slot: Slot.speck, part: .speck, transform: mirror.translatedBy(x: s.x, y: s.y), alpha: 1))
        }
        if let age = p.confettiAge { confettiPlacements(into: &out, age: age, origin: p.confettiOrigin, mirror: mirror) }
        if p.sleep > 0.3 { zPlacements(into: &out, pose: p, metrics: m, mirror: mirror, mirrored: mirrored) }
        if let age = p.haAge { haPlacements(into: &out, age: age, count: p.haCount, pose: p, metrics: m, mirror: mirror, mirrored: mirrored) }
        if let age = p.puffAge { puffPlacements(into: &out, age: age, origin: p.puffOrigin, mirror: mirror) }
        if p.props.contains(.lamp) {                       // 6f: on the floor beside him, on the screen side
            out.append(Placement(slot: Slot.lamp, part: .lamp(lw: 1),
                                 transform: mirror.translatedBy(x: p.x - m.radiusX * 1.55, y: m.ground), alpha: 1))
        }
        if let text = p.bubble, !text.isEmpty { bubblePlacements(into: &out, pose: p, metrics: m, mirrored: mirrored, text: text) }
        return out
    }

    /// Body, sprout and face. `base` maps figure space (body centre = origin) to the target space.
    static func figurePlacements(into out: inout [Placement], pose p: CharacterPose, metrics m: Metrics,
                                 lineScale lw: Double, base: CGAffineTransform) {
        let ox = p.lookX * m.radiusX * 0.14
        let oy = p.lookY * m.radiusY * 0.12
        // Kicking feet while he lies on his back laughing (6c): out of his lower side, which then faces up, kicking.
        if let k = p.feet {
            for (i, at) in [(-0.92, 0.3, 1.25), (-0.74, 0.62, 0.95)].enumerated() {
                let angle = at.2 + sin(k * 17 + Double(i) * .pi) * 0.4
                let t = base.translatedBy(x: at.0 * m.radiusX, y: at.1 * m.radiusY).rotated(by: angle)
                out.append(Placement(slot: Slot.foot + i, part: .foot(lw: lw), transform: t, alpha: 1))
            }
        }
        out.append(Placement(slot: Slot.body, part: .body(lw: lw, shine: !p.props.contains(.hat) && !p.props.contains(.nightcap)), transform: base, alpha: 1))

        // Ears pop up while he listens (behind the head, springy, twitching with the voice).
        if p.earsUp > 0.02 {
            for (i, s) in [-1.0, 1.0].enumerated() {
                let t = base.translatedBy(x: s * m.radiusX * 0.6, y: -m.radiusY * 0.62)
                    .rotated(by: s * (0.38 + p.earsDroop * 0.9) + s * p.earWiggle)
                    .scaledBy(x: p.earsUp * (1 - p.earsDroop * 0.3), y: p.earsUp * (1 - p.earsDroop * 0.3))
                out.append(Placement(slot: Slot.ear + i, part: .ear(lw: lw), transform: t, alpha: 1))
            }
        }

        // Props: backpack on his back with a strap over the shoulder, a beanie, a mug in his "hand".
        if p.props.contains(.backpack) {
            out.append(Placement(slot: Slot.backpack, part: .backpack(lw: lw), transform: base, alpha: 1))
            out.append(Placement(slot: Slot.strap, part: .strap(lw: lw), transform: base, alpha: 1))
        }
        if p.props.contains(.nightcap) {                      // 6f: instead of the beanie (never both)
            out.append(Placement(slot: Slot.hat, part: .nightcap(lw: lw), transform: base.translatedBy(x: ox * 0.2, y: -m.radiusY * 0.86), alpha: 1))
        } else if p.props.contains(.hat) {
            out.append(Placement(slot: Slot.hat, part: .hat(lw: lw), transform: base.translatedBy(x: ox * 0.2, y: -m.radiusY * 0.86), alpha: 1))
        }
        if p.clownWig > 0.01 {                              // the clown's tufts; the sprout grows on the bald top
            out.append(Placement(slot: Slot.wig, part: .wig(lw: lw),
                                 transform: base.translatedBy(x: ox * 0.2, y: -m.radiusY * 0.78 + p.wigDrop), alpha: clamp(p.clownWig)))
        }
        if p.props.contains(.mug) {
            let k = p.mugLift
            let side = CGPoint(x: -m.radiusX * 1.02, y: m.radiusY * 0.32)
            let mouth = CGPoint(x: ox * 0.8 - 13, y: m.radiusY * 0.12)
            let at = CGPoint(x: side.x + (mouth.x - side.x) * k, y: side.y + (mouth.y - side.y) * k)
            out.append(Placement(slot: Slot.mug, part: .mug(lw: lw), transform: base.translatedBy(x: at.x, y: at.y).rotated(by: k * 0.75).scaledBy(x: 1.35, y: 1.35), alpha: 1))
        }

        // Sprout: stem on the head, two leaves at its tip (follow-through comes from leafAngle).
        let fp = Int((p.fatigue * 100).rounded())
        let f = Double(fp) / 100
        let root = base.translatedBy(x: ox * 0.35, y: -m.radiusY * 0.94).rotated(by: p.leafAngle)
        out.append(Placement(slot: Slot.stem, part: .stem(f: fp, lw: lw), transform: root, alpha: 1))
        let len = 22 + f * 2
        let tip = CGPoint(x: f * 16, y: -len * (1 - f * 0.62))
        let flutter = sin(p.time * 3.1 + p.phase) * 0.06
        for (i, side) in [-1.0, 1.0].enumerated() {
            let angle = side * 0.85 * (1 - f) + f * (2.55 + side * 0.3) + flutter * (i == 1 ? -1 : 1) * (1 - f * 0.7)
            let t = root.translatedBy(x: tip.x, y: tip.y).rotated(by: angle + p.leafSpin).scaledBy(x: 1 - f * 0.3, y: 1 - f * 0.12)
            out.append(Placement(slot: Slot.leaf + i, part: .leaf(index: i, f: fp, lw: lw), transform: t, alpha: 1))
        }

        // Blush moves less than the eyes → parallax depth.
        for (i, s) in [-1.0, 1.0].enumerated() {
            let t = base.translatedBy(x: s * m.radiusX * 0.55 + ox * 0.55, y: m.radiusY * 0.14 + oy * 0.4)
            out.append(Placement(slot: Slot.blush + i, part: .blush, transform: t, alpha: 1))
            if p.blushHot > 0.01 {                          // petted: the cheeks glow (6c)
                out.append(Placement(slot: Slot.blushHot + i, part: .blushHot, transform: t, alpha: clamp(p.blushHot)))
            }
        }

        let mood = p.mood
        let ex = m.radiusX * 0.33, ey = -m.radiusY * 0.06
        // The eyes mirror (6a, decision 4): smaller eyes and lavender bags — only from the eyes need.
        let strain = p.eyeStrain
        let strainScale = 1 - strain * 0.25
        if strain > 0.02 {
            for (i, s) in [-1.0, 1.0].enumerated() {
                let t = base.translatedBy(x: s * ex + ox, y: ey + oy)
                out.append(Placement(slot: Slot.eyeBag + i, part: .eyeBag(lw: lw), transform: t, alpha: 0.35 + 0.65 * strain))
            }
        }
        for (i, s) in [-1.0, 1.0].enumerated() {
            let eye = base.translatedBy(x: s * ex + ox, y: ey + oy)
            let part: Part
            var t = eye
            if mood.dizzy {
                part = .eyeDizzy(lw: lw)
                t = eye.rotated(by: p.time * 7 * s)
            } else if mood.annoyed {
                part = .eyeAnnoyed(side: Int(s), lw: lw)
            } else if p.sleep > 0.5 {
                part = .eyeSleep(lw: lw)
            } else if mood.winking && i == 0 {
                part = .eyeHappy(lw: lw)                           // the wink after petting (6c)
            } else if (mood.deadpan || mood.sad || mood.slumped || mood.sulking) && p.eyeOpen < 0.14 {
                part = .eyeSleep(lw: lw)                           // a blink in a sad / stone mood is not a smile
            } else if mood.deadpan {
                part = .eyeLidded(lw: lw)                          // -_- (6c)
                t = eye.scaledBy(x: p.eyeScale * strainScale, y: p.eyeScale * strainScale)
            } else if p.eyeOpen < 0.14 || (mood.called && p.calledAge < 0.5) || mood.cheering || mood.chomping
                        || mood.laughing || mood.petted || mood.dancing {
                part = .eyeHappy(lw: lw)
            } else if mood.sad {
                part = .eyeOpen                                    // half-closed, looking down
                t = eye.translatedBy(x: 0, y: 2).scaledBy(x: strainScale, y: 0.5 * p.eyeOpen * strainScale)
            } else {
                part = .eyeOpen
                t = eye.scaledBy(x: 1 - abs(p.lookX) * 0.2, y: p.eyeOpen)
                    .scaledBy(x: p.eyeScale * strainScale, y: p.eyeScale * strainScale)
            }
            out.append(Placement(slot: Slot.eye + i, part: part, transform: t, alpha: 1))
        }
        if p.props.contains(.sunglasses) {                    // 6f: over both eyes, following the look a little
            out.append(Placement(slot: Slot.sunglasses, part: .sunglasses(lw: lw), transform: base.translatedBy(x: ox * 0.7, y: ey + oy * 0.6), alpha: 1))
        }
        // Tears of laughter fly sideways from the outer corners of the eyes (😂, 6c).
        if let age = p.tearAge {
            for (side, s) in [-1.0, 1.0].enumerated() {
                for j in 0..<Part.tearsPerEye {
                    let u = (age * 1.8 + Double(j) / Double(Part.tearsPerEye)).truncatingRemainder(dividingBy: 1)
                    let a = min(1, u / 0.12) * (1 - u) * clamp(age / 0.2)
                    guard a > 0.002 else { continue }
                    let t = base.translatedBy(x: s * (ex + 9 + 30 * u) + ox, y: ey + oy - 2 - 12 * u + 30 * u * u)
                        .rotated(by: s * (0.6 + u))
                    out.append(Placement(slot: Slot.tear + side * Part.tearsPerEye + j, part: .tear, transform: t, alpha: a))
                }
            }
        }

        let mouth = base.translatedBy(x: ox * 0.8, y: m.radiusY * 0.2 + oy * 0.6)
        var mouthT = mouth
        let mouthPart: Part
        if mood.dizzy {
            let cycle = (p.time * 10 / (2 * .pi)).truncatingRemainder(dividingBy: 1)
            mouthPart = .mouthWave(phase: Int(cycle * Double(Part.waveFrames)) % Part.waveFrames, lw: lw)
        } else if p.sleep > 0.5 || mood.carried {
            // little "o": snoring softly / "whoa!" when picked up
            let r = mood.carried ? 4.2 : 2.6 + sin(p.time * .pi * 2 / 5.2 + p.phase) * 0.6
            mouthT = mouth.translatedBy(x: 0, y: 1).scaledBy(x: r / 4.2, y: r / 4.2).translatedBy(x: 0, y: -1)
            mouthPart = .mouthO
        } else if mood.called || mood.yawning || mood.cheering || mood.chomping {
            mouthPart = .mouthOpen(yawn: mood.yawning)
        } else if mood.laughing {
            mouthT = mouth.translatedBy(x: 0, y: -1).scaledBy(x: 1.45, y: 1.5).translatedBy(x: 0, y: 1)
            mouthPart = .mouthOpen(yawn: false)                         // a big «D»
        } else if mood.chewing {
            let r = 0.55 + 0.35 * abs(sin(p.time * 11))                // nom-nom
            mouthT = mouth.translatedBy(x: 0, y: 1).scaledBy(x: 0.8, y: r).translatedBy(x: 0, y: -1)
            mouthPart = .mouthO
        } else if mood.focused || mood.deadpan {
            mouthPart = .mouthSmile(tired: 91, lw: lw)                  // a straight, busy line — not a smile
        } else if mood.annoyed || mood.sad || mood.slumped || mood.sulking {
            mouthPart = .mouthFrown(lw: lw)
        } else {
            mouthPart = .mouthSmile(tired: 0, lw: lw)                   // 6a: fatigue shows in the pose only
        }
        out.append(Placement(slot: Slot.mouth, part: mouthPart, transform: mouthT, alpha: 1))
        if p.clownNose > 0.01 {
            let s = easeOutBack(clamp(p.clownNose))
            out.append(Placement(slot: Slot.clownNose, part: .clownNose(lw: lw),
                                 transform: base.translatedBy(x: ox * 0.8, y: -m.radiusY * 0.06 + oy * 0.6).scaledBy(x: s, y: s),
                                 alpha: 1))
        }

        for (i, h) in p.hands.prefix(2).enumerated() {
            let t = base.translatedBy(x: h.x * m.radiusX, y: h.y * m.radiusY).rotated(by: h.angle)
            out.append(h.arm ? Placement(slot: Slot.arm + i, part: .arm(lw: lw), transform: t, alpha: 1)
                             : Placement(slot: Slot.hand + i, part: .hand(lw: lw), transform: t, alpha: 1))
        }
    }

    /// «Ликует»: a fan of confetti bursting up from his head, falling and fading (slice 6a).
    static func confettiPlacements(into out: inout [Placement], age: Double, origin o: CGPoint, mirror: CGAffineTransform) {
        let life = CharacterSim.confettiLife, gravity = 430.0
        let alpha = clamp((life - age) / 0.45)
        guard alpha > 0.002 else { return }
        for i in 0..<Part.confettiPieces {
            let angle = -Double.pi / 2 + (Double(i) - 3.5) * 0.3
            let speed = 150 + Double((i * 37) % 60)
            let x = Double(o.x) + cos(angle) * speed * age
            let y = Double(o.y) + sin(angle) * speed * age + 0.5 * gravity * age * age
            let spin = age * Double(6 + i) * (i % 2 == 0 ? 1 : -1)
            out.append(Placement(slot: Slot.confetti + i, part: .confetti(index: i),
                                 transform: mirror.translatedBy(x: x, y: y).rotated(by: spin), alpha: alpha))
        }
    }

    /// "z z z" drifting up from the sprout: offset + delay + fade (Zajno), each z a little bigger.
    static func zPlacements(into out: inout [Placement], pose p: CharacterPose, metrics m: Metrics,
                            mirror: CGAffineTransform, mirrored: Bool) {
        let fadeIn = clamp((p.sleep - 0.3) / 0.5)
        for i in 0..<3 {
            let k = (p.time * 0.32 + Double(i) / 3).truncatingRemainder(dividingBy: 1)   // 0 → 1 over ~3 s
            let alpha = fadeIn * min(1, k * 5) * (1 - k)
            guard alpha > 0.002 else { continue }
            let size = 0.7 + k * 0.6
            let x = p.x - 18 - k * 34 + sin(k * 7 + Double(i)) * 4
            let y = m.ground + p.hop - m.radiusY * 2 - 18 - k * 58
            var t = mirror.translatedBy(x: x, y: y)
            if mirrored { t = t.scaledBy(x: -1, y: 1) }   // letters must never read backwards
            t = t.scaledBy(x: size, y: size).rotated(by: -0.25)
            out.append(Placement(slot: Slot.z + i, part: .z, transform: t, alpha: alpha))
        }
    }

    /// «пф!» (6d): a little cloud bursts out of the screen edge where he vanished, into the screen, and fades.
    static func puffPlacements(into out: inout [Placement], age: Double, origin o: CGPoint, mirror: CGAffineTransform) {
        let u = clamp(age / CharacterSim.puffLife)
        let spread = 1 - (1 - u) * (1 - u)                        // fast out, then slow
        let angles = [Double.pi, .pi * 0.78, .pi * 1.22, .pi * 0.6, .pi * 1.4]
        for i in 0..<Part.puffs {
            let a = angles[i % angles.count]
            let d = (16 + Double(i % 3) * 6) * spread + 4
            let s = 0.55 + 0.6 * spread
            let alpha = 1 - u * u
            guard alpha > 0.002 else { continue }
            let t = mirror.translatedBy(x: Double(o.x) + cos(a) * d, y: Double(o.y) + sin(a) * d).scaledBy(x: s, y: s)
            out.append(Placement(slot: Slot.puff + i, part: .puff(index: i), transform: t, alpha: alpha))
        }
    }

    /// «ХА ХА ХА» (6c): one word after another slides out from behind the screen edge, up and into the screen.
    static func haPlacements(into out: inout [Placement], age: Double, count: Int, pose p: CharacterPose, metrics m: Metrics,
                             mirror: CGAffineTransform, mirrored: Bool) {
        let life = 1.3
        let width = TextKit.width("ХА", font: TextKit.haFont)
        let rows = [0.0, 18, 7, 25, 3, 14]
        for j in 0..<min(count, Part.haWords) {
            let a = age - Double(j) * 0.38
            guard a >= 0, a < life else { continue }
            let alpha = min(1, a / 0.12) * min(1, (life - a) / 0.35)
            guard alpha > 0.002 else { continue }
            let x = m.width - a * 110
            let y = m.ground - m.radiusY * 2 - 6 - rows[j % rows.count] - a * 30
            let scale = 0.85 + 0.25 * min(1, a * 5)
            var t = mirror.translatedBy(x: x, y: y)
            if mirrored { t = t.scaledBy(x: -1, y: 1).translatedBy(x: -width * scale, y: 0) }   // never backwards
            t = t.scaledBy(x: scale, y: scale).rotated(by: j % 2 == 0 ? -0.15 : 0.12)
            out.append(Placement(slot: Slot.ha + j, part: .ha, transform: t, alpha: alpha))
        }
    }

    /// Bubble pops out of him (scale from the tail, easeOutBack); words arrive one by one (offset & delay).
    static func bubblePlacements(into out: inout [Placement], pose p: CharacterPose, metrics m: Metrics,
                                 mirrored: Bool, text: String) {
        let appear = clamp((p.bubbleAge - 0.3) / 0.35)
        let vanish = clamp(p.bubbleRemaining / 0.3)
        let scale = min(easeOutBack(appear), 1.08) * vanish
        guard scale > 0 else { return }

        let layout = BubbleLayout.of(text, buttons: p.buttons, maxTextWidth: m.width - 20 - 28)
        let bw = layout.width, bh = layout.height
        // Above the body as it stands — or lies (6b: lower and wider, its centre further from the edge).
        let lie = Lying.frame(lying: p.lying, tilt: p.tilt, rx: m.radiusX, ry: m.radiusY, roll: p.roll)
        let turned = Lying.turned(lying: p.lying, roll: p.roll)
        let cx = p.x + (turned ? lie.dx : 0)
        let top = m.ground + p.hop - (turned ? 2 * lie.halfHeight : m.radiusY * 2)
        var bx = min(max(cx - bw - 14, 10), m.width - bw - 10)
        let by = min(max(top - (46 - 28 * p.lying) - bh, 10), m.height)   // above the sprout (lying: it points sideways)
        var tailX = min(cx - 22, bx + bw - 18)
        var dir = 1.0
        if mirrored { bx = m.width - bx - bw; tailX = m.width - tailX; dir = -1 }
        let tailY = by + bh

        let pop = CGAffineTransform(translationX: tailX, y: tailY).scaledBy(x: scale, y: scale).translatedBy(x: -tailX, y: -tailY)
        let a = clamp(scale)
        out.append(Placement(slot: Slot.bubbleBox, part: .bubbleBox(width: bw, height: bh), transform: pop.translatedBy(x: bx, y: by), alpha: a))
        out.append(Placement(slot: Slot.bubbleTail, part: .bubbleTail, transform: pop.translatedBy(x: tailX, y: tailY).scaledBy(x: dir, y: 1), alpha: a))
        out.append(Placement(slot: Slot.bubbleStroke, part: .bubbleStroke(width: bw, height: bh), transform: pop.translatedBy(x: bx, y: by), alpha: a))
        for (index, word) in layout.words.enumerated() {
            let wa = clamp((p.bubbleAge - 0.45 - Double(index) * 0.08) / 0.2)
            guard wa * a > 0.002 else { continue }
            let t = pop.translatedBy(x: bx + 14 + word.x, y: by + 24 + Double(word.row) * BubbleLayout.rowHeight + (1 - wa) * 6)
            out.append(Placement(slot: Slot.word + index, part: .word(word.text), transform: t, alpha: wa * a))
        }
        // Buttons arrive right after the words.
        for (i, b) in layout.buttons.enumerated() {
            let ba = clamp((p.bubbleAge - 0.5 - Double(layout.words.count) * 0.08 - Double(i) * 0.06) / 0.2)
            guard ba * a > 0.002 else { continue }
            let t = pop.translatedBy(x: bx + 14 + b.x, y: by + b.y + (1 - ba) * 4)
            out.append(Placement(slot: Slot.button + i, part: .button(title: b.title, hovered: p.hoveredButton == i), transform: t, alpha: ba * a))
        }
    }

    /// Where the bubble's buttons are this frame (scene coordinates, already mirrored) — for hit testing.
    /// Only buttons that have (almost) finished appearing are clickable.
    public static func buttonRects(pose: CharacterPose, metrics m: Metrics, mirrored: Bool) -> [(index: Int, rect: CGRect)] {
        guard let text = pose.bubble, !text.isEmpty, !pose.buttons.isEmpty else { return [] }
        var plan: [Placement] = []
        bubblePlacements(into: &plan, pose: pose, metrics: m, mirrored: mirrored, text: text)
        return plan.compactMap { pl in
            guard pl.alpha > 0.5, case .button(let title, _) = pl.part else { return nil }
            let rect = CGRect(x: 0, y: 0, width: Props.buttonWidth(title), height: Props.buttonHeight).applying(pl.transform)
            return (pl.slot - Slot.button, rect)
        }
    }

    // MARK: Vector rendering

    public static func drawScene(in ctx: CGContext, pose: CharacterPose, metrics m: Metrics, palette: Palette,
                                 mirrored: Bool = false) {
        draw(placements(pose: pose, metrics: m, mirrored: mirrored), in: ctx, metrics: m, palette: palette)
    }

    public static func draw(_ placements: [Placement], in ctx: CGContext, metrics m: Metrics, palette: Palette) {
        for p in placements.sorted(by: { $0.slot < $1.slot }) where p.alpha > 0 {
            ctx.saveGState()
            ctx.concatenate(p.transform)
            // A part fades as one piece, like its layer in the rig: overlapping fills inside it (the wig's puffs)
            // must not each get the alpha and darken where they overlap.
            if p.alpha < 1 { ctx.setAlpha(p.alpha); ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
            p.part.draw(in: ctx, metrics: m, palette: palette)
            if p.alpha < 1 { ctx.endTransparencyLayer() }
            ctx.restoreGState()
        }
    }

    /// Draws a macOS-style icon tile filling `rect` with Чилк inside. Outlines are thickened at tiny sizes.
    public static func drawIcon(in ctx: CGContext, rect: CGRect, pose: CharacterPose, metrics m: Metrics, palette: Palette) {
        let size = Double(rect.width)
        let tile = CGPath(roundedRect: rect, cornerWidth: size * 0.225, cornerHeight: size * 0.225, transform: nil)
        ctx.saveGState()
        ctx.addPath(tile)
        ctx.clip()
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [palette.iconTop.cgColor, palette.iconBottom.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        }
        let s = size / 150
        let base = CGAffineTransform(translationX: rect.midX, y: rect.minY + size * 0.6).scaledBy(x: s * pose.scaleX, y: s * pose.scaleY)
        var parts: [Placement] = []
        figurePlacements(into: &parts, pose: pose, metrics: m, lineScale: (max(1, 1.5 / (3.6 * s)) * 100).rounded() / 100, base: base)
        draw(parts, in: ctx, metrics: m, palette: palette)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(tile)
        ctx.setStrokeColor(RGBA(0, 0, 0, 0.1).cgColor)
        ctx.setLineWidth(max(0.8, size / 160))
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Чилк alone, no tile, in `rect` (y-down): the sticker portrait of the main window («Сегодня», slice 5c).
    public static func drawPortrait(in ctx: CGContext, rect: CGRect, pose: CharacterPose, metrics m: Metrics, palette: Palette) {
        let size = Double(min(rect.width, rect.height))
        let s = size / 160
        let base = CGAffineTransform(translationX: rect.midX, y: rect.minY + size * 0.58).scaledBy(x: s * pose.scaleX, y: s * pose.scaleY)
        var parts: [Placement] = []
        figurePlacements(into: &parts, pose: pose, metrics: m, lineScale: (max(1, 1.5 / (3.6 * s)) * 100).rounded() / 100, base: base)
        draw(parts, in: ctx, metrics: m, palette: palette)
    }

    // MARK: Helpers

    static func fillEllipse(_ ctx: CGContext, center: CGPoint, rx: Double, ry: Double, rotation: Double, color: RGBA) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
        ctx.restoreGState()
    }

    static func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, x)) }

    static func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
}
