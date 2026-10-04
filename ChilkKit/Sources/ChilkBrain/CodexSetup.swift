import Foundation

/// Чилк's own Codex profile (В4, spike 002): a separate CODEX_HOME inside the app's data, a fake HOME so the
/// user's ~/.agents skills do not leak in, while Codex's shell commands still see the real HOME.
public struct CodexSetup: Sendable {
    public var executable: URL
    public var codexHome: URL
    public var isolatedHome: URL
    public var workDir: URL
    public var realHome: String
    public var model = "gpt-6-luna"
    public var effort = "low"

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
        // Apps started from Finder get a minimal PATH; Codex's own commands need the usual tools.
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(realHome)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
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

    /// Finds the `codex` binary: PATH first, then the usual install places (Finder-launched apps have no shell PATH).
    public static func locateCodex(path: String? = ProcessInfo.processInfo.environment["PATH"],
                                   home: String = NSHomeDirectory()) -> URL? {
        let dirs = (path ?? "").split(separator: ":").map(String.init)
            + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/bin"]
        for dir in dirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
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

    public func startThread(model: String, instructions: String, cwd: URL) async throws -> String {
        let r = try await request("thread/start", [
            "model": .string(model), "cwd": .string(cwd.path), "developerInstructions": .string(instructions),
            "ephemeral": true, "sandbox": "read-only", "approvalPolicy": "never",
        ])
        guard let id = r["thread"]?["id"]?.string else { throw ClientError.rpc(code: 0, message: "no thread id") }
        return id
    }
}
