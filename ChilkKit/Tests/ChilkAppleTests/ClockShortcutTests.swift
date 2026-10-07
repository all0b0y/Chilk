import ChilkApple
import Foundation
import Testing

/// Slice 8d (decision 9): the shortcut «Чилк» that starts Clock timers.
struct ClockShortcutTests {
    /// Records the calls and plays a shortcut: «list» → `installed`, «run» → reads the input, writes the output.
    final class FakeShortcuts: @unchecked Sendable {
        var installed: [String] = []
        var version = ClockShortcut.version
        var calls: [[String]] = []
        var inputs: [[String: Any]] = []
        var failRun = false
        let lock = NSLock()

        var runner: ClockShortcut.Runner {
            { [self] args in lock.withLock { handle(args) } }
        }

        private func handle(_ args: [String]) -> ClockShortcut.Run {
                calls.append(args)
                switch args.first {
                case "list": return .init(status: 0, output: installed.joined(separator: "\n") + "\n", error: "")
                case "run":
                    guard installed.contains(args[1]) else { return .init(status: 1, output: "", error: "Error: shortcut not found") }
                    let input = URL(fileURLWithPath: args[args.firstIndex(of: "--input-path")! + 1])
                    let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: input))) as? [String: Any] ?? [:]
                    if failRun, json["do"] as? String == "start" {
                        return .init(status: 1, output: "", error: "Error: Clock refused\nmore")
                    }
                    inputs.append(json)
                    let out = URL(fileURLWithPath: args[args.firstIndex(of: "--output-path")! + 1])
                    try? version.write(to: out, atomically: true, encoding: .utf8)
                    return .init(status: 0, output: "", error: "")
                case "sign":
                    let out = URL(fileURLWithPath: args[args.firstIndex(of: "--output")! + 1])
                    try? Data("AEA1".utf8).write(to: out)
                    return .init(status: 0, output: "", error: "")
                default: return .init(status: 1, output: "", error: "?")
                }
        }
    }

    func dir() -> URL { FileManager.default.temporaryDirectory.appending(path: "clock-\(UUID().uuidString)") }

    @Test func stateIsMissingOutdatedOrReady() async {
        let fake = FakeShortcuts()
        let shortcut = ClockShortcut(workDir: dir(), run: fake.runner)
        #expect(await shortcut.state() == .missing)
        fake.installed = ["Перерыв", "Чилк-2", "Чилк"]
        fake.version = "chilk-shortcut 0"
        #expect(await shortcut.state() == .outdated)
        fake.version = ClockShortcut.version + "\n"
        #expect(await shortcut.state() == .ready)
        #expect(fake.inputs.last?["do"] as? String == "version")
    }

    @Test func aTimerRunsTheShortcutWithItsSeconds() async throws {
        let fake = FakeShortcuts()
        fake.installed = ["Чилк"]
        let work = dir()
        try await ClockShortcut(workDir: work, run: fake.runner).startTimer(seconds: 300)
        #expect(fake.inputs.count == 1)
        #expect(fake.inputs[0]["do"] as? String == "start")
        #expect(fake.inputs[0]["seconds"] as? Int == 300)
        #expect(fake.calls[0].prefix(2) == ["run", "Чилк"])
        // The input and output files do not stay behind.
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).isEmpty)
    }

    @Test func anOlderShortcutStillStartsButSaysSo() async throws {
        let fake = FakeShortcuts()
        fake.installed = ["Чилк"]
        fake.version = "chilk-shortcut 0"
        let current = try await ClockShortcut(workDir: dir(), run: fake.runner).startTimer(seconds: 60)
        #expect(!current)
        #expect(fake.calls.count == 1)                                   // one run: start answers with its version
    }

    @Test func everyReferenceInTheWorkflowPointsToAnEarlierAction() throws {
        let actions = try #require(ClockShortcut.workflow()["WFWorkflowActions"] as? [[String: Any]])
        var seen: Set<String> = []
        func refs(_ v: Any) -> [String] {
            if let d = v as? [String: Any] {
                return (d["OutputUUID"] as? String).map { [$0] } ?? d.values.flatMap(refs)
            }
            if let a = v as? [Any] { return a.flatMap(refs) }
            return []
        }
        for a in actions {
            let params = a["WFWorkflowActionParameters"] as? [String: Any] ?? [:]
            for r in refs(params) { #expect(seen.contains(r), "\(a["WFWorkflowActionIdentifier"] ?? "")") }
            if let id = params["UUID"] as? String { seen.insert(id) }
        }
    }

    @Test func failuresSayWhetherTheShortcutIsMissing() async {
        let fake = FakeShortcuts()
        let shortcut = ClockShortcut(workDir: dir(), run: fake.runner)
        await #expect(throws: ClockShortcut.Failure.notInstalled) { try await shortcut.startTimer(seconds: 60) }
        fake.installed = ["Чилк"]
        fake.failRun = true
        await #expect(throws: ClockShortcut.Failure.runFailed("Error: Clock refused")) {
            try await shortcut.startTimer(seconds: 60)
        }
    }

    @Test func theSignedFileIsNamedLikeTheShortcut() async throws {
        let fake = FakeShortcuts()
        let url = try await ClockShortcut(workDir: dir(), run: fake.runner).signedFile()
        #expect(url.lastPathComponent == "Чилк.shortcut")
        let sign = try #require(fake.calls.first)
        #expect(sign.prefix(3) == ["sign", "--mode", "anyone"])
        #expect(sign[4].hasSuffix(".shortcut"))   // `shortcuts sign` reads only *.shortcut
        #expect(!FileManager.default.fileExists(atPath: sign[4]))
    }

    @Test func theWorkflowStartsATimerAndOutputsItsVersion() throws {
        let wf = ClockShortcut.workflow()
        let data = try PropertyListSerialization.data(fromPropertyList: wf, format: .binary, options: 0)
        #expect(!data.isEmpty)
        let actions = try #require(wf["WFWorkflowActions"] as? [[String: Any]])
        let ids = actions.compactMap { $0["WFWorkflowActionIdentifier"] as? String }
        #expect(ids == ["is.workflow.actions.detect.dictionary", "is.workflow.actions.getvalueforkey",
                        "is.workflow.actions.conditional", "is.workflow.actions.getvalueforkey",
                        "is.workflow.actions.timer.start", "is.workflow.actions.conditional",
                        "is.workflow.actions.gettext", "is.workflow.actions.output"])
        // No Clock intent `shortcuts sign` refuses (Cancel / Pause / Resume / Get Current Timer).
        #expect(!ids.contains { $0.hasPrefix("com.apple.clock.") })
        let text = try #require(actions[6]["WFWorkflowActionParameters"] as? [String: Any])
        #expect(text["WFTextActionText"] as? String == ClockShortcut.version)
        let ifs = actions.filter { $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.conditional" }
            .compactMap { $0["WFWorkflowActionParameters"] as? [String: Any] }
        #expect(ifs.map { $0["WFControlFlowMode"] as? Int } == [0, 2])
        #expect(ifs[0]["GroupingIdentifier"] as? String == ifs[1]["GroupingIdentifier"] as? String)
    }
}

/// The real `shortcuts sign` accepts the workflow (network + iCloud; run by hand: CHILK_REAL_SHORTCUTS=<dir>).
struct ClockShortcutRealSignTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CHILK_REAL_SHORTCUTS"] != nil))
    func theRealSignAcceptsTheWorkflow() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHILK_REAL_SHORTCUTS"]!)
        let url = try await ClockShortcut(workDir: dir).signedFile()
        let head = try FileHandle(forReadingFrom: url).read(upToCount: 4)
        #expect(head == Data("AEA1".utf8))
    }
}

/// The real process runner: big stderr does not block, a stuck child is stopped (SIGTERM, then SIGKILL).
struct ClockShortcutRunnerTests {
    @Test func aChattyChildDoesNotBlock() async {
        let run = await ClockShortcut.run(executable: "/bin/sh",
                                          ["-c", "head -c 300000 /dev/zero | tr '\\\\0' x >&2; echo done"], timeout: 10)
        #expect(run.status == 0)
        #expect(run.output == "done\n")
        #expect(run.error.count == 300_000)
    }

    @Test func aStuckChildIsKilled() async {
        let started = Date()
        let run = await ClockShortcut.run(executable: "/bin/sh", ["-c", "trap '' TERM; sleep 30"], timeout: 1)
        #expect(run.status == ClockShortcut.timedOut)
        #expect(Date().timeIntervalSince(started) < 8)
    }
}
