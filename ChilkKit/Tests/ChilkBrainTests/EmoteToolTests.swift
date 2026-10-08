import Foundation
import Testing
import ChilkCore
@testable import ChilkBrain

// Slice 6c (decisions 11–12): `chilk_emote` — Chilk's own reaction, at Codex's discretion.

struct EmoteToolTests {
    /// Slice 9e (decision 33): the emotion is a field of every answer now — the tool is gone from the catalog.
    @Test func theToolIsGoneTheAnswerFieldReplacesIt() {
        #expect(!ChilkToolCatalog.tools.contains { $0.name == "chilk_emote" })
    }

    @Test func parsingTakesOneOfTheSixAndStrong() throws {
        #expect(try ChilkToolCatalog.parse(name: "chilk_emote", arguments: ["emotion": "laugh", "strong": true])
                == .emote(.laugh, strong: true))
        #expect(try ChilkToolCatalog.parse(name: "chilk_emote", arguments: ["emotion": "clown", "strong": false])
                == .emote(.clown, strong: false))
        for bad: JSON in [["emotion": "sleep", "strong": false], ["emotion": "laugh"], ["emotion": "laugh", "strong": "yes"],
                          ["emotion": "laugh", "strong": false, "extra": 1], [:]] {
            #expect(throws: ChilkToolCatalog.ToolError.self) { try ChilkToolCatalog.parse(name: "chilk_emote", arguments: bad) }
        }
    }

    @Test func noChipInTheChat() {
        for result in [CodexToolResult.ok(["played": true]), .failure("not_now")] {
            #expect(ChatChips.chip(name: "chilk_emote", arguments: ["emotion": "laugh", "strong": false], result: result) == nil)
        }
    }
}
