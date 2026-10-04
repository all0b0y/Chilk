import Foundation
import Testing
@testable import ChilkBrain

@Suite("Codex client (fake app-server)")
struct CodexClientTests {
    static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("FakeAppServer.py")

    static var temporary: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHILK_TEST_TMP"] ?? ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
    }

    func client() -> CodexClient {
        CodexClient(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [Self.script.path],
                    environment: ProcessInfo.processInfo.environment, workDir: Self.temporary)
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
        let thread = try await c.startThread(model: "gpt-6-luna", instructions: "Ты — Чилк", cwd: Self.temporary)
        #expect(thread == "t1")
        let deltas = Deltas()
        let answer = try await c.ask(threadId: thread, text: "Привет") { deltas.add($0) }
        #expect(answer == "Привет, я Чилк!\n[decline]")                     // a new item starts on a new line
        #expect(deltas.all == ["Привет, ", "Привет, я Чилк!", "Привет, я Чилк!\n[decline]"])
        #expect(await c.declined == ["item/commandExecution/requestApproval"])
        await c.stop()
    }

    @Test func aRegisteredToolIsExecutedAndItsActualResultReachesTheModel() async throws {
        let c = client()
        try await c.start()
        let tool = CodexTool(name: "chilk_status", description: "Read Chilk state",
                             inputSchema: ["type": "object", "properties": [:], "additionalProperties": false])
        let thread = try await c.startThread(model: "gpt-6-luna", instructions: "Ты — Чилк",
                                             cwd: Self.temporary, tools: [tool]) { call in
            #expect(call.name == "chilk_status")
            #expect(call.arguments == [:])
            return .ok(["water": true])
        }
        let answer = try await c.ask(threadId: thread, text: "tool")
        #expect(answer == "{\"water\":true}")
        #expect(await c.declined.isEmpty)
        await c.stop()
    }

    @Test(arguments: ["tool wrong-turn", "tool unknown", "tool other-thread", "tool namespace"])
    func anInvalidToolRequestCannotPerformAnAction(text: String) async throws {
        let c = client()
        try await c.start()
        let seen = Deltas()
        let tool = CodexTool(name: "chilk_status", description: "state", inputSchema: [:])
        let t = try await c.startThread(model: "gpt-6-luna", instructions: "", cwd: Self.temporary,
                                        tools: [tool]) { _ in
            seen.add("executed")
            return .ok(["water": true])
        }
        let answer = try await c.ask(threadId: t, text: text)
        #expect(JSON.parse(answer)?["error"]?.string != nil)
        #expect(seen.all.isEmpty)
        await c.stop()
    }

    @Test func repeatedCallIDsDoNotExecuteAnActionTwice() async throws {
        let c = client()
        try await c.start()
        let seen = Deltas()
        let tool = CodexTool(name: "chilk_status", description: "state", inputSchema: [:])
        let t = try await c.startThread(model: "gpt-6-luna", instructions: "", cwd: Self.temporary,
                                        tools: [tool]) { _ in
            seen.add("executed")
            return .ok(["water": true])
        }
        #expect(try await c.ask(threadId: t, text: "tool twice") == "{\"water\":true}")
        #expect(seen.all.count == 1)
        await c.stop()
    }

    @Test func interruptCancelsAnActionBeforeItCanCommit() async throws {
        let c = client()
        try await c.start()
        let seen = Deltas()
        let tool = CodexTool(name: "chilk_status", description: "state", inputSchema: [:])
        let t = try await c.startThread(model: "gpt-6-luna", instructions: "", cwd: Self.temporary,
                                        tools: [tool]) { _ in
            seen.add("entered")
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return .failure("Cancelled") }
            seen.add("committed")
            return .ok(["water": true])
        }
        let asking = Task { try await c.ask(threadId: t, text: "tool interrupted") }
        for _ in 0..<100 {
            if !seen.all.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(seen.all == ["entered"])
        await c.interrupt(threadId: t)
        _ = try? await asking.value
        try await Task.sleep(for: .milliseconds(1100))
        #expect(seen.all == ["entered"])
        await c.stop()
    }

    @Test func aWarmupTurnCannotExecuteRegisteredTools() async throws {
        let c = client()
        try await c.start()
        let seen = Deltas()
        let tool = CodexTool(name: "chilk_status", description: "state", inputSchema: [:])
        let t = try await c.startThread(model: "gpt-6-luna", instructions: "", cwd: Self.temporary,
                                        tools: [tool]) { _ in
            seen.add("executed")
            return .ok(["water": true])
        }
        let answer = try await c.ask(threadId: t, text: "tool", allowTools: false)
        #expect(JSON.parse(answer)?["error"]?.string != nil)
        #expect(seen.all.isEmpty)
        await c.stop()
    }

    @Test func aSecondTurnCannotReplaceTheFirstTurnsContinuation() async throws {
        let c = client()
        try await c.start()
        let seen = Deltas()
        let tool = CodexTool(name: "chilk_status", description: "state", inputSchema: [:])
        let t = try await c.startThread(model: "gpt-6-luna", instructions: "", cwd: Self.temporary,
                                        tools: [tool]) { _ in
            seen.add("entered")
            try? await Task.sleep(for: .seconds(1))
            return .failure("Cancelled")
        }
        let first = Task { try await c.ask(threadId: t, text: "tool interrupted") }
        for _ in 0..<100 {
            if !seen.all.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await #expect(throws: CodexClient.ClientError.turnFailed("Thread already has an active turn")) {
            _ = try await c.ask(threadId: t, text: "fail")
        }
        await c.stop()
        first.cancel()
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
        let c = CodexClient(executable: URL(fileURLWithPath: "/nonexistent/codex"), environment: [:], workDir: Self.temporary)
        await #expect(throws: CodexClient.ClientError.self) { try await c.start() }
    }

    @Test func setupIsolatesSkillsButKeepsTheRealHomeForCommands() throws {
        let dir = Self.temporary.appendingPathComponent("chilk-setup-\(UUID().uuidString)")
        let s = CodexSetup(dataDir: dir, executable: URL(fileURLWithPath: "/usr/bin/true"), realHome: "/Users/me")
        try s.prepare()
        let toml = try String(contentsOf: s.codexHome.appendingPathComponent("config.toml"), encoding: .utf8)
        #expect(toml.contains("model = \"gpt-6-luna\""))
        #expect(toml.contains("set = { HOME = \"/Users/me\" }"))
        #expect(toml.contains("web_search = \"live\""))
        #expect(toml.contains("shell_tool = false"))
        #expect(toml.contains("unified_exec = false"))
        #expect(toml.contains("computer_use = false"))
        // Codex 0.160 routes every tool call (Chilk's dynamic tools included) through the code-mode host;
        // with it disabled, tool calls fail closed and Chilk can never perform an action.
        #expect(toml.contains("code_mode_host = true"))
        #expect(!toml.contains("code_mode_host = false"))
        // Built-ins Chilk must not expose (measured in the live tool list): goals, image generation,
        // and a sleep tool that could park a voice turn for hours.
        #expect(toml.contains("goals = false"))
        #expect(toml.contains("image_generation = false"))
        #expect(toml.contains("sleep_tool = false"))
        #expect(s.environment["CODEX_HOME"] == s.codexHome.path)
        #expect(s.environment["HOME"] == s.isolatedHome.path)                // no ~/.agents skills leak in
        #expect(s.environment["PATH"]!.contains("/opt/homebrew/bin"))
        try? FileManager.default.removeItem(at: dir)
    }
}
