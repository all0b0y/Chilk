import ChilkBrain
import ChilkCore
import Foundation

/// The daily batch of Codex lines (decision 2026-10-05): once a day, in the background, while nobody is talking.
/// Only the weekday and the time of day go to Codex. Offline or failing — the hand-written library speaks alone.
@MainActor
final class PhraseBatches {
    private let brain: Brain
    private let file = AppState.directory.appendingPathComponent("phrases.json")
    private var timer: Timer?
    private var running = false
    private var attempts: (day: String, count: Int) = ("", 0)
    /// Set by the app: the user is talking with Chilk (the batch waits).
    var busy: () -> Bool = { false }
    /// Tray → Tools «Свежие фразы от Codex» (slice 5a): off = no batch is asked for and only the library speaks.
    var enabled: () -> Bool = { true }
    var log: (String) -> Void = { _ in }

    init(brain: Brain) {
        self.brain = brain
        Lines.batch = saved
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfNeeded() }
        }
        timer?.tolerance = 10
    }

    private var saved: PhraseBatch? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(PhraseBatch.self, from: $0) }
    }

    /// The switch changed: off drops today's batch from speech at once; on brings it back (or asks for one).
    func switchChanged() {
        Lines.batch = enabled() ? saved : nil
        log("phrases \(enabled() ? "on" : "off")")
        refreshIfNeeded()
    }

    func refreshIfNeeded(now: Date = Date()) {
        let today = PhraseBatch.dayKey(now)
        guard enabled(), Lines.batch?.day != today, !running, !busy(), brain.state == .ready else { return }
        if attempts.day != today { attempts = (today, 0) }
        guard attempts.count < 3 else { return }                          // a bad day costs at most 3 turns
        attempts.count += 1
        running = true
        let hour = Calendar.current.component(.hour, from: now)
        let text = Self.request(weekday: now.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "ru_RU"))),
                                period: Self.periodName(PhraseBatch.period(hour: hour)))
        Task {
            defer { running = false }
            do {
                let reply = try await brain.oneOff(instructions: Persona.character, text: text, schema: JSON(any: PhraseBatch.schema))
                guard let batch = PhraseBatch.parse(reply, day: today) else { return log("phrases: unusable batch") }
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(batch).write(to: file, options: .atomic)
                if enabled() { Lines.batch = batch }
                let count = batch.lines.values.flatMap(\.values).map(\.count).reduce(0, +)
                log("phrases: \(count) lines, \(batch.ideas.values.map(\.count).reduce(0, +)) ideas for \(today)")
            } catch {
                log("phrases: batch failed (\(error))")
            }
        }
    }

    func shutdown() { timer?.invalidate(); timer = nil }

    private static func periodName(_ p: PhraseBatch.Period) -> String {
        switch p {
        case .morning: "утро"
        case .day: "день"
        case .evening: "вечер"
        case .night: "ночь"
        }
    }

    /// Weekday and time of day only — nothing about the user's activity, apps or files (В24).
    static func request(weekday: String, period: String) -> String {
        """
        Напиши свежие реплики Чилка на сегодня, сейчас \(weekday), \(period). Ответ — JSON по схеме.
        lines: для каждой потребности — water (вода), stretch (размяться), eyes (дать глазам отдохнуть), \
        walk (прогулка), endOfDay (закончить рабочий день) — по 3 фразы polite (первая просьба, мягко, с лёгкой \
        подколкой) и по 3 фразы insist (он просит уже не первый раз: наглее, но по-доброму).
        ideas: что сделать вне экрана за 5–15 минут, по 3 на morning, day, evening, night; конкретно и выполнимо, \
        без погоды и без покупок.
        Каждая фраза — одна строка до 90 знаков, на «ты», без эмодзи, кавычек и ссылок. Фразы lines покажутся в \
        любое время дня: не упоминай утро, день, вечер или ночь. Не про внешность, вес и \
        здоровье, без стыжения и токсичной продуктивности. Не повторяй: «Тук-тук, это вода», «Прогулка сама себя \
        не прогуляет», «Ноутбук тоже хочет спать».
        """
    }
}
