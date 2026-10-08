import ChilkCore
import Foundation
import Testing
@testable import ChilkBrain

/// Slice 8e (SPEC «Срез 8», decisions 3–7, 11): events in Chilk's own «Чилк» calendar — read without a card, written
/// only from a confirmed card, only Chilk's own events.
@Suite("Apple Calendar tools")
struct ChilkCalendarTests {
    actor FakeStore: CalendarStore {
        var items: [EventInfo] = []
        var deny = false
        var log: [String] = []
        func setItems(_ value: [EventInfo]) { items = value }
        func setDeny(_ value: Bool) { deny = value }

        func add(title: String, start: Date, end: Date, allDay: Bool) async throws -> EventInfo {
            if deny { throw CalendarAccessError.denied }
            let info = EventInfo(id: "e\(items.count + 1)", title: title, start: start, end: end, allDay: allDay, recurring: false)
            items.append(info)
            log.append("add \(title)")
            return info
        }
        func events(from: Date, to: Date) async throws -> [EventInfo] {
            if deny { throw CalendarAccessError.denied }
            return items.filter { $0.end > from && $0.start < to }
        }
        func event(id: String) async throws -> EventInfo {
            if deny { throw CalendarAccessError.denied }
            guard let e = items.first(where: { $0.id == id }) else { throw CalendarAccessError.notFound }
            return e
        }
        func update(id: String, title: String?, start: Date?, end: Date?) async throws -> EventInfo {
            guard let i = items.firstIndex(where: { $0.id == id }) else { throw CalendarAccessError.notFound }
            guard !items[i].recurring else { throw CalendarAccessError.recurring }
            let e = items[i]
            items[i] = EventInfo(id: id, title: title ?? e.title, start: start ?? e.start, end: end ?? e.end, allDay: e.allDay,
                                 recurring: false)
            log.append("update \(id)")
            return items[i]
        }
        func delete(id: String) async throws {
            guard let i = items.firstIndex(where: { $0.id == id }) else { throw CalendarAccessError.notFound }
            guard !items[i].recurring else { throw CalendarAccessError.recurring }
            items.remove(at: i)
            log.append("delete \(id)")
        }
    }

    let now = Date(timeIntervalSince1970: 1_791_400_000)                  // 2026-10-07T21:46:40Z
    private func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "Europe/Moscow")
        return f.string(from: d)
    }

    @Test func anEventNeedsATitleAStartAndALengthOrAWholeDay() throws {
        let start = "2026-10-09T15:00:00+03:00"
        let at = ChilkToolCatalog.timestamp(start)!
        #expect(try ChilkToolCatalog.parse(name: "chilk_event", arguments: ["title": " Встреча с Сашей ", "at": .string(start),
                                                                            "minutes": 60, "all_day": false])
                == .event(title: "Встреча с Сашей", at: at, minutes: 60, allDay: false))
        #expect(try ChilkToolCatalog.parse(name: "chilk_event", arguments: ["title": "Дача", "at": "2026-10-10T00:00:00",
                                                                            "minutes": 0, "all_day": true])
                == .event(title: "Дача", at: ChilkToolCatalog.timestamp("2026-10-10T00:00:00")!, minutes: 0, allDay: true))
        let bad: [JSON] = [
            ["title": "Встреча", "at": .string(start), "minutes": 0, "all_day": false],          // a timed event needs a length
            ["title": "Встреча", "at": .string(start), "minutes": 1440, "all_day": false],       // at most 23 h 59 min
            ["title": "Встреча", "at": .string(start), "minutes": .number(1.5), "all_day": false],
            ["title": "  ", "at": .string(start), "minutes": 60, "all_day": false],
            ["title": "Встреча", "at": "в пятницу", "minutes": 60, "all_day": false],
            ["title": "Встреча", "at": .string(start), "minutes": 60],
            ["title": "Встреча", "at": .string(start), "minutes": 60, "all_day": false, "calendar": "Работа"],
        ]
        for args in bad {
            #expect(throws: ChilkToolCatalog.ToolError.self) { try ChilkToolCatalog.parse(name: "chilk_event", arguments: args) }
        }
    }

    @Test func aWholeDayMayComeAsJustADate() throws {
        let day = try ChilkToolCatalog.parse(name: "chilk_event", arguments: ["title": "Дача", "at": "2026-10-10", "minutes": 0,
                                                                              "all_day": true])
        guard case .event(_, let at, _, true) = day else { Issue.record("Expected an all-day event"); return }
        #expect(at == ChilkToolCatalog.timestamp("2026-10-10T00:00:00"))
        let timed: JSON = ["title": "Дача", "at": "2026-10-10", "minutes": 60, "all_day": false]
        #expect(throws: ChilkToolCatalog.ToolError.self) { try ChilkToolCatalog.parse(name: "chilk_event", arguments: timed) }
        #expect(ChilkToolCatalog.explain(name: "chilk_event", arguments: timed).hasPrefix("invalid_arguments: at"))
    }

    /// A move may name just the day (the host keeps the time of day, or moves a whole-day event by days).
    @Test func aMoveMayNameJustTheDay() throws {
        let move = try ChilkToolCatalog.parse(name: "chilk_event_change", arguments: ["id": "e1", "action": "move", "at": "2026-10-11",
                                                                                       "title": "", "minutes": 0])
        guard case .eventChange("e1", .move(let at, nil)) = move else { Issue.record("Expected a move"); return }
        #expect(at == ChilkToolCatalog.timestamp("2026-10-11T00:00:00"))
    }

    @Test func theListTakesARangeOfAtMostAYear() throws {
        let from = "2026-10-08T00:00:00+03:00", to = "2026-10-15T00:00:00+03:00"
        #expect(try ChilkToolCatalog.parse(name: "chilk_events", arguments: ["from": .string(from), "to": .string(to)])
                == .events(from: ChilkToolCatalog.timestamp(from)!, to: ChilkToolCatalog.timestamp(to)!))
        for args: JSON in [["from": .string(to), "to": .string(from)], ["from": .string(from), "to": "2027-10-10T00:00:00+03:00"],
                           ["from": .string(from)], [:]] {
            #expect(throws: ChilkToolCatalog.ToolError.self) { try ChilkToolCatalog.parse(name: "chilk_events", arguments: args) }
        }
    }

    @Test func changesGoByIdWithOnlyTheFieldsTheActionNeeds() throws {
        let at = "2026-10-09T16:00:00+03:00"
        func parse(_ action: String, _ at: String, _ title: String, _ minutes: Double) throws -> ChilkAction {
            try ChilkToolCatalog.parse(name: "chilk_event_change", arguments: ["id": "e1", "action": .string(action), "at": .string(at),
                                                                               "title": .string(title), "minutes": .number(minutes)])
        }
        let d = ChilkToolCatalog.timestamp(at)!
        #expect(try parse("move", at, "", 0) == .eventChange(id: "e1", change: .move(d, minutes: nil)))
        #expect(try parse("move", at, "", 90) == .eventChange(id: "e1", change: .move(d, minutes: 90)))
        #expect(try parse("rename", "", " Созвон ", 0) == .eventChange(id: "e1", change: .rename("Созвон")))
        #expect(try parse("move_rename", at, "Созвон", 30) == .eventChange(id: "e1", change: .moveRename(d, minutes: 30, "Созвон")))
        #expect(try parse("delete", "", "", 0) == .eventChange(id: "e1", change: .delete))
        #expect(throws: ChilkToolCatalog.ToolError.self) { try parse("move", "", "", 0) }
        #expect(throws: ChilkToolCatalog.ToolError.self) { try parse("rename", "", "", 0) }
        #expect(throws: ChilkToolCatalog.ToolError.self) { try parse("move", at, "", 1440) }
        #expect(throws: ChilkToolCatalog.ToolError.self) { try parse("done", "", "", 0) }
    }

    /// Decision 13: which field is wrong, not «invalid arguments».
    @Test func theModelIsToldWhichFieldIsWrong() {
        let start = "2026-10-09T15:00:00+03:00"
        #expect(ChilkToolCatalog.explain(name: "chilk_event", arguments: ["title": "Встреча", "at": .string(start), "minutes": 0,
                                                                          "all_day": false]).hasPrefix("invalid_arguments: minutes"))
        #expect(ChilkToolCatalog.explain(name: "chilk_events", arguments: ["from": "2026-10-15T00:00:00", "to": "2026-10-08T00:00:00"])
                    .hasPrefix("invalid_arguments: to"))
        #expect(ChilkToolCatalog.explain(name: "chilk_event_change", arguments: ["id": "e1", "action": "move", "at": "",
                                                                                 "title": "", "minutes": 0]).hasPrefix("invalid_arguments: at"))
        #expect(ChilkToolCatalog.explain(name: "chilk_event_change", arguments: ["id": "e1", "action": "rename", "at": "",
                                                                                 "title": "", "minutes": 0]).hasPrefix("invalid_arguments: title"))
    }

    /// Nothing is written on a tool call — only `create` / `change` / `delete` after the card's «Да».
    @Test func writingHappensOnlyAfterTheCard() async {
        let store = FakeStore()
        let e = ChilkCalendarExecutor(store: store)
        #expect(ChilkCalendarExecutor.proposes("chilk_event") && ChilkCalendarExecutor.proposes("chilk_event_change"))
        #expect(ChilkCalendarExecutor.handles("chilk_events") && !ChilkCalendarExecutor.handles("chilk_event"))
        let proposal = await e.execute(name: "chilk_event", arguments: ["title": "Встреча", "at": "2026-10-09T15:00:00+03:00",
                                                                        "minutes": 60, "all_day": false])
        #expect(!proposal.success)
        #expect(await store.log.isEmpty)
        let created = await e.create(title: "Встреча", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200), allDay: false)
        #expect(created.success && created.value["calendar"]?.string == "Чилк" && created.value["id"]?.string == "e1")
        #expect(await store.log == ["add Встреча"])
    }

    @Test func theListIsSortedByStartBoundedAndSaysWhatRepeats() async {
        let store = FakeStore()
        await store.setItems((0..<60).map { i in
            EventInfo(id: "e\(i)", title: "№\(i)", start: now.addingTimeInterval(Double(60 - i) * 3600),
                      end: now.addingTimeInterval(Double(61 - i) * 3600), allDay: false, recurring: i == 59)
        })
        let e = ChilkCalendarExecutor(store: store)
        let result = await e.execute(name: "chilk_events", arguments: ["from": .string(iso(now)), "to": .string(iso(now.addingTimeInterval(30 * 86400)))])
        #expect(result.success)
        guard case .array(let items) = result.value["events"] else { Issue.record("Expected a list"); return }
        #expect(items.count == 50 && result.value["hasMore"]?.bool == true)
        #expect(items.first?["title"]?.string == "№59" && items.first?["recurring"]?.bool == true)
        #expect(items.first?["id"]?.string == "e59" && items.first?["start"]?.string != nil && items.first?["allDay"]?.bool == false)
        #expect(result.value["calendar"]?.string == "Чилк")
    }

    @Test func errorsSayWhatHappenedAndNothingIsChanged() async throws {
        let store = FakeStore()
        await store.setItems([EventInfo(id: "r1", title: "Планёрка", start: now, end: now.addingTimeInterval(1800), allDay: false,
                                        recurring: true)])
        let e = ChilkCalendarExecutor(store: store)
        let missing = await e.delete(id: "zz")
        #expect(missing.value["error"]?.string?.hasPrefix("not_found") == true)
        let repeating = await e.change(id: "r1", title: "Летучка", start: nil, end: nil)
        #expect(repeating.value["error"]?.string?.hasPrefix("recurring_event") == true)
        #expect(try await e.lookup(id: "r1").recurring)
        await #expect(throws: CalendarAccessError.self) { try await e.lookup(id: "zz") }
        await store.setDeny(true)
        let denied = await e.create(title: "Чай", start: now.addingTimeInterval(60), end: now.addingTimeInterval(120), allDay: false)
        #expect(denied.value["error"]?.string?.contains("Privacy & Security → Calendars") == true)
        let listDenied = await e.execute(name: "chilk_events", arguments: ["from": .string(iso(now)), "to": .string(iso(now.addingTimeInterval(86400)))])
        #expect(listDenied.value["error"]?.string?.hasPrefix("no_access") == true)
        #expect(await store.log.isEmpty)
    }

    @Test func calendarOffRemovesTheCalendarToolsAndRefusesThemOnLiveThreads() {
        var s = ToolSwitches()
        s.set(.calendar, on: false)
        let list = ChilkToolCatalog.tools(for: s).map(\.name)
        for gone in ["chilk_event", "chilk_events", "chilk_event_change"] { #expect(!list.contains(gone)) }
        #expect(list.contains("chilk_reminder"))
        #expect(ChilkToolCatalog.switchedOff(name: "chilk_events", arguments: [:], switches: s, kindOf: { _ in nil }) == .calendar)
        #expect(ChilkToolCatalog.switchedOff(name: "chilk_reminder", arguments: [:], switches: s, kindOf: { _ in nil }) == nil)
    }

    @Test func aFailedEventProposalIsAChipButAWaitingCardIsNot() {
        let args: JSON = ["title": "Встреча", "at": "2026-10-09T15:00:00+03:00", "minutes": 60, "all_day": false]
        #expect(ChatChips.chip(name: "chilk_event", arguments: args, result: .ok(["awaiting_confirmation": true])) == nil)
        let failed = ChatChips.chip(name: "chilk_event", arguments: args, result: .failure("time_passed: …"))
        #expect(failed?.kind == .event && failed?.failed == true && failed?.subject == "Встреча")
    }
}
