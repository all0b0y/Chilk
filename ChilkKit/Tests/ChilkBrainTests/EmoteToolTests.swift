import Foundation
import Testing
import ChilkCore
@testable import ChilkBrain

// Slice 6c (decisions 11–12): `chilk_emote` — Chilk's own reaction, at Codex's discretion.

struct EmoteToolTests {
    @Test func theToolIsAlwaysThereWhateverIsSwitchedOff() {
        var off = ToolSwitches()
        for a in ChilkAbility.allCases { off.set(a, on: false) }
        #expect(ChilkToolCatalog.tools(for: off).contains { $0.name == "chilk_emote" })
        let tool = ChilkToolCatalog.tools.first { $0.name == "chilk_emote" }!
        // Only the six emotions: needs and states (tired, eye bags, hops, lying, sleep) are not offered.
        let names = tool.inputSchema["properties"]?["emotion"]?["enum"]
        #expect(names == .array(Emotion.allCases.map { .string($0.rawValue) }))
        #expect(tool.description.contains("never in the user"))
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
