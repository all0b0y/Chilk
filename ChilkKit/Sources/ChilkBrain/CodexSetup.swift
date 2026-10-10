import ChilkCore
import Foundation

/// Чилк's own Codex profile (В4, spike 002): a separate CODEX_HOME inside the app's data, a fake HOME so the
/// user's ~/.agents skills do not leak in, while Codex's shell commands still see the real HOME.
public struct CodexSetup: Sendable {
    public var executable: URL
    public var codexHome: URL
    public var isolatedHome: URL
    public var workDir: URL
    public var realHome: String
    /// config.toml's defaults only: a conversation's model and depth come from Settings → «Мозг» per thread / turn
    /// (slice 9f), so a demo run with another choice never rewrites the shared profile.
    public var model = BrainChoice.defaultModel
    public var effort = BrainChoice.backgroundDepth.rawValue

    /// - Parameter dataDir: `~/Library/Application Support/Chilk`.
    public init(dataDir: URL, executable: URL, realHome: String = NSHomeDirectory()) {
        self.executable = executable
        self.codexHome = dataDir.appendingPathComponent("codex", isDirectory: true)
        self.isolatedHome = dataDir.appendingPathComponent("codex-home", isDirectory: true)
        self.workDir = dataDir.appendingPathComponent("workdir", isDirectory: true)
        self.realHome = realHome
    }

    public static var defaultDataDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chilk", isDirectory: true)
    }

    public var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = codexHome.path
        env["HOME"] = isolatedHome.path
        // Apps started from Finder get a minimal PATH; Codex's own commands need the usual tools. Codex's own folder
        // comes first: an npm-installed `codex` is a `#!/usr/bin/env node` script, and under nvm its Node sits beside it.
        let extra = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                     "\(realHome)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (path + extra.filter { !path.contains($0) }).joined(separator: ":")
        return env
    }

    public var configTOML: String {
        """
        # Чилк: isolated Codex profile (written by Chilk.app; edits are overwritten)
        model = "\(model)"
        model_reasoning_effort = "\(effort)"
        cli_auth_credentials_store = "file"
        web_search = "live"

        [features]
        shell_tool = false
        unified_exec = false
        computer_use = false
        browser_use = false
        browser_use_external = false
        browser_use_full_cdp_access = false
        code_mode_host = true
        view_image = false
        apps = false
        plugins = false
        skill_search = false
        multi_agent = false
        multi_agent_v2 = false
        memories = false
        goals = false
        image_generation = false
        sleep_tool = false

        [shell_environment_policy]
        set = { HOME = "\(realHome)" }

        """
    }

    public var isLoggedInOnDisk: Bool {
        FileManager.default.fileExists(atPath: codexHome.appendingPathComponent("auth.json").path)
    }

    /// Creates the folders and (re)writes config.toml.
    public func prepare() throws {
        let fm = FileManager.default
        for dir in [codexHome, isolatedHome, workDir] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let config = codexHome.appendingPathComponent("config.toml")
        if (try? String(contentsOf: config, encoding: .utf8)) != configTOML {
            try configTOML.write(to: config, atomically: true, encoding: .utf8)
        }
    }

    /// How to install Codex, shown when it is not found (the official ways: Homebrew cask or npm).
    public static let installCommand = "brew install --cask codex"
    public static let installCommandNPM = "npm install -g @openai/codex"

    /// Finds the `codex` binary: PATH first, then the usual install places (Finder-launched apps have no shell PATH).
    public static func locateCodex(path: String? = ProcessInfo.processInfo.environment["PATH"],
                                   home: String = NSHomeDirectory(),
                                   systemDirs: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]) -> URL? {
        for dir in searchDirectories(path: path, home: home, systemDirs: systemDirs) {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Where `codex` may live, in lookup order: PATH, Homebrew and npm's global folders, then the Node version
    /// managers — volta, pnpm, bun and every nvm Node (newest first).
    static func searchDirectories(path: String?, home: String,
                                  systemDirs: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]) -> [String] {
        let onPath: [String] = (path ?? "").split(separator: ":").map(String.init)
        let npm: [String] = ["\(home)/.npm-global/bin", "\(home)/bin"]
        let managers: [String] = ["\(home)/.volta/bin", "\(home)/Library/pnpm", "\(home)/.bun/bin"]
        var dirs: [String] = onPath
        dirs.append("\(home)/.local/bin")
        dirs.append(contentsOf: systemDirs)
        dirs.append(contentsOf: npm)
        dirs.append(contentsOf: managers)
        dirs.append(contentsOf: nvmBinDirectories(home: home))
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }
    }

    /// `~/.nvm/versions/node/<version>/bin`, newest version first («v22.11.0» before «v9.0.0»).
    static func nvmBinDirectories(home: String) -> [String] {
        let root = "\(home)/.nvm/versions/node"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return versions.filter { $0.hasPrefix("v") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(root)/\($0)/bin" }
    }

    public func makeClient() -> CodexClient {
        CodexClient(executable: executable, environment: environment, workDir: workDir)
    }
}

/// High-level calls on top of the client.
extension CodexClient {
    public struct Account: Sendable, Equatable {
        public var email: String?
        public var plan: String?
    }

    /// `nil` = not logged in.
    public func account() async throws -> Account? {
        let r = try await request("account/read", [:])
        guard let a = r["account"], a != .null else { return nil }
        return Account(email: a["email"]?.string, plan: a["planType"]?.string)
    }

    /// ChatGPT login: returns the URL to open in the browser; `account/login/completed` follows.
    public func startLogin() async throws -> URL {
        let r = try await request("account/login/start", ["type": "chatgpt"])
        guard let s = r["authUrl"]?.string, let url = URL(string: s) else { throw ClientError.rpc(code: 0, message: "no authUrl") }
        return url
    }

    /// One entry of `model/list` (slice 9f): what Settings → «Мозг» offers and what a chosen model is checked against.
    public struct Model: Sendable, Equatable {
        public var id: String
        public var displayName: String
        public var isDefault: Bool
        /// `supportedReasoningEfforts[].reasoningEffort`, in Codex's order.
        public var efforts: [String]
        public var defaultEffort: String?
        /// Codex lists it but would not show it in a picker.
        public var hidden: Bool

        public init(id: String, displayName: String, isDefault: Bool = false, efforts: [String] = [],
                    defaultEffort: String? = nil, hidden: Bool = false) {
            self.id = id
            self.displayName = displayName
            self.isDefault = isDefault
            self.efforts = efforts
            self.defaultEffort = defaultEffort
            self.hidden = hidden
        }

        /// `nil` when the entry has no id.
        init?(_ json: JSON) {
            guard let id = json["id"]?.string ?? json["model"]?.string, !id.isEmpty else { return nil }
            self.id = id
            displayName = json["displayName"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? id
            isDefault = json["isDefault"]?.bool ?? false
            efforts = (json["supportedReasoningEfforts"]?.elements ?? []).compactMap { $0["reasoningEffort"]?.string }
            defaultEffort = json["defaultReasoningEffort"]?.string
            hidden = json["hidden"]?.bool ?? false
        }
    }

    /// The models this account offers (`model/list`, all pages; read-only, no model turn). Hidden ones included —
    /// a chosen hidden model is still available; the picker leaves them out. Throws when the list cannot be read
    /// whole: a cursor that repeats or one still left after `maxPages` pages means «unknown», never a partial list
    /// (a model on a page not read would show as «недоступна»). An empty list is returned as is — the caller treats it
    /// as unknown too.
    public func models(maxPages: Int = 10) async throws -> [Model] {
        var all: [Model] = []
        var cursor: String?
        var seen: Set<String> = []
        for _ in 0..<maxPages {
            var params: [String: JSON] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let r = try await request("model/list", .object(params))
            guard let data = r["data"]?.elements else { throw ClientError.rpc(code: 0, message: "no model list") }
            for m in data.compactMap(Model.init) where !all.contains(where: { $0.id == m.id }) { all.append(m) }
            guard let next = r["nextCursor"]?.string, !next.isEmpty else { return all }
            guard seen.insert(next).inserted else {
                throw ClientError.rpc(code: 0, message: "model/list cursor \(next) repeats")
            }
            cursor = next
        }
        throw ClientError.rpc(code: 0, message: "model/list has more than \(maxPages) pages")
    }

    /// `environments: []` = no execution environment: no shell, no apply_patch, no file edits. Chilk's actions
    /// are only its own dynamic tools (plus web search). Verified against the live tool list (codex 0.160):
    /// `unified_exec = false` alone is not honoured, so this parameter is the real guard.
    /// `config`: per-thread overrides of config.toml (slice 5a: `{"web_search": "disabled"}` when the user switched
    /// web search off — verified live on codex 0.160: that thread gets no web search, others on the server keep it).
    public func startThread(model: String, instructions: String, cwd: URL, tools: [CodexTool] = [],
                            config: JSON? = nil, onTool: CodexToolHandler? = nil) async throws -> String {
        var params: [String: JSON] = [
            "model": .string(model), "cwd": .string(cwd.path), "developerInstructions": .string(instructions),
            "ephemeral": true, "sandbox": "read-only", "approvalPolicy": "never", "allowProviderModelFallback": false,
            "environments": .array([]),
        ]
        if !tools.isEmpty { params["dynamicTools"] = .array(tools.map(\.descriptor)) }
        if let config { params["config"] = config }
        let r = try await request("thread/start", .object(params))
        guard let id = r["thread"]?["id"]?.string else { throw ClientError.rpc(code: 0, message: "no thread id") }
        if let onTool { installTools(tools, thread: id, handler: onTool) }
        return id
    }
}

private extension JSON {
    /// The items of a JSON array (`nil` for anything else).
    var elements: [JSON]? { if case .array(let a) = self { return a } else { return nil } }
}
