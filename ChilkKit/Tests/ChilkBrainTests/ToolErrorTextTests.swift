import ChilkBrain
import Foundation
import Testing

/// Slice 8a (decision 13): a failed parse names the field and how to fix it.
struct ToolErrorTextTests {
    @Test func aTimeWithoutAZoneSaysHowToWriteIt() {
        let text = ChilkToolCatalog.explain(name: "chilk_reminder", arguments: ["at": "2026-10-09T10:00:00", "title": "Хлеб"])
        #expect(text == "invalid_arguments: at — needs an ISO-8601 time with a timezone offset, e.g. 2026-10-09T10:00:00+03:00")
    }

    @Test func emptyMissingExtraAndUnknownAreNamed() {
        #expect(ChilkToolCatalog.explain(name: "chilk_reminder", arguments: ["at": "2026-10-09T10:00:00+03:00", "title": " "])
                == "invalid_arguments: title — must not be empty")
        #expect(ChilkToolCatalog.explain(name: "chilk_reminder", arguments: ["title": "Хлеб"]) == "invalid_arguments: at — missing")
        #expect(ChilkToolCatalog.explain(name: "chilk_reminders", arguments: ["list": "Чилк"])
                .hasPrefix("invalid_arguments: list — not a field of chilk_reminders"))
        #expect(ChilkToolCatalog.explain(name: "chilk_fly", arguments: [:]) == "unknown_tool: chilk_fly")
        #expect(ChilkToolCatalog.explain(name: "chilk_game", arguments: ["game": "chess", "length": 0]).hasPrefix("invalid_arguments: game — must be one of"))
        #expect(ChilkToolCatalog.explain(name: "chilk_game", arguments: ["game": "any", "length": 9]) == "invalid_arguments: length — must be at most 6")
    }

    @Test func theExecutorsReturnIt() async {
        let r = await ChilkReminderExecutor(store: NoReminders()).execute(name: "chilk_reminder", arguments: ["title": "Хлеб"])
        #expect(!r.success && r.value["error"]?.string == "invalid_arguments: at — missing")
    }
}

private actor NoReminders: ReminderStore {
    func add(title: String, due: Date) async throws -> ReminderInfo { ReminderInfo(title: title, due: due) }
    func open() async throws -> [ReminderInfo] { [] }
}
