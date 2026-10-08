import CoreGraphics
import Testing
@testable import ChilkCore

// Slice 9 (grilling 2026-10-08, decision 34): «удивление» and «смущение» — two more emotions, each with its own
// signature (slice 6, decision 1: one signal, one meaning).

@MainActor
struct SurpriseShyTests {
    let m = Metrics.standard

    func fresh(_ seed: UInt64 = 31) -> CharacterSim {
        let s = CharacterSim(metrics: m, rng: SeededRandom(seed: seed))
        for _ in 0..<60 { s.step(dt: 1.0 / 60, pointer: nil) }
        return s
    }

    /// Steps `seconds`, calling `every` with the act's time `k` after each frame.
    func run(_ sim: CharacterSim, seconds: Double, from k0: Double = 0, every: ((CharacterSim, Double) -> Void)? = nil) {
        for i in 1...Int(seconds * 60) {
            sim.step(dt: 1.0 / 60, pointer: nil)
            every?(sim, k0 + Double(i) / 60)
        }
    }

    /// Where a startle can begin: at home (docked), behind the edge while the popover or a game holds him (.away),
    /// hidden and peeking (.lurk).
    enum Start: CaseIterable { case docked, away, lurk }

    func placed(_ start: Start, seed: UInt64 = 31) -> CharacterSim {
        let sim = fresh(seed)
        switch start {
        case .docked: break
        case .away:
            sim.standOut = .away
            run(sim, seconds: 2)
        case .lurk:
            sim.hidden = true
            run(sim, seconds: 2)
            sim.standOut = .lurk
            run(sim, seconds: 1.2)
        }
        return sim
    }

    @Test func eachNewEmotionIsItsOwnSceneAndShowsItsSignatureForMostOfIt() {
        #expect(CharacterSim.emotionAct(.surprised, strong: false) == .startle)
        #expect(CharacterSim.emotionAct(.shy, strong: false) == .bashful)
        for e in [Emotion.surprised, .shy] {
            let sim = fresh()
            sim.emote(e, strong: false)
            let a = sim.act!
            #expect(a.isEmotion)
            // The scene really lasts its 2–3 s (the bubble with the words waits for it), not a frame less or more…
            var last = 0.0, signature = 0.0
            run(sim, seconds: 3.5) { s, k in
                if s.isEmoting { last = k }
                let p = s.pose
                let shows = e == .surprised ? p.mood.surprised || p.exclaimAge != nil : p.mood.shy && p.blushShy > 0.5
                if shows { signature += 1.0 / 60 }
            }
            #expect(abs(last + 1.0 / 60 - a.duration) < 0.02, "\(e): over at \(last) s, duration \(a.duration) s")
            #expect(a.duration >= 2 && a.duration <= 3, "\(e): \(a.duration) s")
            // …and is not an empty tail: its own face shows for most of it.
            #expect(signature > a.duration * 0.6, "\(e): signature for \(signature) s of \(a.duration) s")
        }
    }

    @Test func surpriseIsOneSharpJumpWithRoundEyesAndAnExclamationThenRest() {
        for seed: UInt64 in [31, 7, 1234] {
            let sim = fresh(seed)
            sim.emote(.surprised, strong: false)
            var takeOffs = 0, airFrames = 0, wasUp = false, peak = 0.0, takeOffX = 0.0
            var happy = false, armsUp = false, roundAt08 = false, exclaimSeen = false, wideAt08 = 0.0
            run(sim, seconds: 2.3) { s, k in
                let p = s.pose
                let up = p.hop < -10
                if up && !wasUp { takeOffs += 1; takeOffX = s.positionX }
                if up { airFrames += 1 }
                wasUp = up
                peak = min(peak, p.hop)
                if p.mood.cheering || p.mood.laughing || p.mood.focused || p.mood.petted { happy = true }
                // Arms fly out and DOWN — never up like the cheer's ＼(^o^)／ (±0.95 from vertical).
                if p.hands.contains(where: { $0.arm && abs($0.angle) < 1.6 }) { armsUp = true }
                if p.exclaimAge != nil { exclaimSeen = true }
                if abs(k - 0.8) < 0.01 {
                    roundAt08 = p.mood.surprised && p.eyeOpen == 1 && p.hands.count == 2
                    wideAt08 = p.eyeScale
                }
            }
            // One quick startled jump (the cheer jumps three times, the hop antic only bobs a few points).
            #expect(takeOffs == 1, "seed \(seed): \(takeOffs) jumps")
            #expect(peak < -22 && peak > -42, "seed \(seed): peak \(peak)")
            #expect(airFrames < 22, "seed \(seed): \(airFrames) frames in the air")
            // He jumps once he is out from behind the edge (the whole body with its border on screen), not half hidden.
            #expect(takeOffX + m.radiusX * 1.07 <= m.width, "seed \(seed): took off at x \(takeOffX)")
            #expect(roundAt08 && wideAt08 > 1.12, "seed \(seed): eyes at 0.8 s")
            #expect(exclaimSeen && !happy && !armsUp)
            run(sim, seconds: 0.3)
            let p = sim.pose
            #expect(sim.act == nil && !p.mood.surprised && p.exclaimAge == nil && p.hands.isEmpty)
            #expect(abs(p.hop) < 3)
        }
    }

    @Test func theJumpAndTheExclamationWaitUntilHeIsOutFromBehindTheEdge() {
        // Review 9e-art: tied to a clock (0.18 s) the jump and its «!» came half behind the edge when he started from
        // the popover (.away) or from hiding (.lurk). Now they come once he is out, wherever he started.
        for start in Start.allCases {
            let sim = placed(start)
            if start != .docked { #expect(sim.positionX > m.width, "\(start): starts behind the edge at \(sim.positionX)") }
            sim.emote(.surprised, strong: false)
            var takeOffs = 0, wasUp = false, firstExclaim: (k: Double, age: Double, x: Double)?
            var exclaimFrames = 0, exclaimBehind = 0, round = 0.0, blinked = false, roundBeforeJump = true
            run(sim, seconds: 2.3) { s, k in
                let p = s.pose
                let up = p.hop < -10
                if up && !wasUp { takeOffs += 1 }
                wasUp = up
                if let age = p.exclaimAge {
                    if firstExclaim == nil { firstExclaim = (k, age, s.positionX) }
                    exclaimFrames += 1
                    if s.positionX > m.peekX + CharacterSim.startleOutSlack + 1 { exclaimBehind += 1 }
                } else if firstExclaim == nil, !p.mood.surprised {
                    roundBeforeJump = false                                // ⊙ ⊙ from the first frame, before the jump
                }
                if p.mood.surprised { round += 1.0 / 60 }
                if let f = firstExclaim, k > f.k + CharacterSim.startleWide, p.eyeOpen < 0.3 { blinked = true }
            }
            guard let f = firstExclaim else { Issue.record("\(start): no «!»"); continue }
            #expect(takeOffs == 1, "\(start): \(takeOffs) jumps")
            #expect(f.x <= m.peekX + CharacterSim.startleOutSlack + 1, "\(start): «!» at x \(f.x)")
            #expect(exclaimBehind == 0, "\(start): \(exclaimBehind) frames of «!» behind the edge")
            #expect(f.k <= CharacterSim.startleJumpDeadline + 0.02, "\(start): jumped at \(f.k) s")
            #expect(f.age < 1.0 / 60 + 0.001, "\(start): the «!» counts from the jump, first age \(f.age)")
            // The «!» lives its 1.5 s from the jump; the eyes stay round until `startleWide` after it, then «ой».
            #expect(abs(Double(exclaimFrames) / 60 - CharacterSim.exclaimLife) < 0.05, "\(start)")
            #expect(abs(round - (f.k - 1.0 / 60 + CharacterSim.startleWide)) < 0.05, "\(start): round for \(round) s")
            #expect(roundBeforeJump && blinked, "\(start)")
            if start == .docked { #expect(f.k < 0.35, "from the dock he is out almost at once: \(f.k) s") }
        }
    }

    @Test func shyHidesHisEyesBehindTheMittensPeeksOnceAndSways() {
        for seed: UInt64 in [31, 7, 1234] {
            let sim = fresh(seed)
            sim.emote(.shy, strong: false)
            var covered = 0, peeks = 0, wasPeeking = false, blush = 0.0
            var tiltLo = 9.0, tiltHi = -9.0, jumped = false, happy = false, shy = 0
            run(sim, seconds: 2.7) { s, k in
                let p = s.pose
                if p.hop < -6 { jumped = true }
                if p.mood.cheering || p.mood.laughing || p.mood.petted || p.mood.dancing { happy = true }
                if p.mood.shy { shy += 1 }
                blush = max(blush, p.blushShy)
                if k > 0.4 && k < 2.2 { tiltLo = min(tiltLo, p.tilt); tiltHi = max(tiltHi, p.tilt) }
                // Each mitten on its eye (the renderer's eye centre, in body half-widths / half-heights).
                func onEye(_ i: Int) -> Bool {
                    guard p.hands.count == 2 else { return false }
                    let s = i == 0 ? -1.0 : 1.0, h = p.hands[i]
                    let ex = s * 0.33 + p.lookX * 0.14, ey = -0.06 + p.lookY * 0.12
                    return abs(h.x - ex) < 0.08 && abs(h.y - ey) < 0.12 && !h.arm
                }
                if onEye(0) && onEye(1) { covered += 1 }
                let peeking = p.shyPeek > 0.5 && p.hands.count == 2 && !onEye(0) && onEye(1)
                if peeking && !wasPeeking { peeks += 1 }
                wasPeeking = peeking
            }
            #expect(covered > 50, "seed \(seed): mittens over the eyes for \(covered) frames")
            #expect(peeks == 1, "seed \(seed): \(peeks) peeks")
            #expect(blush > 0.95)
            #expect(tiltHi - tiltLo > 0.12, "seed \(seed): sway \(tiltHi - tiltLo)")     // side to side
            #expect(!jumped && !happy && shy > 120)
            run(sim, seconds: 0.2)
            let p = sim.pose
            #expect(sim.act == nil && !p.mood.shy && p.blushShy == 0 && p.shyPeek == 0 && p.hands.isEmpty)
        }
    }

    @Test func bothComeOutFromBehindTheEdgeAndGoBack() {
        for e in [Emotion.surprised, .shy] {
            let sim = fresh()
            #expect(sim.positionX > m.peekX + 20)
            sim.emote(e, strong: false)
            run(sim, seconds: 1)
            #expect(sim.positionX <= m.peekX + 2, "\(e)")
            #expect(sim.isEmoting)
            run(sim, seconds: 3)
            #expect(sim.positionX > m.peekX + 20, "\(e)")
        }
    }

    @Test func noPettingOrAnticsWhileTheyPlay() {
        for e in [Emotion.surprised, .shy] {
            let sim = fresh()
            sim.emote(e, strong: false)
            for i in 0..<120 {                                     // strokes across him during the scene
                let c = sim.bodyCenter
                let d = ((i / 18) % 2 == 0 ? -1.0 : 1.0) * (Double(i % 18) / 18 - 0.5) * 40
                sim.step(dt: 1.0 / 60, pointer: CGPoint(x: Double(c.x) + d, y: Double(c.y)))
                #expect(!sim.pose.mood.petted && sim.currentAntic == nil, "\(e) frame \(i)")
            }
        }
    }

    /// The parts of a scene that must not outlive it.
    func leftovers(_ p: CharacterPose) -> [String] {
        var out: [String] = []
        if p.mood.surprised { out.append("round eyes") }
        if p.mood.shy { out.append("shy face") }
        if p.exclaimAge != nil { out.append("«!»") }
        if p.blushShy > 0 { out.append("shy blush") }
        if p.shyPeek > 0 { out.append("peek") }
        if p.hands.contains(where: { $0.paw }) { out.append("mittens") }
        if p.hands.contains(where: { $0.arm && abs($0.angle) > 1.6 }) { out.append("startled arms") }
        return out
    }

    @Test func interruptingEitherSceneLeavesNothingBehind() {
        // stopAct (a game, a stand-up), another act or emotion over it, and a conversation's stopAct + «Слушаю».
        let ways: [(String, (CharacterSim) -> Void)] = [
            ("stopAct", { $0.stopAct() }),
            ("another act", { $0.perform(.wave) }),
            ("another emotion", { $0.emote(.cheer, strong: false) }),
            ("conversation", { s in s.stopAct(); s.listening = true; s.updateBubble("Слушаю…") }),
        ]
        for e in [Emotion.surprised, .shy] {
            for at in [0.1, 0.4, 1.3] {                           // before the jump, mid-air, during the peek
                for (name, interrupt) in ways {
                    let sim = fresh()
                    sim.emote(e, strong: false)
                    run(sim, seconds: at)
                    interrupt(sim)
                    var stuck: [String] = [], hopUp = false
                    run(sim, seconds: 2.5) { s, k in
                        stuck += leftovers(s.pose)
                        if k > 0.5 && s.pose.hop < -12 && name != "another act" && name != "another emotion" { hopUp = true }
                    }
                    #expect(stuck.isEmpty, "\(e) at \(at) s, \(name): \(Set(stuck))")
                    #expect(!hopUp, "\(e) at \(at) s, \(name): still jumping")
                    #expect(sim.act == nil, "\(e) at \(at) s, \(name): \(String(describing: sim.act))")
                    #expect(sim.pose.eyeScale < 1.15, "\(e) at \(at) s, \(name): eyes \(sim.pose.eyeScale)")
                    // Started again, the startle still waits until he is out and jumps once.
                    if e == .surprised {
                        sim.stopAct()
                        sim.listening = false
                        sim.emote(.surprised, strong: false)
                        var jumps = 0, wasUp = false
                        run(sim, seconds: 2.3) { s, _ in
                            let up = s.pose.hop < -10
                            if up && !wasUp { jumps += 1 }
                            wasUp = up
                        }
                        #expect(jumps == 1, "\(name): \(jumps) jumps on the second startle")
                    }
                }
            }
        }
    }
}
