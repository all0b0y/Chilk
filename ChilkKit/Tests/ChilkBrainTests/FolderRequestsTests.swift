import Foundation
import Testing
@testable import ChilkBrain

@MainActor
struct FolderRequestsTests {
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    let work = URL(fileURLWithPath: "/Users/test/Documents/Работа", isDirectory: true)

    func grant(_ url: URL) -> FolderGrant { FolderGrant(name: url.lastPathComponent, kind: .files, root: url) }

    @Test func yesSharesTheFolderAtOnce() async {
        var asked: [URL] = [], added: [URL] = []
        let outcome = await FolderRequests(home: home).run(path: "~/Documents/Работа", grants: [],
            check: { $0 }, ask: { asked.append($0); return true }, add: { added.append($0); return grant($0) })
        #expect(asked == [work] && added == [work])
        #expect(outcome == .granted(grant(work)))
        #expect(FolderRequests.result(outcome)["folder"]?.string == "Работа")
    }

    @Test func noIsRememberedAndNotAskedAgainUntilRestart() async {
        let requests = FolderRequests(home: home)
        var asks = 0
        for _ in 0..<2 {
            let outcome = await requests.run(path: "/Users/test/Documents/Работа", grants: [], check: { $0 },
                                             ask: { _ in asks += 1; return false }, add: { _ in Issue.record("Not added"); return grant(work) })
            #expect(outcome == .declined)
        }
        #expect(asks == 1)
        let fresh = await FolderRequests(home: home).run(path: "~/Documents/Работа", grants: [], check: { $0 },
                                                         ask: { _ in true }, add: { grant($0) })
        #expect(fresh == .granted(grant(work)))
    }

    @Test func noAnswerIsANoForNowButMayBeAskedAgain() async {
        let requests = FolderRequests(home: home)
        var asks = 0
        for _ in 0..<2 {
            #expect(await requests.run(path: "~/Documents/Работа", grants: [], check: { $0 },
                                       ask: { _ in asks += 1; return nil }, add: { grant($0) }) == .noAnswer)
        }
        #expect(asks == 2)
    }

    @Test func aForbiddenOrSharedFolderIsNeverAsked() async {
        struct Refused: Error {}
        let requests = FolderRequests(home: home)
        #expect(await requests.run(path: "~/Documents", grants: [], check: { _ in throw Refused() },
                                   ask: { _ in Issue.record("Asked"); return true }, add: { grant($0) }) == .notAllowed)
        #expect(await requests.run(path: "~/Documents/Работа", grants: [grant(work)], check: { $0 },
                                   ask: { _ in Issue.record("Asked"); return true }, add: { grant($0) }) == .already(grant(work)))
    }

    @Test func pathsResolveFromHome() {
        #expect(FolderRequests.resolve("~/Documents/Работа", home: home) == work)
        #expect(FolderRequests.resolve("/Volumes/Диск/Архив", home: home).path == "/Volumes/Диск/Архив")
    }

    /// The app routes every file tool, the request included, to the shared-folder host (regression: a request
    /// once fell through to the timer executor and failed).
    @Test func theRequestIsRoutedToTheFolderHost() {
        for name in ["chilk_find_files", "chilk_read_file", "chilk_list_folders", "chilk_request_folder"] {
            #expect(ChilkFileToolExecutor.handles(name))
        }
        #expect(!ChilkFileToolExecutor.handles("chilk_append_note"))
    }
}
