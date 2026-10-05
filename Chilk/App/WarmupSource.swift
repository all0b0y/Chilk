import ChilkBrain
import ChilkCore
import Foundation

/// Where each warm-up comes from (decision 2026-10-05, «2 + 1 это как раз вариант экстренный»): Codex writes
/// the next one ahead of time, in the background, while nobody is talking; offline, failing or rejected by
/// the rules — the hand-written library. Only the time of day goes to Codex.
@MainActor
final class WarmupSource {
    enum Origin: String { case codex, library }

    private let brain: Brain
    private let file = AppState.directory.appendingPathComponent("warmup.json")
    private var ready: [Exercise]?
    private var running = false
    private var failures = 0
    private var timer: Timer?
    private var rng = SystemRandomNumberGenerator()
    /// Set by the app: the user is talking with Chilk (preparing waits).
    var busy: () -> Bool = { false }
    var log: (String) -> Void = { _ in }

    init(brain: Brain) {
        self.brain = brain
        if let data = try? Data(contentsOf: file), let steps = try? JSONDecoder().decode([Exercise].self, from: data),
           Warmup.isValid(steps) {
            ready = steps
        }
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prepareIfNeeded() }
        }
        timer?.tolerance = 20
    }

    /// The next warm-up right now: the prepared one, else the library. A new one is prepared after it is
    /// finished (`used`); an interrupted Codex warm-up is given back, so start/stop costs no Codex turns.
    func take() -> (steps: [Exercise], origin: Origin) {
        defer {
            ready = nil
            try? FileManager.default.removeItem(at: file)
        }
        if let steps = ready, Warmup.isValid(steps) { return (steps, .codex) }
        return (Warmup.compose(from: Lines.warmupLibrary, using: &rng) ?? Self.fixed, .library)
    }

    /// A fixed, known-valid order — only if the library itself were broken (a test guards against that).
    private static var fixed: [Exercise] {
        let lib = Lines.warmupLibrary
        let pick = { (k: ExerciseKind, n: Int) in Array(lib.filter { $0.kind == k }.prefix(n)) }
        return pick(.body, 2) + pick(.eyes, 1) + pick(.mind, 1) + pick(.breath, 1)
    }

    func giveBack(_ steps: [Exercise], origin: Origin) {
        guard origin == .codex, ready == nil, Warmup.isValid(steps) else { return }
        ready = steps
        try? JSONEncoder().encode(steps).write(to: file, options: .atomic)
    }

    func prepareIfNeeded(now: Date = Date()) {
        guard ready == nil, !running, !busy(), brain.state == .ready, failures < 3 else { return }
        running = true
        let text = Warmup.request(period: Self.period(Calendar.current.component(.hour, from: now)))
        Task {
            defer { running = false }
            do {
                let reply = try await brain.oneOff(instructions: Persona.character, text: text, schema: JSON(any: Warmup.schema))
                guard let steps = Warmup.parse(reply) else {
                    failures += 1
                    return log("warmup: Codex answer rejected by the rules")
                }
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(steps).write(to: file, options: .atomic)
                ready = steps
                failures = 0
                log("warmup: prepared by Codex (\(steps.map(\.kind.rawValue).joined(separator: ",")))")
            } catch {
                failures += 1
                log("warmup: preparing failed (\(error))")
            }
        }
    }

    func shutdown() { timer?.invalidate(); timer = nil }

    private static func period(_ hour: Int) -> String {
        switch hour {
        case 5..<12: "утро"
        case 12..<18: "день"
        case 18..<23: "вечер"
        default: "ночь"
        }
    }
}
