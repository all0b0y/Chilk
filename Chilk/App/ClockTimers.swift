import AppKit
import ChilkApple
import ChilkCore

/// Slice 8d (SPEC «Срез 8», decision 9): timers ring in Apple's Clock through the shortcut «Чилк».
/// - At launch of a new build the shortcut is offered: Chilk signs it on this Mac and opens the Shortcuts import
///   window; the user clicks «Добавить» — no API adds a shortcut silently. Marked done only once it was offered.
/// - On a timer card's «Да» the timer starts in one `shortcuts run` (it answers with its version). A missing shortcut
///   is offered again and the timer starts as soon as it is added (≤ 90 s), still counted from «Да».
/// - Cancel / pause / resume: macOS refuses to sign Clock's intents into a shared shortcut, so Chilk opens Clock (the
///   user's choice «A»).
@MainActor
final class ClockTimers {
    private let shortcut: ClockShortcut
    private let fake: FakeClock?
    private let markFile = AppState.directory.appendingPathComponent("clock-shortcut-offered.txt")
    var log: (String) -> Void = { _ in }
    /// Chilk's line while he waits for the user's click: shown when the stage is free (waits up to 30 s for it).
    var speak: (String) -> Void = { _ in }
    var stageFree: () -> Bool = { false }
    /// One shared «offer and wait for the click»: a second «Да» meanwhile waits for the same window, never opens another.
    private var addition: Task<Addition, Never>?
    private var sayTask: Task<Void, Never>?
    private var updateOffered = false

    init() {
        let work = AppState.directory.appendingPathComponent("clock", isDirectory: true)
        if ProcessInfo.processInfo.environment["CHILK_FAKE_CLOCK"] != nil {
            let fake = FakeClock(file: AppState.directory.appendingPathComponent("clock-fake.json"),
                                 closesFirst: ProcessInfo.processInfo.environment["CHILK_FAKE_CLOCK"] == "closed")
            self.fake = fake
            shortcut = ClockShortcut(workDir: work, run: fake.runner)
        } else {
            fake = nil
            shortcut = ClockShortcut(workDir: work)
        }
    }

    private static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + " · " + ClockShortcut.version
    }

    /// The latest line only; a line still waiting for the stage is dropped when a newer one comes or it is stale.
    private func say(_ line: String, while relevant: @escaping @MainActor () -> Bool = { true }) {
        sayTask?.cancel()
        sayTask = Task {
            for _ in 0..<15 {
                guard !Task.isCancelled, relevant() else { return }
                if stageFree() { speak(line); return }
                try? await Task.sleep(for: .seconds(2))
            }
            log("clock: a line not shown (the stage stayed busy)")
        }
    }

    /// Once per installed build: the shortcut is checked and, if missing or old, offered. Demo runs with an isolated
    /// state dir never pop the import window unless the Clock is fake.
    func checkAtLaunch() {
        let isolated = ProcessInfo.processInfo.environment["CHILK_STATE_DIR"] != nil
        guard !isolated || fake != nil else { return }
        let offered = (try? String(contentsOf: markFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard offered != Self.build else { return }
        Task {
            let state = await shortcut.state()
            log("clock shortcut at launch: \(state)")
            if state != .ready {
                guard await offer() else { return }               // offline: offered again at the next launch
                say(state == .missing
                    ? String(localized: "Добавь команду «Чилк» — нажми «Добавить» в окне «Быстрых команд». Через неё ставлю таймеры в «Часах»")
                    : String(localized: "Обнови команду «Чилк» — нажми «Заменить» в окне «Быстрых команд»"))
            }
            try? Self.build.write(to: markFile, atomically: true, encoding: .utf8)
        }
    }

    /// Signs the shortcut and opens the import window. `false`: it could not be prepared (no network / iCloud?).
    private func offer() async -> Bool {
        do {
            let file = try await shortcut.signedFile()
            if let fake { fake.userAdds() } else { NSWorkspace.shared.open(file) }
            log("clock shortcut offered")
            return true
        } catch {
            log("clock shortcut not offered: \(error)")
            return false
        }
    }

    private enum Addition { case added, notAdded, notPrepared }

    /// Offer + wait (≤ 90 s) for «Чилк» to appear in the list; shared by every caller meanwhile.
    private func waitForAddition() async -> Addition {
        if let addition { return await addition.value }
        let task = Task { () -> Addition in
            guard await offer() else { return .notPrepared }
            for _ in 0..<45 {
                try? await Task.sleep(for: .seconds(2))
                if await shortcut.isListed() { return .added }
            }
            log("clock shortcut not added in 90 s")
            return .notAdded
        }
        addition = task
        let result = await task.value
        addition = nil
        return result
    }

    enum StartResult { case started, notAdded, notPrepared, failed }

    /// The card's «Да» (`confirmedAt`): the timer counts from it even when the shortcut had to be added first.
    func start(seconds: Int, confirmedAt: Date) async -> StartResult {
        func remaining() -> Int { max(1, seconds - Int(Date().timeIntervalSince(confirmedAt).rounded())) }
        var waiting = false
        for attempt in 0..<2 {
            do {
                let current = try await shortcut.startTimer(seconds: remaining())
                if !current, !updateOffered {
                    updateOffered = true                           // started by the old one; offer the new once a run
                    if await offer() {
                        say(String(localized: "Обнови команду «Чилк» — нажми «Заменить» в окне «Быстрых команд»"))
                    }
                }
                sayTask?.cancel()
                return .started
            } catch .notInstalled {
                guard attempt == 0 else { return .notAdded }
                waiting = true
                say(String(localized: "Нажми «Добавить» в окне «Быстрых команд» — и таймер пойдёт"),
                    while: { [weak self] in self?.addition != nil })
                switch await waitForAddition() {
                case .added: continue
                case .notAdded: return .notAdded
                case .notPrepared: return .notPrepared
                }
            } catch {
                log("clock timer failed: \(error)\(waiting ? " (after adding the shortcut)" : "")")
                return .failed
            }
        }
        return .notAdded
    }

    /// Cancel / pause / resume: the user does it in Clock.
    func openClock() {
        if let fake { fake.opened(); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Clock.app"))
    }
}

/// Acceptance only (CHILK_FAKE_CLOCK=1): plays `/usr/bin/shortcuts` — the import is «clicked» 3 s after the offer
/// (`closed`: the first import window is closed unclicked), started timers and Clock openings go to `clock-fake.json`.
final class FakeClock: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private var added: Date?
    private var events: [[String: Any]] = []

    private var closesFirst: Bool

    init(file: URL, closesFirst: Bool) {
        self.file = file
        self.closesFirst = closesFirst
    }

    func userAdds() {
        lock.withLock {
            if closesFirst { closesFirst = false; record(["import": "closed"]); return }
            added = Date().addingTimeInterval(3)
            record(["import": "added"])
        }
    }
    func opened() { lock.withLock { record(["opened": "Clock"]) } }

    private var installed: Bool { added.map { Date() >= $0 } ?? false }

    private func record(_ e: [String: Any]) {
        var e = e
        e["at"] = ISO8601DateFormatter().string(from: Date())
        events.append(e)
        if let data = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: file)
        }
    }

    var runner: ClockShortcut.Runner {
        { [self] args in lock.withLock { handle(args) } }
    }

    private func handle(_ args: [String]) -> ClockShortcut.Run {
        switch args.first {
        case "list": return .init(status: 0, output: installed ? "Перерыв\nЧилк\n" : "Перерыв\n", error: "")
        case "sign":
            if let i = args.firstIndex(of: "--output"), i + 1 < args.count {
                try? Data("AEA1".utf8).write(to: URL(fileURLWithPath: args[i + 1]))
            }
            return .init(status: 0, output: "", error: "")
        case "run":
            guard installed else { return .init(status: 1, output: "", error: "Error: The shortcut «Чилк» couldn’t be found.") }
            let input = args.firstIndex(of: "--input-path").map { URL(fileURLWithPath: args[$0 + 1]) }
            let json = input.flatMap { try? JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any] } ?? [:]
            if json["do"] as? String == "start" { record(["timer": json["seconds"] ?? 0]) }
            if let i = args.firstIndex(of: "--output-path") {
                try? ClockShortcut.version.write(to: URL(fileURLWithPath: args[i + 1]), atomically: true, encoding: .utf8)
            }
            return .init(status: 0, output: "", error: "")
        default: return .init(status: 1, output: "", error: "?")
        }
    }
}
