import ChilkCore
import Foundation
import Testing
@testable import ChilkBrain

/// Slice 9b (SPEC «Срез 9», decisions 9–12, 18): `chilk_plan` and the plan's reminders.
struct ChilkPlanToolTests {
    func item(_ title: String, _ time: String = "", guess: Bool = false) -> JSON {
        ["title": .string(title), "time": .string(time), "guess": .bool(guess)]
    }

    @Test func thePlanToolTakesTheWholeListWithAnOptionalDay() throws {
        let args: JSON = ["action": "collect", "day": "2026-10-09",
                          "items": [item(" созвон ", "11:00"), item("маме", "3:00", guess: true), item("купить хлеб")]]
        let day = ChilkToolCatalog.dateOnly("2026-10-09")!
        #expect(try ChilkToolCatalog.parse(name: "chilk_plan", arguments: args) == .plan(.collect, day: day, items: [
            PlanItem(title: "созвон", time: PlanTime(hour: 11, minute: 0)),
            PlanItem(title: "маме", time: PlanTime(hour: 3, minute: 0), guessed: true),
            PlanItem(title: "купить хлеб"),
        ]))
        #expect(try ChilkToolCatalog.parse(name: "chilk_plan", arguments: ["action": "finish", "day": "", "items": []])
                == .plan(.finish, day: nil, items: []))
        #expect(try ChilkToolCatalog.parse(name: "chilk_plan", arguments: ["action": "cancel", "day": "", "items": []])
                == .plan(.cancel, day: nil, items: []))
    }

    @Test func aBrokenPlanIsRefusedWithTheFieldToFix() {
        let cases: [(JSON, String)] = [
            (["action": "start", "day": "", "items": []], "invalid_arguments: action — must be one of \"collect\", \"finish\", \"cancel\""),
            (["action": "collect", "day": "завтра", "items": []],
             "invalid_arguments: day — a date like 2026-10-09, or empty when the user did not name a day"),
            (["action": "collect", "day": "", "items": [item("созвон", "11"), item("маме", "3pm")]],
             "invalid_arguments: items[0].time — HH:mm like 09:30, or empty when no time was said"),
            (["action": "collect", "day": "", "items": [["title": "созвон", "time": ""]]], "invalid_arguments: items[0].guess — missing"),
            (["action": "collect", "day": "", "items": [["title": "созвон", "time": "", "guess": false, "minutes": 30]]],
             "invalid_arguments: items[0].minutes — not a field; the fields: guess, time, title"),
            (["action": "collect", "day": "", "items": [item("  ")]],
             "invalid_arguments: items[0].title — the thing in a few words, 1–120 characters, one line"),
            (["action": "collect", "day": "", "items": .array((0..<31).map { item("дело \($0)") })],
             "invalid_arguments: items — at most 30 things in one plan"),
            (["action": "collect", "day": ""], "invalid_arguments: items — missing"),
        ]
        for (args, why) in cases {
            #expect(throws: ChilkToolCatalog.ToolError.self) { try ChilkToolCatalog.parse(name: "chilk_plan", arguments: args) }
            #expect(ChilkToolCatalog.explain(name: "chilk_plan", arguments: args) == why)
        }
    }

    @Test func thePlanNeedsTheRemindersSwitch() {
        var off = ToolSwitches()
        off.set(.reminders, on: false)
        #expect(!ChilkToolCatalog.tools(for: off).contains { $0.name == "chilk_plan" })
        #expect(ChilkToolCatalog.tools(for: ToolSwitches()).contains { $0.name == "chilk_plan" })
        #expect(ChilkToolCatalog.switchedOff(name: "chilk_plan", arguments: [:], switches: off, kindOf: { _ in nil }) == .reminders)
    }

    @Test func theItemsSchemaIsStrict() {
        let schema = ChilkToolCatalog.tools.first { $0.name == "chilk_plan" }!.inputSchema
        #expect(schema["required"] == ["action", "day", "items"])
        let items = schema["properties"]?["items"]?["items"]
        #expect(items?["additionalProperties"] == false)
        #expect(items?["required"] == ["guess", "time", "title"])
    }

    @Test func aThingWithoutATimeIsDescribedByItsDay() {
        let due = ChilkToolCatalog.dateOnly("2026-10-09")!
        let open = ChilkReminderExecutor.describe(ReminderInfo(title: "хлеб", due: due, id: "x", timed: false))
        #expect(open["day"] == "2026-10-09" && open["at"] == nil && open["done"] == nil)
        let done = ChilkReminderExecutor.describe(ReminderInfo(title: "созвон", due: due.addingTimeInterval(11 * 3600), id: "y", done: true))
        #expect(done["at"] != nil && done["day"] == nil && done["done"] == true)
        #expect(ReminderInfo(title: "без даты", due: nil, timed: true).timed == false)
    }

    @Test func planItemsAreWrittenWithOrWithoutATimeAndTicked() async throws {
        let store = ChilkReminderTests.FakeStore()
        let reminders = ChilkReminderExecutor(store: store)
        let due = ChilkToolCatalog.dateOnly("2026-10-09")!
        #expect(await reminders.create(title: "хлеб", due: due, timed: false).success)
        #expect(await store.added == [ReminderInfo(title: "хлеб", due: due, timed: false)])
        await store.setItems([ReminderInfo(title: "хлеб", due: due, id: "r1", timed: false),
                              ReminderInfo(title: "вчера", due: due.addingTimeInterval(-86400), id: "r0")])
        #expect(await reminders.setDone(id: "r1", done: false).success)
        #expect(await reminders.setDone(id: "r1", done: true).success)
        #expect(await store.changed == ["reopen r1", "complete r1"])
        #expect(try await reminders.day(due).map(\.id) == ["r1"])
        let gone = await reminders.setDone(id: "nope", done: true)
        #expect(!gone.success && gone.value["error"]?.string?.hasPrefix("not_found") == true)
    }
}
