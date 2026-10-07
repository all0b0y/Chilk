import ChilkCore
import Foundation

/// Slice 7a (decision 32): a request as the notebook sees it.
struct GameRequest: Equatable {
    let need: Need
    let stage: Int
    let buttons: [Reaction]
}

/// Slice 7a: the notebook's words.
enum GameLines {
    static var ticTacToe: String { String(localized: "Крестики-нолики") }
    static var howMany: String { String(localized: "Сколько партий?") }
    static var start: String { String(localized: "Начать") }
    static var again: String { String(localized: "Ещё матч") }
    static var enough: String { String(localized: "Хватит") }
    static var yourMove: String { String(localized: "Твой ход — ты крестики") }
    static var chilkThinks: String { String(localized: "Чилк думает…") }
    static var youWonGame: String { String(localized: "Твоя партия!") }
    static var chilkWonGame: String { String(localized: "Партия Чилка") }
    static var drawGame: String { String(localized: "Ничья") }
    static var youWonMatch: String { String(localized: "Ты выиграл матч!") }
    static var chilkWonMatch: String { String(localized: "Чилк выиграл матч") }
    static var drawMatch: String { String(localized: "Ничья в матче") }

    static func score(you: Int, chilk: Int, game: Int, of length: Int) -> String {
        String(localized: "Ты \(you) : \(chilk) Чилк · партия \(game) из \(length)")
    }

    static func finalScore(you: Int, chilk: Int) -> String {
        String(localized: "Ты \(you) : \(chilk) Чилк")
    }

    /// Why not now (decision 26) — said by Chilk, also the tool's hint.
    static func refusal(_ r: GameRefusal) -> String {
        switch r {
        case .exhausted: String(localized: "Сначала помоги мне… потом поиграем")
        case .topStage: String(localized: "Сейчас не до игр — сначала перерыв")
        case .exercise: String(localized: "Доделаем упражнение — потом поиграем")
        case .notReady: String(localized: "В это я ещё не умею")
        }
    }

    static func name(_ kind: GameKind) -> String {
        switch kind {
        case .ticTacToe: String(localized: "Крестики-нолики")
        case .basketball: String(localized: "Баскетбол")
        case .battleship: String(localized: "Морской бой")
        case .checkers: String(localized: "Шашки")
        }
    }

    /// Decision 32: between games a waiting request comes first.
    static func firstThenRematch(_ n: Need) -> String {
        switch n {
        case .water: String(localized: "Сначала попей — потом реванш")
        case .stretch: String(localized: "Сначала разомнись — потом реванш")
        case .eyes: String(localized: "Сначала дай глазам отдых — потом реванш")
        case .walk: String(localized: "Сначала прогуляйся — потом реванш")
        case .endOfDay: String(localized: "Сначала закончим день — потом реванш")
        }
    }

    static func resume(you: Int, chilk: Int) -> String { String(localized: "Доиграем? Счёт \(you) : \(chilk)") }
    static func resumeNote(_ score: String) -> String { String(localized: "Доиграть: \(score)") }
    static var resumeYes: String { String(localized: "Доиграем") }
    static var resumeLater: String { String(localized: "Потом") }

    static var busy: String { String(localized: "Сейчас занят — давай чуть позже") }

    // Slice 7c: battleship.
    static var yourSea: String { String(localized: "Твоё море") }
    static var hisSea: String { String(localized: "Море Чилка") }
    static var placeShips: String { String(localized: "Расставь корабли: тащи, клик — повернуть") }
    static var shuffle: String { String(localized: "Случайно") }
    static var toBattle: String { String(localized: "В бой!") }
    // Slice 7d: draughts.
    static var yourMoveDraughts: String { String(localized: "Твой ход — ты синие, снизу") }
    static var mustTake: String { String(localized: "Бить обязательно!") }
    static var doesNotFit: String { String(localized: "Так не встанет: корабли не касаются даже углами") }
    static var fireAtHim: String { String(localized: "Твой выстрел — по морю Чилка") }

    /// What a shot did, on the status line.
    static func shot(_ r: ShotResult, byYou: Bool) -> String {
        switch (r, byYou) {
        case (.miss, true): String(localized: "Мимо. Ход Чилка")
        case (.hit, true): String(localized: "Ранил! Стреляй ещё")
        case (.sunk, true): String(localized: "Потопил! Стреляй ещё")
        case (.miss, false): String(localized: "Чилк промахнулся — твой ход")
        case (.hit, false): String(localized: "Чилк ранил твой корабль")
        case (.sunk, false): String(localized: "Чилк потопил твой корабль")
        case (.wasted, _): ""
        }
    }
}

/// Slice 7b: basketball's words (decisions 27–28, 32).
enum CourtLines {
    static var willIScore: String { String(localized: "Попаду?") }
    static var hit: String { String(localized: "Попадёт") }
    static var miss: String { String(localized: "Мимо") }
    static var throwsLabel: String { String(localized: "Бросков:") }
    static var guessIt: String { String(localized: "Попадёт или мимо?") }
    static var guessed: String { String(localized: "Угадал!") }
    static var notGuessed: String { String(localized: "Не угадал") }
    static var highFive: String { String(localized: "Пять!") }
    static var putAway: String { String(localized: "Ладно, мяч убрал") }
    static var goOn: String { String(localized: "Продолжить") }
    static var notDuringCall: String { String(localized: "У тебя созвон — сыграем после") }

    static func score(you: Int, chilk: Int, shot: Int, of length: Int) -> String {
        String(localized: "Ты \(you) : \(chilk) Чилк · бросок \(shot) из \(length)")
    }

    static func goOnAfterCall(you: Int, chilk: Int) -> String {
        String(localized: "Ну что, продолжаем? Счёт \(you) : \(chilk)")
    }

    /// Decision 32: a call — the only exception from his tact; a line from the day's Codex batch now and then.
    static var shush: [String] {
        [String(localized: "Ой, у тебя созвон — сори, сворачиваюсь 🤫"), String(localized: "Всё-всё, меня тут нет"),
         String(localized: "Доброшу потом. Тсс!"), String(localized: "Кольцо унёс, не палимся")]
    }
}
