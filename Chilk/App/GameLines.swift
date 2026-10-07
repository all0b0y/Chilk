import ChilkCore
import Foundation

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

    static var busy: String { String(localized: "Сейчас занят — давай чуть позже") }
}
