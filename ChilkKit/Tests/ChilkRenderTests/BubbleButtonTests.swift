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
            let rects = ChilkRenderer.buttonRects(pose: talkingPose(), metrics: m, mirrored: mirrored)
            #expect(rects.map(\.index) == [0, 1, 2])
            let scene = CGRect(origin: .zero, size: m.sceneSize)
            #expect(rects.allSatisfy { scene.contains($0.rect) })
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
        #expect(rects.allSatisfy { CGRect(origin: .zero, size: m.sceneSize).contains($0.rect) })
    }
}
