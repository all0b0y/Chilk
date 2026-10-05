import Foundation

/// Guided breaks (decisions 2026-10-05): «Разминка со мной» — 5 steps of about a minute on a dark screen, and a
/// 15-minute walk with a countdown. Codex writes each warm-up; a hand-written library is the emergency fallback.
public enum ExerciseKind: String, Codable, Sendable, CaseIterable {
    case body, eyes, breath, mind
}

/// What Chilk does while the user does the step: only animations he already has.
public enum ExerciseMove: String, Codable, Sendable, CaseIterable {
    case stretch, lookFar, breathe, still, wave

    /// Which moves fit which kind (a Codex answer with a mismatch is rejected).
    public static func allowed(for kind: ExerciseKind) -> Set<ExerciseMove> {
        switch kind {
        case .body: [.stretch, .wave, .still]
        case .eyes: [.lookFar, .still]
        case .breath: [.breathe]
        case .mind: [.still, .breathe]
        }
    }
}

public struct Exercise: Codable, Sendable, Equatable {
    public var kind: ExerciseKind
    public var text: String
    public var move: ExerciseMove

    public init(_ kind: ExerciseKind, _ text: String, move: ExerciseMove) {
        self.kind = kind
        self.text = text
        self.move = move
    }
}

public enum Warmup {
    public static let stepSeconds: TimeInterval = 60
    public static let walkSeconds: TimeInterval = 15 * 60
    /// 2 body, 1 eyes, 1 breath, 1 mind («для головы»).
    public static let shape: [ExerciseKind: Int] = [.body: 2, .eyes: 1, .breath: 1, .mind: 1]
    public static var stepCount: Int { shape.values.reduce(0, +) }
    public static let maxText = 120

    /// Nothing about loads, jumping, weight or health (decision 2026-10-05). Word starts, lower case.
    static let banned = ["прыг", "прыж", "подпрыг", "попрыг", "запрыг", "бег", "присед", "отжим", "планк", "гантел", "похуд", "калори", "диет",
                         "вес тела", "диагноз", "лечен", "таблет", "лекарств", "врач", "давлени", "болит", "болезн", "болев"]

    public static func safe(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...maxText).contains(t.count),
              !t.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.isEmojiPresentation }),
              !t.contains("http"), !t.contains("<"), !t.contains("`") else { return false }
        let lower = " " + t.lowercased()
        let separators = CharacterSet.letters.inverted
        return !banned.contains { stem in
            var range = lower.startIndex..<lower.endIndex
            while let hit = lower.range(of: stem, range: range) {
                let before = lower[lower.index(before: hit.lowerBound)]
                if before.unicodeScalars.allSatisfy({ separators.contains($0) }) { return true }
                range = hit.upperBound..<lower.endIndex
            }
            return false
        }
    }

    /// The shape, a body step first, a calm one (breath or mind) last, safe short texts, fitting moves.
    public static func isValid(_ steps: [Exercise]) -> Bool {
        guard steps.count == stepCount, steps.first?.kind == .body,
              let last = steps.last, last.kind == .breath || last.kind == .mind else { return false }
        let counts = Dictionary(grouping: steps, by: \.kind).mapValues(\.count)
        return counts == shape && steps.allSatisfy { safe($0.text) && ExerciseMove.allowed(for: $0.kind).contains($0.move) }
    }

    /// A warm-up from the library: same shape and order rules, a new order each time.
    public static func compose<G: RandomNumberGenerator>(from library: [Exercise], using rng: inout G) -> [Exercise]? {
        var picked: [Exercise] = []
        for kind in ExerciseKind.allCases {
            let pool = library.filter { $0.kind == kind && safe($0.text) }.shuffled(using: &rng)
            guard pool.count >= shape[kind, default: 0] else { return nil }
            picked += pool.prefix(shape[kind, default: 0])
        }
        let calm = picked.filter { $0.kind == .breath || $0.kind == .mind }.randomElement(using: &rng)!
        let first = picked.first { $0.kind == .body }!
        var middle = picked
        middle.remove(at: middle.firstIndex(of: first)!)
        middle.remove(at: middle.firstIndex(of: calm)!)
        let steps = [first] + middle.shuffled(using: &rng) + [calm]
        return isValid(steps) ? steps : nil
    }

    // MARK: Codex

    public static var schema: [String: Any] {
        let step: [String: Any] = [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": ExerciseKind.allCases.map(\.rawValue)],
                "text": ["type": "string"],
                "move": ["type": "string", "enum": ExerciseMove.allCases.map(\.rawValue)],
            ],
            "required": ["kind", "text", "move"], "additionalProperties": false,
        ]
        return ["type": "object", "properties": ["steps": ["type": "array", "items": step]],
                "required": ["steps"], "additionalProperties": false]
    }

    /// Only the time of day goes to Codex — nothing about the user (В24).
    public static func request(period: String) -> String {
        """
        Составь короткую разминку у компьютера, сейчас \(period). Ответ — JSON по схеме: ровно 5 шагов steps, \
        каждый примерно на минуту. Состав: 2 шага body (тело), 1 eyes (глаза), 1 breath (дыхание), 1 mind (для \
        головы: внимание, воображение, благодарность и т. п.). Первый шаг — body, последний — спокойный: breath \
        или mind; остальные в любом порядке. text — одна строка до 110 знаков на «ты», что делать, без эмодзи, \
        кавычек и ссылок. Только безопасное сидя или стоя у стола: без прыжков, бега, приседаний, отжиманий и \
        нагрузки, ничего о весе, здоровье, боли и лечении. move — движение Чилка: body — stretch, wave или still; \
        eyes — lookFar или still; breath — breathe; mind — still или breathe.
        """
    }

    public static func parse(_ message: String) -> [Exercise]? {
        guard let data = message.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["steps"] as? [[String: Any]] else { return nil }
        let steps = raw.compactMap { s -> Exercise? in
            guard let kind = (s["kind"] as? String).flatMap(ExerciseKind.init), let text = s["text"] as? String,
                  let move = (s["move"] as? String).flatMap(ExerciseMove.init) else { return nil }
            return Exercise(kind, text.trimmingCharacters(in: .whitespacesAndNewlines), move: move)
        }
        return isValid(steps) ? steps : nil
    }
}

/// A guided break in progress: which step and how much is left. Times are monotonic seconds.
public struct GuidedSession: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case warmup([Exercise])
        case walk
    }

    public let kind: Kind
    public let started: TimeInterval

    public init(_ kind: Kind, started: TimeInterval) {
        self.kind = kind
        self.started = started
    }

    public var duration: TimeInterval {
        switch kind {
        case .warmup(let steps): Double(steps.count) * Warmup.stepSeconds
        case .walk: Warmup.walkSeconds
        }
    }

    /// The step shown at `now` (0 for a walk) and the seconds left in it; nil when finished.
    public func step(at now: TimeInterval) -> (index: Int, left: TimeInterval)? {
        let elapsed = max(0, now - started)
        guard elapsed < duration else { return nil }
        switch kind {
        case .warmup:
            let index = Int(elapsed / Warmup.stepSeconds)
            return (index, Double(index + 1) * Warmup.stepSeconds - elapsed)
        case .walk:
            return (0, duration - elapsed)
        }
    }

    /// What a finished break counts: the warm-up only «размяться» (not the eyes — user decision «2»);
    /// the walk as a walk away from the Mac does.
    public var credits: [Need] {
        switch kind {
        case .warmup: [.stretch]
        case .walk: [.walk, .stretch, .eyes]
        }
    }

    /// «4:59», «0:07».
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds).rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
