import ChilkCore
import ChilkRender
import CoreGraphics
import Testing

/// Slice 10 (SPEC «Срез 10», Б9, decision 18): the confirmation card is pinned over his bubble until it is answered —
/// beside him on the screen side, never over him or the bubble, its buttons apart from the bubble's.
@Suite("Pinned card")
@MainActor
struct PinnedCardTests {
    let m = Metrics.standard
    let card = "📝 Напоминание: Купить хлеб\nЗавтра (пт, 10 окт.), 10:00\n«Напоминания» → «Чилк»"
    let plan = (1...8).map { "Дело номер \($0) на завтра" }.joined(separator: "\n")
    let tallAnswer = String(repeating: "длинный ответ ", count: 17)

    func box(_ plan: [Placement], slot: Int) -> CGRect? {
        plan.first { $0.slot == slot }.map { $0.part.bounds(metrics: m).applying($0.transform) }
    }

    func sim(card: String, bubble: String?, out: StandOut = .out, setup: (CharacterSim) -> Void = { _ in }) -> CharacterSim {
        let s = CharacterSim(metrics: m, rng: SeededRandom(seed: 3))
        s.standOut = out
        setup(s)
        s.pinCard(card, buttons: ["Да", "Изменить", "Нет"])
        if let bubble { s.say(bubble, duration: .infinity, buttons: ["Подробнее"]) }
        for _ in 0..<150 { s.step(dt: 1.0 / 60, pointer: nil) }
        return s
    }

    @Test func theCardSitsOverTheBubbleBesideHimNeverOverEither() {
        for text in [card, plan] {
            for bubble in [nil, "Ой, засмущал.", tallAnswer] {
                for mirrored in [false, true] {
                    for out in [StandOut.peek, .out, .center] {
                        let s = sim(card: text, bubble: bubble, out: out)
                        let plan = ChilkRenderer.placements(pose: s.pose, metrics: m, mirrored: mirrored)
                        let name = "\(text.prefix(8)) bubble=\(bubble?.prefix(6) ?? "-") mirrored=\(mirrored) \(out)"
                        guard let c = box(plan, slot: Slot.cardBox), let him = box(plan, slot: Slot.body) else {
                            Issue.record("no card/body \(name)"); continue
                        }
                        #expect(!c.intersects(him), "\(name)")
                        #expect(mirrored ? c.minX > him.midX : c.maxX < him.midX, "\(name)")      // on the screen side
                        if let b = box(plan, slot: Slot.bubbleBox) {
                            #expect(c.maxY <= b.minY, "\(name)")                                 // over the bubble
                            #expect(abs((mirrored ? c.minX - b.minX : c.maxX - b.maxX)) < 1, "\(name)")   // one column
                        }
                        // The window's canvas holds all of it (it grows up past the scene's top).
                        let canvas = SceneViewport(metrics: m, placements: plan).rect
                        #expect(canvas.contains(c.insetBy(dx: 2, dy: 2)), "\(name)")
                    }
                }
            }
        }
    }

    @Test func aBubbleComingAndGoingDoesNotMoveTheCard() {
        let alone = sim(card: card, bubble: nil)
        let talking = sim(card: card, bubble: "Ой, засмущал.")
        let a = box(ChilkRenderer.placements(pose: alone.pose, metrics: m, mirrored: false), slot: Slot.cardBox)
        let b = box(ChilkRenderer.placements(pose: talking.pose, metrics: m, mirrored: false), slot: Slot.cardBox)
        #expect(a != nil && a == b)
    }

    @Test func itsButtonsHaveTheirOwnIndexes() {
        for mirrored in [false, true] {
            let s = sim(card: card, bubble: "Подумай")
            let rects = ChilkRenderer.buttonRects(pose: s.pose, metrics: m, mirrored: mirrored)
            #expect(rects.map(\.index).sorted() == [0, ChilkRenderer.cardButtonBase, ChilkRenderer.cardButtonBase + 1,
                                                     ChilkRenderer.cardButtonBase + 2])
            for (i, a) in rects.enumerated() {
                for b in rects.dropFirst(i + 1) { #expect(!a.rect.intersects(b.rect)) }
            }
        }
    }

    @Test func aHoveredCardButtonLightsOnlyOnTheCard() {
        let s = sim(card: card, bubble: "Подумай")
        s.hoveredButton = ChilkRenderer.cardButtonBase
        let plan = ChilkRenderer.placements(pose: s.pose, metrics: m, mirrored: false)
        let lit = plan.compactMap { p -> Int? in if case .button(_, let hovered) = p.part, hovered { p.slot } else { nil } }
        #expect(lit == [Slot.cardButton])
    }

    /// It keeps him out at his edge — hidden too, as the card did since 8c; answered, he goes back.
    @Test func aPinnedCardKeepsHimOutEvenHiddenAndHeGoesBackWhenItIsAnswered() {
        for hidden in [false, true] {
            let s = sim(card: card, bubble: nil, out: .docked) { $0.hidden = hidden }
            for _ in 0..<150 { s.step(dt: 1.0 / 60, pointer: nil) }
            #expect(s.isCardOnScreen && !s.isHiddenHome, "hidden=\(hidden)")
            #expect(abs(s.positionX - m.outX) < 6, "hidden=\(hidden) x=\(s.positionX)")
            s.unpinCard()
            for _ in 0..<240 { s.step(dt: 1.0 / 60, pointer: nil) }
            #expect(s.isHiddenHome == hidden && s.pose.card == nil, "hidden=\(hidden)")
            #expect(s.positionX > m.outX + 6, "hidden=\(hidden) x=\(s.positionX)")
        }
    }

    @Test func notWhileThePopoverHoldsHimAndItFadesWhenAnswered() {
        let away = sim(card: card, bubble: nil, out: .away)
        #expect(away.pose.card == nil && !away.isCardOnScreen)
        let s = sim(card: card, bubble: nil)
        #expect(s.pinnedCard == card)
        s.unpinCard()
        #expect(s.pinnedCard == nil)
        for _ in 0..<30 { s.step(dt: 1.0 / 60, pointer: nil) }
        #expect(s.pose.card == nil)
    }

    @Test func theSameCardAgainDoesNotPopANewOneDoes() {
        let s = sim(card: card, bubble: nil)
        let age = s.pose.cardAge
        s.pinCard(card, buttons: ["Изменить", "Нет"])               // time passed: «Да» went away
        s.step(dt: 1.0 / 60, pointer: nil)
        #expect(s.pose.cardAge > age)
        #expect(s.pose.cardButtons == ["Изменить", "Нет"])
        s.pinCard("📝 Напоминание: Купить батон", buttons: ["Да", "Нет"])
        s.step(dt: 1.0 / 60, pointer: nil)
        #expect(s.pose.cardAge < 0.1)
    }
}
