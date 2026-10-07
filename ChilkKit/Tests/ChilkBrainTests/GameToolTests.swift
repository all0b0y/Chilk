import Foundation
import Testing
import ChilkCore
@testable import ChilkBrain

// Slice 7a (SPEC decision 26): «давай поиграем» / «давай в крестики до пяти» by voice or chat — `chilk_game`.

@MainActor
struct GameToolTests {
    @Test func theToolIsAlwaysThereAndParsesAGameAndALength() throws {
        var off = ToolSwitches()
        for a in ChilkAbility.allCases { off.set(a, on: false) }
        #expect(ChilkToolCatalog.tools(for: off).contains { $0.name == "chilk_game" })
        #expect(try ChilkToolCatalog.parse(name: "chilk_game", arguments: ["game": "any", "length": 0])
                == .game(nil, length: nil))
        #expect(try ChilkToolCatalog.parse(name: "chilk_game", arguments: ["game": "tictactoe", "length": 5])
                == .game(.ticTacToe, length: 5))
        // A game of a later sub-slice parses: the app refuses it with not_ready and Codex offers a ready one.
        #expect(try ChilkToolCatalog.parse(name: "chilk_game", arguments: ["game": "checkers", "length": 0])
                == .game(.checkers, length: nil))
        let bad: [JSON] = [[:], ["game": "chess", "length": 0], ["game": "any", "length": 7], ["game": "any", "length": .number(2.5)],
                           ["game": "any", "length": -1], ["game": "any"], ["game": "any", "length": 1, "now": true]]
        for bad in bad {
            #expect(throws: ChilkToolCatalog.ToolError.self) { try ChilkToolCatalog.parse(name: "chilk_game", arguments: bad) }
        }
    }

    @Test func theSchemaOffersOnlyReadyGamesAndAny() throws {
        let tool = try #require(ChilkToolCatalog.tools.first { $0.name == "chilk_game" })
        let games = tool.inputSchema["properties"]?["game"]?["enum"]
        #expect(games == .array([.string("any")] + GameKind.ready.map { .string($0.rawValue) }))
    }

    @Test func theExecutorHandsItToTheApp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("game-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var asked: [String] = []
        let executor = try ChilkToolExecutor(file: dir.appendingPathComponent("timers.json"), game: { kind, length in
            asked.append("\(kind?.rawValue ?? "any") \(length ?? 0)")
            return .ok(["game": "tictactoe", "name": "Крестики-нолики"])
        })
        let r = executor.execute(name: "chilk_game", arguments: ["game": "any", "length": 3])
        #expect(r.success && r.value["game"]?.string == "tictactoe")
        #expect(asked == ["any 3"])
    }

    @Test func aChipSaysWhichGameOrThatItWasRefused() {
        let played = ChatChips.chip(name: "chilk_game", arguments: ["game": "any", "length": 0],
                                    result: .ok(["game": "tictactoe", "name": "Крестики-нолики"]))
        #expect(played?.kind == .game && played?.subject == "tictactoe" && played?.failed == false)
        let refused = ChatChips.chip(name: "chilk_game", arguments: ["game": "tictactoe", "length": 0],
                                     result: .failure("top_stage: a break first"))
        #expect(refused?.kind == .game && refused?.failed == true)
    }
}
