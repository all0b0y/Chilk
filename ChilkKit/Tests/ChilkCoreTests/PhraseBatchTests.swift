import ChilkCore
import Foundation
import Testing

/// Decision 2026-10-05: Codex writes a daily batch; the hand-written library stays as the fallback.
@Suite("Phrase batch")
struct PhraseBatchTests {
    @Test func aBatchKeepsShortPlainLinesPerNeedStepAndPeriod() throws {
        let message = """
        {"lines": {"water": {"polite": ["Глоток воды? 💧", "Глоток воды?", "**Вода** ждёт", "x", "Тут ссылка http://a.b ок"],
                             "insist": ["Ну попей уже, а?"]},
                   "stretch": {"polite": [], "insist": []}, "eyes": {"polite": [], "insist": []},
                   "walk": {"polite": [], "insist": []}, "endOfDay": {"polite": ["Закругляемся?\\nДа"], "insist": []}},
         "ideas": {"morning": ["выйди за кофе", "Идея: потянись у окна"], "day": [], "evening": [], "night": []}}
        """
        let batch = try #require(PhraseBatch.parse(message, day: "2026-10-05"))
        #expect(batch.lines(for: .water, stage: 1) == ["Глоток воды?", "Вода ждёт"])     // emoji/markdown gone, deduped
        #expect(batch.lines(for: .water, stage: 2) == ["Ну попей уже, а?"])
        #expect(batch.lines(for: .endOfDay, stage: 1).isEmpty)                           // multi-line dropped
        #expect(batch.ideas(hour: 8) == ["Идея: выйди за кофе", "Идея: потянись у окна"])
        #expect(batch.ideas(hour: 14).isEmpty)
    }

    @Test func nothingUsableIsNoBatch() {
        #expect(PhraseBatch.parse("не JSON", day: "2026-10-05") == nil)
        #expect(PhraseBatch.parse(#"{"lines": {}, "ideas": {}}"#, day: "2026-10-05") == nil)
    }

    @Test func atMostSixLinesPerSlotAndTheBatchSurvivesASaveAndLoad() throws {
        let many = (1...10).map { "\"Строка номер \($0)\"" }.joined(separator: ",")
        let batch = try #require(PhraseBatch.parse(#"{"lines": {"walk": {"polite": [\#(many)], "insist": []}}, "ideas": {}}"#, day: "d"))
        #expect(batch.lines(for: .walk, stage: 0).count == 6)
        let copy = try JSONDecoder().decode(PhraseBatch.self, from: JSONEncoder().encode(batch))
        #expect(copy == batch)
    }

    @Test func theSchemaAsksForEveryNeedAndPeriodOnly() throws {
        let schema = PhraseBatch.schema
        let lines = try #require((schema["properties"] as? [String: Any])?["lines"] as? [String: Any])
        #expect(Set(lines["required"] as? [String] ?? []) == Set(Need.allCases.map(\.rawValue)))
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(PhraseBatch.dayKey(Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian)).count == 10)
        #expect(PhraseBatch.period(hour: 4) == .night && PhraseBatch.period(hour: 22) == .evening)
    }
}
