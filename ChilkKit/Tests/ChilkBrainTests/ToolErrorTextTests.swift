import ChilkBrain
import Foundation
import Testing

/// Slice 8a (decision 13): a failed parse names the field and how to fix it.
struct ToolErrorTextTests {
    @Test func aTimeWithoutAZoneSaysHowToWriteIt() {
        let text = ChilkToolCatalog.explain(name: "chilk_reminder", arguments: ["at": "завтра в 10", "title": "Хлеб"])
        #expect(text == "invalid_arguments: at — needs an ISO-8601 time, e.g. 2026-10-09T10:00:00+03:00 (without an offset it is local time)")
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
        let r = await ChilkReminderExecutor(store: NoReminders()).execute(name: "chilk_reminders", arguments: ["title": "Хлеб"])
        #expect(!r.success && r.value["error"]?.string?.hasPrefix("invalid_arguments: title — not a field of chilk_reminders") == true)
    }
}

private actor NoReminders: ReminderStore {
    func add(title: String, due: Date, timed: Bool) async throws -> ReminderInfo { ReminderInfo(title: title, due: due, timed: timed) }
    func open() async throws -> [ReminderInfo] { [] }
    func update(id: String, title: String?, due: Date?, timed: Bool) async throws -> ReminderInfo { throw ReminderAccessError.notFound }
    func setDone(id: String, done: Bool) async throws { throw ReminderAccessError.notFound }
    func day(_ day: Date) async throws -> [ReminderInfo] { [] }
    func delete(id: String) async throws { throw ReminderAccessError.notFound }
}

/// Review 8a: lengths come from the schema, and a valid path is not reported.
struct ToolErrorTextLimitsTests {
    @Test func aLongButValidFieldIsNotTheCulprit() {
        let text = ChilkToolCatalog.explain(name: "chilk_schedule", arguments: [
            "at": "в десять", "title": "Созвон", "message": .string(String(repeating: "а", count: 150))])
        #expect(text.hasPrefix("invalid_arguments: at"))
        let long = ChilkToolCatalog.explain(name: "chilk_reminder", arguments: [
            "at": "2026-10-09T10:00:00+03:00", "title": .string(String(repeating: "а", count: 130))])
        #expect(long == "invalid_arguments: title — too long (at most 120 characters)")
    }

    @Test func folderPathsAreCheckedLikeTheTool() {
        #expect(ChilkToolCatalog.explain(name: "chilk_request_folder", arguments: ["path": "Документы/Работа", "reason": "договор"])
                == "invalid_arguments: path — a full folder path: absolute or starting with ~/, without . or .. parts")
        #expect(!ChilkToolCatalog.explain(name: "chilk_request_folder", arguments: ["path": "~/Документы", "reason": ""])
                .contains("path"))
    }
}
