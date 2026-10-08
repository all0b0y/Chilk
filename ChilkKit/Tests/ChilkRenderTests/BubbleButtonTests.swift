import ChilkCore
import ChilkRender
import CoreGraphics
import Testing

@Suite("Bubble buttons")
@MainActor
struct BubbleButtonTests {
    let m = Metrics.standard

    func talkingPose(mirrored: Bool = false, buttons: [String] = ["Попил", "Через 10 мин", "Я занят"]) -> CharacterPose {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 3))
        sim.standOut = .peek
        sim.say("Попей водички 💧", buttons: buttons)
        for _ in 0..<120 { sim.step(dt: 1.0 / 60, pointer: nil) }
        return sim.pose
    }

    @Test func everyButtonGetsAClickableRectInsideThePanel() {
        for mirrored in [false, true] {
            let pose = talkingPose()
            let rects = ChilkRenderer.buttonRects(pose: pose, metrics: m, mirrored: mirrored)
            #expect(rects.map(\.index) == [0, 1, 2])
            // Slice 10 (Б6): the bubble is beside him and may reach past the nominal scene — inside the panel's canvas.
            let panel = SceneViewport(metrics: m, placements: ChilkRenderer.placements(pose: pose, metrics: m, mirrored: mirrored)).rect
            #expect(rects.allSatisfy { panel.contains($0.rect) })
            for (a, b) in zip(rects, rects.dropFirst()) { #expect(!a.rect.intersects(b.rect)) }
            #expect(rects.allSatisfy { $0.rect.height > 20 && $0.rect.width > 40 })
        }
    }

    @Test func buttonsAreNotClickableBeforeTheyAppear() {
        let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 3))
        sim.say("Попей водички 💧", buttons: ["Попил"])
        sim.step(dt: 1.0 / 60, pointer: nil)
        #expect(ChilkRenderer.buttonRects(pose: sim.pose, metrics: m, mirrored: false).isEmpty)
    }

    @Test func manyButtonsWrapInsteadOfLeavingThePanel() {
        let pose = talkingPose(buttons: ["Давай гимнастику", "Через 10 мин", "Я занят", "Ещё кнопка"])
        let rects = ChilkRenderer.buttonRects(pose: pose, metrics: m, mirrored: false)
        #expect(rects.count == 4)
        #expect(Set(rects.map { $0.rect.minY.rounded() }).count >= 2)
        let panel = SceneViewport(metrics: m, placements: ChilkRenderer.placements(pose: pose, metrics: m, mirrored: false)).rect
        #expect(rects.allSatisfy { panel.contains($0.rect) })
    }

    /// Slice 10 (Б6): the bubble never covers him — beside him on the screen side at any height (a tall card included),
    /// on both edges, standing, peeking and hidden-lurking.
    @Test func theBubbleIsBesideHimNeverOverHim() {
        let tall = (1...10).map { "Строка номер \($0) карточки" }.joined(separator: "\n")
        for text in ["Звал?", "Попей водички 💧", tall, String(repeating: "длинный ответ ", count: 17)] {
            for mirrored in [false, true] {
                for out in [StandOut.peek, .out, .lurk] {
                    let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 3))
                    if out == .lurk { sim.hidden = true }
                    sim.standOut = out
                    sim.say(text, buttons: ["Да", "Нет"])
                    for _ in 0..<150 { sim.step(dt: 1.0 / 60, pointer: nil) }
                    let plan = ChilkRenderer.placements(pose: sim.pose, metrics: m, mirrored: mirrored)
                    guard let box = plan.first(where: { if case .bubbleBox = $0.part { true } else { false } }),
                          let body = plan.first(where: { $0.slot == Slot.body }) else { Issue.record("no bubble/body"); continue }
                    let b = box.part.bounds(metrics: m).applying(box.transform)
                    let him = body.part.bounds(metrics: m).applying(body.transform)
                    #expect(!b.intersects(him), "\(text.prefix(12)) mirrored=\(mirrored) \(out)")
                    #expect(mirrored ? b.minX > him.midX : b.maxX < him.midX)            // on the screen side
                }
            }
        }
    }

    /// Review 10c: and not over his arms, a mug, a hat or a backpack — cheering, waving, drinking, dancing, lying, in the
    /// centre; the tallest bubble included.
    @Test func theBubbleClearsHisArmsAndProps() {
        let tall = (1...10).map { "Строка номер \($0) карточки" }.joined(separator: "\n")
        let his: Set<Int> = [Slot.ear, Slot.ear + 1, Slot.arm, Slot.arm + 1, Slot.foot, Slot.foot + 1, Slot.backpack,
                             Slot.body, Slot.hat, Slot.stem, Slot.leaf, Slot.leaf + 1, Slot.hand, Slot.hand + 1, Slot.mug, Slot.ball]
        let setups: [(String, (CharacterSim) -> Void)] = [
            ("cheer", { $0.standOut = .peek; $0.perform(.cheer) }),
            ("wave", { $0.standOut = .out; $0.wear(.hat); $0.wear(.backpack); $0.perform(.wave) }),
            ("drink", { $0.standOut = .peek; $0.perform(.drink) }),
            ("dance", { $0.standOut = .center; $0.perform(.dance(seconds: 10)) }),
            ("lying", { $0.standOut = .peek; $0.slumped = true }),
        ]
        for (name, setup) in setups {
            for text in ["Ура!", tall] {
                for mirrored in [false, true] {
                    let sim = CharacterSim(metrics: m, rng: SeededRandom(seed: 5))
                    setup(sim)
                    sim.say(text, buttons: ["Да", "Нет"])
                    for frame in 0..<240 {
                        sim.step(dt: 1.0 / 60, pointer: nil)
                        guard frame >= 90, frame % 10 == 0 else { continue }
                        let plan = ChilkRenderer.placements(pose: sim.pose, metrics: m, mirrored: mirrored)
                        guard let box = plan.first(where: { if case .bubbleBox = $0.part { true } else { false } }) else { continue }
                        let b = box.part.bounds(metrics: m).applying(box.transform)
                        for part in plan where his.contains(part.slot) {
                            let r = part.part.bounds(metrics: m).applying(part.transform)
                            #expect(!b.intersects(r), "\(name) \(text.prefix(5)) mirrored=\(mirrored) frame=\(frame) slot=\(part.slot)")
                        }
                    }
                }
            }
        }
    }
}
