import Foundation
import Testing
@testable import ChilkCore

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}

@Suite("Warm-up rules, library and the guided session")
struct WarmupTests {
    static let sample: [Exercise] = [
        Exercise(.body, "Потянись руками вверх, будто достаёшь до верхней полки", move: .stretch),
        Exercise(.eyes, "Посмотри в окно на самую дальнюю точку и задержи на ней взгляд", move: .lookFar),
        Exercise(.body, "Медленно покрути плечами назад, потом вперёд", move: .stretch),
        Exercise(.mind, "Вспомни три хорошие вещи за сегодня, даже маленькие", move: .still),
        Exercise(.breath, "Вдох на четыре счёта, выдох на шесть, плечи вниз", move: .breathe),
    ]

    static let library: [Exercise] = sample + [
        Exercise(.body, "Повращай кистями рук в одну и в другую сторону", move: .stretch),
        Exercise(.eyes, "Закрой глаза ладонями и посиди в темноте", move: .still),
        Exercise(.mind, "Назови про себя пять предметов вокруг тебя", move: .still),
        Exercise(.breath, "Подыши животом: ладонь на живот, медленный вдох", move: .breathe),
    ]

    @Test func theSampleHasTheAgreedShape() {
        #expect(Warmup.isValid(Self.sample))
        #expect(Warmup.stepCount == 5)
    }

    @Test func wrongShapeOrderOrMoveIsRejected() {
        #expect(!Warmup.isValid(Array(Self.sample.dropLast())))                       // 4 steps
        #expect(!Warmup.isValid(Array(Self.sample.reversed())))                     // breath first
        var calmFirst = Self.sample
        calmFirst.swapAt(0, 3)
        #expect(!Warmup.isValid(calmFirst))
        var wrongMove = Self.sample
        wrongMove[4].move = .wave
        #expect(!Warmup.isValid(wrongMove))
        var threeBody = Self.sample
        threeBody[3] = Exercise(.body, "Встань и потянись в стороны, руки на поясе", move: .stretch)
        #expect(!Warmup.isValid(threeBody))
    }

    @Test(arguments: ["Сделай десять приседаний у стола", "Попрыгай на месте полминуты", "Это полезно для похудения и веса",
                      "Если болит спина, выпей таблетку", "Смотри 🙂 вдаль", "Открой https://example.com", "Коротко"])
    func unsafeOrMessyTextIsRejected(_ text: String) {
        #expect(!Warmup.safe(text))
    }

    @Test func harmlessWordsThatStartLikeBannedOnesPass() {
        #expect(Warmup.safe("Сделай шаг больше и потянись к потолку"))
        #expect(Warmup.safe("Весело помаши руками, как будто встречаешь друга"))
    }

    @Test func theLibraryComposesAValidWarmupInADifferentOrder() {
        var rng = SeededGenerator(state: 1)
        var orders = Set<[String]>()
        for _ in 0..<20 {
            let steps = Warmup.compose(from: Self.library, using: &rng)
            #expect(steps.map(Warmup.isValid) == true)
            orders.insert(steps?.map(\.text) ?? [])
        }
        #expect(orders.count > 3)
        #expect(Warmup.compose(from: Array(Self.library.filter { $0.kind != .eyes }), using: &rng) == nil)
    }

    @Test func aCodexAnswerIsParsedAndCheckedLikeTheLibrary() throws {
        let json = """
        {"steps":[{"kind":"body","text":"Потянись руками вверх, будто достаёшь до верхней полки","move":"stretch"},
        {"kind":"eyes","text":"Посмотри в окно на самую дальнюю точку","move":"lookFar"},
        {"kind":"body","text":"Медленно покрути плечами назад, потом вперёд","move":"wave"},
        {"kind":"mind","text":"Вспомни три хорошие вещи за сегодня","move":"still"},
        {"kind":"breath","text":"Вдох на четыре счёта, выдох на шесть","move":"breathe"}]}
        """
        #expect(Warmup.parse(json)?.count == 5)
        #expect(Warmup.parse(json.replacingOccurrences(of: "Медленно покрути", with: "Сделай двадцать отжиманий, покрути")) == nil)
        #expect(Warmup.parse("not json") == nil)
        #expect(Warmup.request(period: "утро").contains("утро"))
    }

    @Test func theSessionWalksThroughFiveMinutesAndAWalkLastsFifteen() {
        let s = GuidedSession(.warmup(Self.sample), started: 100)
        #expect(s.duration == 300)
        #expect(s.step(at: 100)?.index == 0)
        #expect(s.step(at: 159.5)?.index == 0)
        #expect(s.step(at: 160)?.index == 1)
        #expect(s.step(at: 399)?.index == 4)
        #expect(s.step(at: 400) == nil)
        #expect(s.credits == [.stretch])
        let walk = GuidedSession(.walk, started: 0)
        #expect(walk.step(at: 60)?.left == 840)
        #expect(walk.credits == [.walk, .stretch, .eyes])
        #expect(GuidedSession.clock(299.2) == "5:00" && GuidedSession.clock(7) == "0:07")
    }

    /// The app's hand-written emergency library (Chilk/App/BreakLines.swift) obeys the same rules and can always
    /// make a warm-up: every text safe, enough of each kind, moves that fit.
    @Test func theAppLibraryPassesTheRules() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../Chilk/App/BreakLines.swift").standardizedFileURL
        let text = try String(contentsOf: source, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"Exercise\(\.(\w+), String\(localized: "([^"]+)"\), move: \.(\w+)\)"#)
        let library = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m -> Exercise? in
            let g = { Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
            guard let kind = ExerciseKind(rawValue: g(1)), let move = ExerciseMove(rawValue: g(3)) else { return nil }
            return Exercise(kind, g(2), move: move)
        }
        #expect(library.count == 20)
        let counts = Dictionary(grouping: library, by: \.kind).mapValues(\.count)
        #expect(counts == [.body: 8, .eyes: 4, .breath: 3, .mind: 5])
        for e in library {
            #expect(Warmup.safe(e.text), "\(e.text)")
            #expect(ExerciseMove.allowed(for: e.kind).contains(e.move), "\(e.text)")
        }
        var rng = SeededGenerator(state: 9)
        for _ in 0..<50 { #expect(Warmup.compose(from: library, using: &rng) != nil) }
    }
}
