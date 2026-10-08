import Foundation
import Testing
@testable import ChilkCore

/// Slice 10 (SPEC «Срез 10», Б2/Б3, decisions 2, 3, 5, 8): the draft edited in «Лист дня», «уже в плане» kept fresh, and
/// what Codex hears about the user's edits and the card's end.
struct SliceTenPlanTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return c
    }()

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func theUsersEditInTheSheetChangesTheDraft() {
        var d = PlanDraft(day: at(9, 0), already: ["английский"])
        d.update([PlanItem(title: "ЕЭС"), PlanItem(title: "продуктовый менеджмент"), PlanItem(title: "ESG")])
        #expect(d.edit(1, to: nil)?.title == "продуктовый менеджмент")
        #expect(d.items.map(\.title) == ["ЕЭС", "ESG"])
        #expect(d.edit(0, to: PlanItem(title: "ЕЭС", time: PlanTime("10:00"))) == PlanItem(title: "ЕЭС"))
        #expect(d.items.first?.time == PlanTime("10:00"))
        #expect(d.edit(5, to: nil) == nil)
        #expect(d.card().map { if case .plan(_, let items, _) = $0.kind { items.count } else { -1 } } == 2)
    }

    /// Decision 8: «+» in the sheet (or the iPhone) wrote a thing of the draft — it is «уже в плане» now, not twice.
    @Test func whatReachedRemindersLeavesTheDraft() {
        var d = PlanDraft(day: at(9, 0), already: [])
        d.update([PlanItem(title: "Купить хлеб"), PlanItem(title: "зал", time: PlanTime("18:00"))])
        d.refresh(already: ["купить  хлеб", "английский"])
        #expect(d.already == ["купить  хлеб", "английский"])
        #expect(d.items.map(\.title) == ["зал"])
        d.update([PlanItem(title: "Английский"), PlanItem(title: "зал", time: PlanTime("18:00"))])
        #expect(d.items.map(\.title) == ["зал"])
    }

    @Test func theEditsSayWhatTheUserTookOutAndChanged() {
        var e = PlanEdits()
        #expect(e.isEmpty && e.text == nil)
        e.record(PlanItem(title: "продуктовый менеджмент"), nil)
        e.record(PlanItem(title: "созвон", time: PlanTime("11:00")), PlanItem(title: "созвон", time: PlanTime("12:00")))
        e.record(PlanItem(title: "хлеб"), PlanItem(title: "хлеб"))             // nothing changed — nothing said
        #expect(e.removed == ["продуктовый менеджмент"])
        #expect(e.text == "убрано пользователем — продуктовый менеджмент; изменено пользователем — 11:00 созвон → 12:00 созвон")
    }

    /// Decision 2 (Б2): after the card Codex knows what was written and what the user removed, with the rule.
    @Test func theOutcomeNamesTheWrittenTheFailedAndTheRemoved() {
        var e = PlanEdits()
        e.record(PlanItem(title: "продуктовый менеджмент"), nil)
        let text = PlanOutcome.written(day: at(9, 0), written: ["ЕЭС", "ESG"], failed: ["резюме"], edits: e,
                                       now: at(8, 18), calendar: cal)
        #expect(text.hasPrefix("итог карточки плана на пятницу, 9 октября (2026-10-09): записано — ЕЭС, ESG; не записалось — "
                               + "резюме; убрано пользователем — продуктовый менеджмент"))
        #expect(text.contains(PlanOutcome.rule))
        let plain = PlanOutcome.written(day: at(9, 0), written: ["ЕЭС"], failed: [], edits: PlanEdits(), now: at(8, 18),
                                        calendar: cal)
        #expect(!plain.contains(PlanOutcome.rule) && !plain.contains("не записалось"))
        #expect(PlanOutcome.declined(day: at(9, 0), now: at(8, 18), calendar: cal)
                == "карточку плана на пятницу, 9 октября (2026-10-09) пользователь отклонил — ничего не записано, черновика больше нет")
    }

    /// Review 10: a model turn in flight sends the list from before the user's ✕ — the edit wins.
    @Test func aTurnInFlightCannotUndoTheUsersEdit() {
        var e = PlanEdits()
        e.record(PlanItem(title: "продуктовый менеджмент"), nil)
        e.record(PlanItem(title: "созвон", time: PlanTime("11:00")), PlanItem(title: "созвон", time: PlanTime("12:00")))
        let model = [PlanItem(title: "ЕЭС"), PlanItem(title: "Продуктовый  менеджмент"),
                     PlanItem(title: "созвон", time: PlanTime("11:00")), PlanItem(title: "молоко")]
        #expect(e.applied(to: model) == [PlanItem(title: "ЕЭС"), PlanItem(title: "созвон", time: PlanTime("12:00")),
                                         PlanItem(title: "молоко")])
        var all = PlanEdits()
        all.append(e)
        #expect(all == e && all.removed == ["продуктовый менеджмент"])
    }
}
