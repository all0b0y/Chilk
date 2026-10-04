import Foundation

/// Talks to `codex app-server` over stdio (spike 002): requests with ids, notifications, and server-side
/// requests (approvals) which Чилк declines until his own skills arrive.
public actor CodexClient {
    public enum ClientError: Error, Equatable, CustomStringConvertible {
        case notStarted
        case cannotLaunch(String)
        case exited
        case rpc(code: Int, message: String)
        case turnFailed(String)

        public var description: String {
            switch self {
            case .notStarted: "codex app-server is not running"
            case .cannotLaunch(let why): "cannot launch codex: \(why)"
            case .exited: "codex app-server exited"
            case .rpc(let code, let message): "rpc error \(code): \(message)"
            case .turnFailed(let message): "turn failed: \(message)"
            }
        }
    }

    private struct Turn {
        var text = ""
        var lastItem: String?
        let onDelta: @Sendable (String) -> Void
        let continuation: CheckedContinuation<String, Error>
    }

    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let workDir: URL
    private var process: Process?
    private var input: FileHandle?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var turns: [String: Turn] = [:]
    private var observers: [String: [@Sendable (JSON) -> Void]] = [:]
    /// Server requests answered with «decline» (approvals, tool calls) — for tests and logs.
    public private(set) var declined: [String] = []

    public init(executable: URL, arguments: [String] = ["app-server"], environment: [String: String], workDir: URL) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workDir = workDir
    }

    public var isRunning: Bool { process?.isRunning ?? false }

    /// Launches the server and performs the `initialize` handshake.
    public func start(clientName: String = "chilk", version: String = "0.3") async throws {
        guard process == nil else { return }
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        p.environment = environment
        p.currentDirectoryURL = workDir
        let toServer = Pipe(), fromServer = Pipe()
        p.standardInput = toServer
        p.standardOutput = fromServer
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in Task { await self?.exited() } }
        do { try p.run() } catch { throw ClientError.cannotLaunch(error.localizedDescription) }
        process = p
        input = toServer.fileHandleForWriting
        let output = fromServer.fileHandleForReading
        Task.detached { [weak self] in
            do {
                for try await line in output.bytes.lines { await self?.receive(line) }
            } catch {}
            await self?.exited()
        }
        _ = try await request("initialize", ["clientInfo": ["name": .string(clientName), "version": .string(version)]])
        try send(["jsonrpc": "2.0", "method": "initialized", "params": [:]])
    }

    public func stop() {
        process?.terminate()
        exited()
    }

    public func request(_ method: String, _ params: JSON = [:]) async throws -> JSON {
        guard process != nil else { throw ClientError.notStarted }
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { c in
            pending[id] = c
            do {
                try send(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
            } catch {
                pending[id] = nil
                c.resume(throwing: error)
            }
        }
    }

    /// Called with the params of every notification `method` (e.g. `account/login/completed`).
    public func observe(_ method: String, _ handler: @escaping @Sendable (JSON) -> Void) {
        observers[method, default: []].append(handler)
    }

    /// Starts a turn on `threadId` and streams the assistant's text (the whole text so far) until it completes.
    public func ask(threadId: String, text: String, effort: String = "low", outputSchema: JSON? = nil,
                    onDelta: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            turns[threadId] = Turn(onDelta: onDelta, continuation: c)
            var params: JSON = ["threadId": .string(threadId), "effort": .string(effort),
                                "input": [["type": "text", "text": .string(text)]]]
            if let outputSchema, case .object(var o) = params {
                o["outputSchema"] = outputSchema
                params = .object(o)
            }
            Task {
                do { _ = try await self.request("turn/start", params) } catch { self.failTurn(threadId, error) }
            }
        }
    }

    public func interrupt(threadId: String) async {
        _ = try? await request("turn/interrupt", ["threadId": .string(threadId)])
    }

    // MARK: Wire

    private func send(_ message: JSON) throws {
        guard let input else { throw ClientError.notStarted }
        try input.write(contentsOf: Data((message.serialized() + "\n").utf8))
    }

    private func receive(_ line: String) {
        guard let message = JSON.parse(line) else { return }
        let method = message["method"]?.string
        if let id = message["id"], method == nil {                       // a response to us
            guard let n = id.int, let c = pending.removeValue(forKey: n) else { return }
            if let error = message["error"] {
                c.resume(throwing: ClientError.rpc(code: error["code"]?.int ?? 0, message: error["message"]?.string ?? ""))
            } else {
                c.resume(returning: message["result"] ?? .null)
            }
            return
        }
        guard let method else { return }
        if let id = message["id"] {                                       // the server asks us (approvals, tools)
            declined.append(method)
            try? send(["jsonrpc": "2.0", "id": id, "result": ["decision": "decline"]])
            return
        }
        let params = message["params"] ?? .null
        switch method {
        case "item/agentMessage/delta":
            if let thread = params["threadId"]?.string, var turn = turns[thread] {
                let item = params["itemId"]?.string
                if let last = turn.lastItem, let item, item != last, !turn.text.isEmpty { turn.text += "\n" }
                turn.lastItem = item ?? turn.lastItem
                turn.text += params["delta"]?.string ?? ""
                turns[thread] = turn
                turn.onDelta(turn.text)
            }
        case "turn/completed":
            if let thread = params["threadId"]?.string, let turn = turns.removeValue(forKey: thread) {
                if params["turn"]?["status"]?.string == "failed" {
                    turn.continuation.resume(throwing: ClientError.turnFailed(params["turn"]?["error"]?["message"]?.string ?? "failed"))
                } else {
                    turn.continuation.resume(returning: turn.text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        case "error":
            if params["willRetry"]?.bool != true, let thread = params["threadId"]?.string {
                failTurn(thread, ClientError.turnFailed(params["error"]?["message"]?.string ?? "error"))
            }
        default:
            break
        }
        for observer in observers[method] ?? [] { observer(params) }
    }

    private func failTurn(_ thread: String, _ error: Error) {
        turns.removeValue(forKey: thread)?.continuation.resume(throwing: error)
    }

    private func exited() {
        guard process != nil || !pending.isEmpty || !turns.isEmpty else { return }
        process = nil
        input = nil
        for c in pending.values { c.resume(throwing: ClientError.exited) }
        pending.removeAll()
        for t in turns.values { t.continuation.resume(throwing: ClientError.exited) }
        turns.removeAll()
    }
}
