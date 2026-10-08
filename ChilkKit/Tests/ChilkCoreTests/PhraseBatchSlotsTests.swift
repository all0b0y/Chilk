import ChilkCore
import Foundation
import Testing

@Suite("The day's batch, wider (slice 9e, decision 32)")
struct PhraseBatchSlotsTests {
    @Test func eachSlotHasItsStep() {
        #expect(PhraseBatch.step(stage: 1, again: false) == .polite)
        #expect(PhraseBatch.step(stage: 2, again: false) == .insist)
        #expect(PhraseBatch.step(stage: 3, again: false) == .stage3)
        #expect(PhraseBatch.step(stage: 1, again: true) == .again)
    }

    @Test func theNewSlotsAreParsedAndAnOldBatchStillLoads() throws {
        let json = #"""
        {"lines": {"water": {"polite": ["Глоток воды, а?"], "insist": ["Ну попей уже, правда"], "again": ["Снова я, с водой"],
                   "stage3": ["Я гашу свет, пока ты не попьёшь"]}},
         "ideas": {}, "shush": [], "sleepWarning": ["Через час спать, закругляйся"], "noGames": ["Ночью не играю, спать"],
         "wishes": ["Пусть день будет лёгким"], "reactions": {"all": ["красота!"], "most": [], "some": [], "none": ["Бывает, ничего"]}}
        """#
        let b = try #require(PhraseBatch.parse(json, day: "2026-10-08"))
        #expect(b.lines[.water]?[.again] == ["Снова я, с водой"])
        #expect(b.lines[.water]?[.stage3]?.count == 1)
        #expect(b.sleepWarning.count == 1 && b.noGames.count == 1 && b.wishes.count == 1)
        #expect(b.reactions[.all] == ["красота!"] && b.reactions[.most] == nil)
        let old = try JSONDecoder().decode(PhraseBatch.self, from: Data(#"{"day": "2026-10-07", "lines": {}, "ideas": {}}"#.utf8))
        #expect(old.sleepWarning.isEmpty && old.reactions.isEmpty)
        let schema = PhraseBatch.schema
        #expect((schema["required"] as? [String])?.contains("reactions") == true)
    }

    @Test func noLineTwiceBeforeTheRoundIsOver() {
        var bag = LineBag()
        let pool = ["a", "b", "c"]
        var round = Set<String>()
        for _ in 0..<3 { round.insert(bag.next("water.polite", from: pool)!) }
        #expect(round == Set(pool))
        let lastOfRound = bag.next("x", from: ["only"])
        #expect(lastOfRound == "only")
        // across rounds the last line is not the first of the next one
        var b2 = LineBag()
        let first = b2.next("s", from: ["p", "q"], index: { _ in 0 })
        let second = b2.next("s", from: ["p", "q"], index: { _ in 0 })
        let third = b2.next("s", from: ["p", "q"], index: { _ in 0 })
        #expect(first != second && third != second)
        var empty = LineBag()
        let nothing = empty.next("e", from: [])
        #expect(nothing == nil)
    }
}
