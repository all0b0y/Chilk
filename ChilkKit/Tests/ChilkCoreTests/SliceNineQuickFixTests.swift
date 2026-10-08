import Foundation
import Testing
@testable import ChilkCore

// Slice 9a (SPEC «Срез 9», decisions 1 and 8): folded chips and the card's answer window.

struct ChipSummaryTests {
    @Test func noChipsOneChipAndAFoldedGroup() {
        #expect(ChipSummary([]) == .none)
        let one = ChatChip(kind: .webSearch)
        #expect(ChipSummary([one]) == .single(one))
        #expect(ChipSummary([one, ChatChip(kind: .remember)]) == .group(count: 2, failed: 0))
        let failed = ChatChip(kind: .note, failed: true)
        #expect(ChipSummary([one, failed, ChatChip(kind: .mode, subject: "strict")]) == .group(count: 3, failed: 1))
    }

    @Test func russianPluralForms() {
        let f = { (n: Int) in RussianPlural.form(n, "действие", "действия", "действий") }
        #expect(f(1) == "действие" && f(21) == "действие" && f(101) == "действие")
        #expect(f(2) == "действия" && f(3) == "действия" && f(4) == "действия" && f(22) == "действия")
        #expect(f(5) == "действий" && f(11) == "действий" && f(12) == "действий" && f(14) == "действий")
        #expect(f(0) == "действий" && f(20) == "действий" && f(111) == "действий" && f(25) == "действий")
    }
}

struct CardAnswerWindowTests {
    @Test func heListensAMinuteForTheCard() {
        #expect(Dialogue.cardAnswerWindow == 60)
        #expect(Dialogue.cardAnswerWindow > Dialogue.followUpWindow(mode: .question, replyLength: 0)!)
    }
}

struct NotebookThemeTests {
    @Test func theDarkSheetIsRememberedAndOldFilesStayLight() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("games-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var h = GameHistory()
        h.played(.checkers, at: Date(timeIntervalSince1970: 1_800_000_000))
        h.dark = true
        try h.save(to: url)
        #expect(GameHistory.load(from: url) == h)
        #expect(try JSONDecoder().decode(GameHistory.self, from: Data(#"{"lastPlayed":{}}"#.utf8)).dark == false)
    }
}
