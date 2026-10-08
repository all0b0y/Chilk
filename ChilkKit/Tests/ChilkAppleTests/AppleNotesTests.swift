@testable import ChilkApple
import ChilkBrain
import Foundation
import Testing

/// Slice 8f (SPEC «Срез 8», decisions 10, 12): the Notes adapter. A fake runner stands in for `osascript` — no Notes, no
/// prompt, no real data; the script itself goes through `osacompile`, which neither starts Notes nor sends it anything
/// (it catches syntax, not a misspelt one-word property).
struct AppleNotesTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [[String]] = []
        var all: [[String]] { lock.withLock { seen } }
        func add(_ a: [String]) { lock.withLock { seen.append(a) } }
    }

    private func notes(_ reply: ClockShortcut.Run, calls: Calls = Calls(), name: String = #function) -> (AppleNotes, UserDefaults) {
        let suite = "dev.all0b0y.chilk.tests.notes.\(name.prefix(40))"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removeObject(forKey: AppleNotes.folderKey)
        defaults.removeObject(forKey: AppleNotes.automationKey)
        return (AppleNotes(suite: suite, runner: { args in calls.add(args); return reply }), defaults)
    }

    private static let US = "\u{1F}", RS = "\u{1E}"
    private static func row(_ id: String, _ title: String, _ text: String, locked: Bool = false, files: Bool = false) -> String {
        [id, title, locked ? "true" : "false", files ? "true" : "false", "2026-10-8-39780", text].joined(separator: US)
    }

    @Test func theScriptCompilesWithoutStartingNotes() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "chilk-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "notes.applescript")
        try AppleNotes.script.write(to: source, atomically: true, encoding: .utf8)
        let run = await ClockShortcut.run(executable: "/usr/bin/osacompile",
                                          ["-o", dir.appending(path: "notes.scpt").path, source.path], timeout: 30)
        #expect(run.status == 0, "\(run.error)")
    }

    @Test func theUsersTextTravelsOnlyAsArguments() async throws {
        let calls = Calls()
        let (n, _) = notes(.init(status: 0, output: "f1" + Self.RS + Self.row("n1", "Тест", "Тест\nx") + "\n", error: ""), calls: calls)
        let tricky = "\" & (do shell script \"echo hi\") & \""
        _ = try await n.add(title: tricky, text: "<b>a & b</b>")
        let args = try #require(calls.all.first)
        #expect(args.count == 5 && args[0] == "-e" && args[1] == AppleNotes.script && args[2] == "add" && args[3] == "")
        #expect(args[4] == "<div><h1>&quot; &amp; (do shell script &quot;echo hi&quot;) &amp; &quot;</h1></div><div>&lt;b&gt;a &amp; b&lt;/b&gt;</div>")
        #expect(!AppleNotes.script.contains("echo hi"))
    }

    @Test func aListIsReadAndTheFolderIsRemembered() async throws {
        let out = "folder-1" + Self.RS + Self.row("n1", "Покупки", "Покупки\nмолоко\nхлеб") + Self.RS
            + Self.row("n2", "Пароли", "", locked: true) + "\n"
        let calls = Calls()
        let (n, defaults) = notes(.init(status: 0, output: out, error: ""), calls: calls)
        let found = try await n.notes()
        #expect(found.map(\.id) == ["n1", "n2"] && found[0].title == "Покупки" && found[0].text == "молоко\nхлеб")
        #expect(found[1].locked && !found[0].locked && !found[0].attachments)
        #expect(found[0].modified == Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 11, minute: 3)))
        #expect(defaults.string(forKey: AppleNotes.folderKey) == "folder-1" && defaults.string(forKey: AppleNotes.automationKey) == "granted")
        _ = try await n.notes()
        #expect(calls.all.last?[3] == "folder-1")                  // the next call names the remembered folder
    }

    @Test func noFolderYetReadsAsEmptyAndRemembersNothing() async throws {
        let (n, defaults) = notes(.init(status: 0, output: "\n", error: ""))
        #expect(try await n.notes().isEmpty)
        #expect(defaults.string(forKey: AppleNotes.folderKey) == nil)
        await #expect(throws: NotesAccessError.notFound) { try await n.note(id: "n1") }
    }

    @Test func scriptErrorsBecomeNamedFailures() async {
        let cases: [(String, NotesAccessError)] = [("(-1743)", .denied), ("(1001)", .notFound), ("(-1728)", .notFound),
                                                   ("(1002)", .locked), ("(1003)", .unavailable), ("(1004)", .attachments)]
        for (tail, expected) in cases {
            let (n, _) = notes(.init(status: 1, output: "", error: "0:12: execution error: Notes got an error: x \(tail)\n"), name: tail)
            await #expect(throws: expected) { try await n.delete(id: "n1") }
        }
        let (n, defaults) = notes(.init(status: 1, output: "", error: "execution error: Not authorized to send Apple events to Notes. (-1743)\n"))
        await #expect(throws: NotesAccessError.denied) { try await n.notes() }
        #expect(defaults.string(forKey: AppleNotes.automationKey) == "denied")
        let (slow, _) = notes(.init(status: ClockShortcut.timedOut, output: "", error: "timeout"), name: "slow")
        await #expect(throws: (any Error).self) { try await slow.notes() }
    }

    @Test func theNoteBodyKeepsLinesAndEscapes() {
        #expect(AppleNotes.html(title: "Список", text: "a < b\n\nc")
                == "<div><h1>Список</h1></div><div>a &lt; b</div><div><br></div><div>c</div>")
        #expect(AppleNotes.html(title: "Только заголовок", text: "") == "<div><h1>Только заголовок</h1></div>")
    }

    /// Decision 12: the real process runner answers from a background queue; the adapter takes the answer there.
    @Test func theProcessAnswerOffTheMainThreadIsTaken() async throws {
        UserDefaults(suiteName: "dev.all0b0y.chilk.tests.notes.process")!.removeObject(forKey: AppleNotes.folderKey)
        let reply = "f9" + Self.RS + Self.row("n1", "Покупки", "Покупки\nсыр")
        let n = AppleNotes(suite: "dev.all0b0y.chilk.tests.notes.process", runner: { _ in
            await ClockShortcut.run(executable: "/usr/bin/printf", ["%s", reply], timeout: 10)
        })
        #expect(try await n.notes().first?.text == "сыр")
    }
}
