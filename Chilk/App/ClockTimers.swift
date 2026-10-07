import AppKit
import ChilkApple
import ChilkCore

/// Slice 8d (SPEC «Срез 8», decision 9): timers ring in Apple's Clock through the shortcut «Чилк».
/// - At launch (a new install or update) the shortcut is offered once: Chilk signs it on this Mac and opens the
///   Shortcuts import window; the user clicks «Добавить» — no API adds a shortcut silently.
/// - On a timer card's «Да» a missing shortcut is offered again and the timer starts as soon as it is added (≤ 90 s).
/// - Cancel / pause / resume: macOS refuses to sign Clock's intents into a shared shortcut, so Chilk opens Clock (the
///   user's choice «A»).
@MainActor
final class ClockTimers {
    private let shortcut: ClockShortcut
    private let fake: FakeClock?
    private let stateFile = AppState.directory.appendingPathComponent("clock-shortcut.json")
    var log: (String) -> Void = { _ in }
    /// Chilk's line while he waits for the user's click: shown when the stage is free (waits up to 30 s for it).
    var speak: (String) -> Void = { _ in }
    var stageFree: () -> Bool = { false }

    private func say(_ line: String) {
        Task {
            for _ in 0..<15 {
                if stageFree() { speak(line); return }
                try? await Task.sleep(for: .seconds(2))
            }
            log("clock: a line not shown (the stage stayed busy)")
        }
    }
    private var offering: Task<Bool, Never>?

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

    /// Once per installed build: the shortcut is checked and, if missing or old, offered. Demo runs with an isolated
    /// state dir never pop the import window unless the Clock is fake.
    func checkAtLaunch() {
        let isolated = ProcessInfo.processInfo.environment["CHILK_STATE_DIR"] != nil
        guard !isolated || fake != nil else { return }
        let offered = (try? String(contentsOf: stateFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let state = await shortcut.state()
            log("clock shortcut at launch: \(state)")
            guard state != .ready, offered != Self.build else { return }
            try? Self.build.write(to: stateFile, atomically: true, encoding: .utf8)
            say(state == .missing
                ? String(localized: "Добавь команду «Чилк» — нажми «Добавить» в окне «Быстрых команд». Через неё ставлю таймеры в «Часах»")
                : String(localized: "Обнови команду «Чилк» — нажми «Заменить» в окне «Быстрых команд»"))
            _ = await offer()
        }
    }

    /// Signs the shortcut and opens the import window. `false`: it could not even be prepared.
    @discardableResult
    func offer() async -> Bool {
        if let offering { return await offering.value }
        let task = Task { () -> Bool in
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
        offering = task
        let ok = await task.value
        offering = nil
        return ok
    }

    enum StartResult { case started, notAdded, failed }

    /// The card's «Да». A missing shortcut is offered and waited for (≤ 90 s): one «Да», one click.
    func start(seconds: Int) async -> StartResult {
        if await shortcut.state() != .ready {
            say(String(localized: "Нажми «Добавить» в окне «Быстрых команд» — и таймер пойдёт"))
            guard await offer() else { return .failed }
            var ready = false
            for _ in 0..<45 {
                try? await Task.sleep(for: .seconds(2))
                if await shortcut.state() == .ready { ready = true; break }
            }
            guard ready else { log("clock shortcut not added in 90 s"); return .notAdded }
        }
        do {
            try await shortcut.startTimer(seconds: seconds)
            return .started
        } catch .notInstalled {
            return .notAdded
        } catch {
            log("clock timer failed: \(error)")
            return .failed
        }
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
