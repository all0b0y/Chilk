import Foundation

// MARK: - Slice 8d (SPEC «Срез 8», decision 9): timers in Apple's Clock app through the shortcut «Чилк»

/// macOS gives a third-party app no way to start a Clock timer (no AlarmKit in the macOS SDK); Clock's actions are
/// reachable only through Shortcuts. Chilk builds one shortcut «Чилк», signs it on this Mac (`shortcuts sign`), the
/// user adds it with one click in the Shortcuts import window (no API imports a shortcut silently), and Chilk runs it
/// in the background: `shortcuts run Чилк -i <file.json>` with {"do": "start", "seconds": N}.
///
/// Measured on macOS 26.6: the built-in `is.workflow.actions.timer.start` signs; Clock's Cancel / Pause / Resume / Get
/// Current Timer intents are refused by `shortcuts sign` («contains unsupported features»), so the shortcut only
/// starts a timer and Chilk opens Clock for the rest (the user's choice «A», 2026-10-07).
public struct ClockShortcut: Sendable {
    public static let name = "Чилк"
    /// Bumped whenever the workflow changes: an older installed shortcut is offered again.
    public static let version = "chilk-shortcut 1"

    public struct Run: Sendable, Equatable {
        public var status: Int32
        public var output: String
        public var error: String
        public init(status: Int32, output: String, error: String) {
            self.status = status
            self.output = output
            self.error = error
        }
    }

    /// Runs `/usr/bin/shortcuts` with arguments (a seam for tests and demo runs).
    public typealias Runner = @Sendable ([String]) async -> Run

    public enum Failure: Error, Equatable, Sendable {
        /// The shortcut «Чилк» is not added (or is an older version).
        case notInstalled
        /// `shortcuts sign` failed (no network / iCloud, or Shortcuts refused the file).
        case signFailed(String)
        /// The shortcut ran and failed (Clock refused, the user denied a prompt…).
        case runFailed(String)
    }

    public enum State: Equatable, Sendable { case missing, outdated, ready }

    private let run: Runner
    private let workDir: URL

    public init(workDir: URL, run: @escaping Runner = ClockShortcut.processRunner) {
        self.workDir = workDir
        self.run = run
    }

    // MARK: Using it

    /// Added and of this version (two `shortcuts` runs: at launch and while waiting for the user's click only).
    public func state() async -> State {
        guard await isListed() else { return .missing }
        return Self.isCurrent(await ask(["do": "version"])) ? .ready : .outdated
    }

    /// A shortcut named «Чилк» is in the user's list (one cheap `shortcuts list`).
    public func isListed() async -> Bool {
        let list = await run(["list"])
        return list.status == 0 && list.output.split(whereSeparator: \.isNewline).contains { $0 == Self.name }
    }

    private static func isCurrent(_ output: String?) -> Bool {
        output?.trimmingCharacters(in: .whitespacesAndNewlines) == version
    }

    /// Starts a Clock timer for `seconds` (counted from now) — one run: the shortcut answers with its version.
    /// Returns `false` when the timer started but the shortcut is an older version (offer the new one).
    @discardableResult
    public func startTimer(seconds: Int) async throws(Failure) -> Bool {
        let result = await runShortcut(["do": "start", "seconds": max(1, seconds)])
        if result.status == 0 { return Self.isCurrent(result.output) }
        if result.status == Self.timedOut { throw .runFailed("timeout") }
        if await !isListed() { throw .notInstalled }
        throw .runFailed(Self.firstLine(result.error))
    }

    /// The status a run gets when it was stopped after 60 s.
    public static let timedOut: Int32 = -2

    private func ask(_ input: [String: Any]) async -> String? {
        let result = await runShortcut(input)
        return result.status == 0 ? result.output : nil
    }

    private func runShortcut(_ input: [String: Any]) async -> Run {
        let id = UUID().uuidString
        let inFile = workDir.appending(path: "clock-in-\(id).json")
        let outFile = workDir.appending(path: "clock-out-\(id).txt")
        defer {
            try? FileManager.default.removeItem(at: inFile)
            try? FileManager.default.removeItem(at: outFile)
        }
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: input).write(to: inFile)
        } catch { return Run(status: -1, output: "", error: "could not write the input") }
        var result = await run(["run", Self.name, "--input-path", inFile.path, "--output-path", outFile.path,
                                "--output-type", "public.plain-text"])
        if let text = try? String(contentsOf: outFile, encoding: .utf8) { result.output = text }
        return result
    }

    // MARK: Adding it

    /// The signed file to open (the Shortcuts import window). Named «Чилк.shortcut»: the name becomes the shortcut's.
    public func signedFile() async throws(Failure) -> URL {
        let dir = workDir.appending(path: "shortcut")
        let unsigned = dir.appending(path: "Chilk-unsigned.shortcut")   // `sign` reads only *.shortcut
        let signed = dir.appending(path: "\(Self.name).shortcut")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: signed)
            let data = try PropertyListSerialization.data(fromPropertyList: Self.workflow(), format: .binary, options: 0)
            try data.write(to: unsigned)
        } catch { throw .signFailed("could not write the file") }
        let result = await run(["sign", "--mode", "anyone", "--input", unsigned.path, "--output", signed.path])
        try? FileManager.default.removeItem(at: unsigned)
        guard result.status == 0, FileManager.default.fileExists(atPath: signed.path) else {
            throw .signFailed(Self.firstLine(result.error.isEmpty ? result.output : result.error))
        }
        return signed
    }

    private static func firstLine(_ s: String) -> String {
        String(s.split(whereSeparator: \.isNewline).first ?? "").prefix(200).description
    }

    // MARK: The workflow

    /// The shortcut: input JSON → «do». «start» → Start Timer for «seconds»; «version» → only the output. Output: the
    /// version text (Chilk checks it).
    public static func workflow() -> [String: Any] {
        let dictionary = uid(), command = uid(), seconds = uid(), versionText = uid()
        var actions: [[String: Any]] = [
            action("is.workflow.actions.detect.dictionary", [
                "UUID": dictionary,
                "WFInput": ["Value": ["Type": "ExtensionInput"], "WFSerializationType": "WFTextTokenAttachment"]]),
            action("is.workflow.actions.getvalueforkey", [
                "UUID": command, "WFDictionaryKey": "do", "WFInput": attachment(dictionary, "Dictionary")]),
        ]
        let group = uid()
        actions.append(action("is.workflow.actions.conditional", [
            "GroupingIdentifier": group, "WFControlFlowMode": 0, "WFCondition": 4, "WFConditionalActionString": "start",
            "WFInput": ["Type": "Variable", "Variable": attachment(command, "Dictionary Value")]]))
        actions.append(action("is.workflow.actions.getvalueforkey", [
            "UUID": seconds, "WFDictionaryKey": "seconds", "WFInput": attachment(dictionary, "Dictionary")]))
        actions.append(action("is.workflow.actions.timer.start", [
            "UUID": uid(),
            "WFDuration": ["Value": ["Magnitude": attachment(seconds, "Dictionary Value"), "Unit": "sec"],
                           "WFSerializationType": "WFQuantityFieldValue"]]))
        actions.append(action("is.workflow.actions.conditional", [
            "GroupingIdentifier": group, "WFControlFlowMode": 2, "UUID": uid()]))
        actions.append(action("is.workflow.actions.gettext", ["UUID": versionText, "WFTextActionText": version]))
        actions.append(action("is.workflow.actions.output", [
            "UUID": uid(),
            "WFOutput": ["Value": ["string": "\u{FFFC}",
                                   "attachmentsByRange": ["{0, 1}": outputRef(versionText, "Text")]],
                         "WFSerializationType": "WFTextTokenString"]]))
        return [
            "WFWorkflowClientVersion": "4711",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 4_282_601_983, "WFWorkflowIconGlyphNumber": 59511],
            "WFWorkflowImportQuestions": [Any](),
            "WFWorkflowTypes": [Any](),
            "WFWorkflowInputContentItemClasses": ["WFStringContentItem", "WFGenericFileContentItem",
                                                  "WFDictionaryContentItem"],
            "WFWorkflowHasShortcutInputVariables": true,
            "WFWorkflowHasOutputFallback": false,
            "WFWorkflowOutputContentItemClasses": ["WFStringContentItem"],
            "WFQuickActionSurfaces": [Any](),
            "WFWorkflowActions": actions,
        ]
    }

    private static func uid() -> String { UUID().uuidString }

    private static func action(_ id: String, _ params: [String: Any]) -> [String: Any] {
        ["WFWorkflowActionIdentifier": id, "WFWorkflowActionParameters": params]
    }

    private static func outputRef(_ uuid: String, _ name: String) -> [String: Any] {
        ["Type": "ActionOutput", "OutputUUID": uuid, "OutputName": name]
    }

    private static func attachment(_ uuid: String, _ name: String) -> [String: Any] {
        ["Value": outputRef(uuid, name), "WFSerializationType": "WFTextTokenAttachment"]
    }

    // MARK: The real runner

    /// `/usr/bin/shortcuts` off the main thread, 60 s at most (a stuck run must not hold the card's result forever).
    public static let processRunner: Runner = { args in
        await run(executable: "/usr/bin/shortcuts", args, timeout: 60)
    }

    /// Output goes to files, not pipes (a full pipe would block the child). After `timeout`: SIGTERM, 3 s later
    /// SIGKILL; the run then reports `timedOut`.
    public static func run(executable: String, _ args: [String], timeout: TimeInterval) async -> Run {
        await withCheckedContinuation { (done: CheckedContinuation<Run, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let dir = FileManager.default.temporaryDirectory
                let id = UUID().uuidString
                let outURL = dir.appending(path: "chilk-sc-\(id).out"), errURL = dir.appending(path: "chilk-sc-\(id).err")
                defer {
                    try? FileManager.default.removeItem(at: outURL)
                    try? FileManager.default.removeItem(at: errURL)
                }
                guard FileManager.default.createFile(atPath: outURL.path, contents: nil),
                      FileManager.default.createFile(atPath: errURL.path, contents: nil),
                      let out = try? FileHandle(forWritingTo: outURL), let err = try? FileHandle(forWritingTo: errURL)
                else { done.resume(returning: Run(status: -1, output: "", error: "could not create output files")); return }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = args
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                let exited = DispatchSemaphore(value: 0)
                p.terminationHandler = { _ in exited.signal() }
                do { try p.run() } catch {
                    try? out.close(); try? err.close()
                    done.resume(returning: Run(status: -1, output: "", error: "could not start \(executable)"))
                    return
                }
                var timedOut = false
                if exited.wait(timeout: .now() + timeout) == .timedOut {
                    timedOut = true
                    p.terminate()
                    if exited.wait(timeout: .now() + 3) == .timedOut {
                        kill(p.processIdentifier, SIGKILL)
                        exited.wait()
                    }
                }
                try? out.close(); try? err.close()
                let o = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
                let e = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
                done.resume(returning: Run(status: timedOut ? Self.timedOut : p.terminationStatus, output: o,
                                           error: timedOut ? "timeout" : e))
            }
        }
    }
}
