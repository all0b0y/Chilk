import Foundation
import Testing
@testable import ChilkBrain

@Suite("Codex client (fake app-server)")
struct CodexClientTests {
    static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("FakeAppServer.py")

    func client() -> CodexClient {
        CodexClient(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [Self.script.path],
                    environment: ProcessInfo.processInfo.environment, workDir: FileManager.default.temporaryDirectory)
    }

    final class Deltas: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func add(_ s: String) { lock.withLock { seen.append(s) } }
        var all: [String] { lock.withLock { seen } }
    }

    @Test func handshakeAccountThreadAndAStreamingTurn() async throws {
        let c = client()
        try await c.start()
        #expect(try await c.account() == CodexClient.Account(email: "me@example.com", plan: "pro"))
        let thread = try await c.startThread(model: "gpt-6-luna", instructions: "Ты — Чилк", cwd: FileManager.default.temporaryDirectory)
        #expect(thread == "t1")
        let deltas = Deltas()
        let answer = try await c.ask(threadId: thread, text: "Привет") { deltas.add($0) }
        #expect(answer == "Привет, я Чилк!\n[decline]")                     // a new item starts on a new line
        #expect(deltas.all == ["Привет, ", "Привет, я Чилк!", "Привет, я Чилк!\n[decline]"])
        #expect(await c.declined == ["item/commandExecution/requestApproval"])
        await c.stop()
    }

    @Test func aFailedTurnThrowsInsteadOfAnsweringSomethingElse() async throws {
        let c = client()
        try await c.start()
        await #expect(throws: CodexClient.ClientError.turnFailed("boom")) {
            _ = try await c.ask(threadId: "t1", text: "fail")
        }
        await c.stop()
    }

    @Test func unknownMethodsAreRPCErrors() async throws {
        let c = client()
        try await c.start()
        await #expect(throws: CodexClient.ClientError.rpc(code: -32601, message: "no such method")) {
            _ = try await c.request("nope")
        }
        await c.stop()
    }

    @Test func aDyingServerFailsWhatIsPending() async throws {
        let c = client()
        try await c.start()
        await #expect(throws: CodexClient.ClientError.exited) {
            _ = try await c.request("die")
        }
        #expect(await !c.isRunning)
    }

    @Test func loginReturnsTheBrowserURLAndReportsCompletion() async throws {
        let c = client()
        final class Done: @unchecked Sendable { var success: Bool? }
        let done = Done()
        await c.observe("account/login/completed") { done.success = $0["success"]?.bool }
        try await c.start()
        #expect(try await c.startLogin() == URL(string: "https://auth.example/start"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(done.success == true)
        await c.stop()
    }

    @Test func aMissingBinaryIsAClearError() async {
        let c = CodexClient(executable: URL(fileURLWithPath: "/nonexistent/codex"), environment: [:], workDir: FileManager.default.temporaryDirectory)
        await #expect(throws: CodexClient.ClientError.self) { try await c.start() }
    }

    @Test func setupIsolatesSkillsButKeepsTheRealHomeForCommands() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chilk-setup-\(UUID().uuidString)")
        let s = CodexSetup(dataDir: dir, executable: URL(fileURLWithPath: "/usr/bin/true"), realHome: "/Users/me")
        try s.prepare()
        let toml = try String(contentsOf: s.codexHome.appendingPathComponent("config.toml"), encoding: .utf8)
        #expect(toml.contains("model = \"gpt-6-luna\""))
        #expect(toml.contains("set = { HOME = \"/Users/me\" }"))
        #expect(s.environment["CODEX_HOME"] == s.codexHome.path)
        #expect(s.environment["HOME"] == s.isolatedHome.path)                // no ~/.agents skills leak in
        #expect(s.environment["PATH"]!.contains("/opt/homebrew/bin"))
        try? FileManager.default.removeItem(at: dir)
    }
}
