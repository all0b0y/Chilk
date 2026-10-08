import Foundation
import Testing
@testable import ChilkCore

// Slice 9f (SPEC «Срез 9», decisions 36–38): the Codex model and the answer depth in settings.json.

@Suite("Brain choice (slice 9f)")
struct BrainChoiceTests {
    @Test func neverChosenIsGPT6LunaAtLow() {
        let c = BrainChoice()
        #expect(c.model == nil && c.modelID == "gpt-6-luna" && c.displayName == "GPT-6-Luna")
        #expect(c.depth == .low)
        #expect(BrainChoice.backgroundDepth == .low)                  // decision 38: the background is always «Быстро»
    }

    @Test func aChoiceSurvivesTheRoundTrip() throws {
        var s = AppSettings()
        s.brain = BrainChoice(model: "gpt-6-sol", modelName: "GPT-6-Sol", depth: .medium)
        s.launchAtLogin = true
        let back = try JSONDecoder().decode(AppSettings.self, from: try JSONEncoder().encode(s))
        #expect(back == s)
        #expect(back.brain.modelID == "gpt-6-sol" && back.brain.depth == .medium)
    }

    @Test func aFileFromBeforeTheSliceGetsTheDefaultsAndReEncodesUnchanged() throws {
        // settings.json as slice 9a wrote it: no «brain» key.
        let old = #"{"apps":{"overrides":{},"recent":["com.apple.Safari"],"music":[]},"hotkey":{"keyCode":49,"modifiers":6144,"label":"⌃⌥Space"},"screen":{"follow":{}},"launchAtLogin":true}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        #expect(s.brain == BrainChoice())
        #expect(s.apps.recent == ["com.apple.Safari"] && s.launchAtLogin == true)
        // Re-encoded it has no «brain» either: the store's lossy check does not copy the file aside.
        let again = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(s)) as? [String: Any]
        #expect(again?["brain"] == nil)
        let before = try JSONSerialization.jsonObject(with: Data(old.utf8)) as? NSDictionary
        #expect(before == (again.map { $0 as NSDictionary }))
    }

    @Test func aDamagedBrainLosesOnlyItsOwnFields() throws {
        let json = #"{"brain":{"model":"gpt-5.6-terra","depth":"ultra"},"hotkey":"junk"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.brain.modelID == "gpt-5.6-terra")
        #expect(s.brain.depth == .low)                                 // «ultra» is never Chilk's depth
        #expect(s.brain.displayName == "gpt-5.6-terra")                // no saved name: the id
        let junk = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"brain":"junk"}"#.utf8))
        #expect(junk.brain == BrainChoice())
        let blank = try JSONDecoder().decode(BrainChoice.self, from: Data(#"{"model":"  ","depth":"high"}"#.utf8))
        #expect(blank.model == nil && blank.modelID == "gpt-6-luna" && blank.depth == .high)
    }

    @Test func onlyQuickMediumAndThoughtfulAreOffered() {
        #expect(AnswerDepth.offered(["low", "medium", "high", "xhigh", "max", "ultra"]) == [.low, .medium, .high])
        #expect(AnswerDepth.offered(["medium", "xhigh"]) == [.medium])
        #expect(AnswerDepth.offered(["max"]).isEmpty)
    }

    @Test func pickingAModelKeepsTheDepthItSupports() {
        let c = BrainChoice(depth: .high)
        let sol = c.choosing(model: "gpt-6-sol", name: "GPT-6-Sol", supported: ["low", "medium", "high", "xhigh"])
        #expect(sol == BrainChoice(model: "gpt-6-sol", modelName: "GPT-6-Sol", depth: .high))
        let narrow = c.choosing(model: "tiny", name: "Tiny", supported: ["medium", "xhigh"])
        #expect(narrow.depth == .medium)                               // «Вдумчиво» is not there: the first offered
        let unknown = c.choosing(model: "odd", name: "Odd", supported: [])
        #expect(unknown.depth == .high)                                // nothing known: the choice stays
    }

    @Test func aMissingModelIsNeverReplacedByAnother() {
        let c = BrainChoice(model: "gpt-9-gone")
        #expect(c.isAvailable(in: ["gpt-6-luna", "gpt-6-sol"]) == false)
        #expect(c.isAvailable(in: nil) == nil)                         // Codex away: unknown, not «missing»
        #expect(BrainChoice().isAvailable(in: ["gpt-6-luna"]) == true)
        #expect(c.modelID == "gpt-9-gone")                             // still asked for as chosen
    }

    // MARK: 9f review

    @Test func anEmptyListIsUnknownNotMissing() {
        // Codex answers `data: []` before its catalog is loaded (or signed out): never «модель недоступна».
        #expect(BrainChoice(model: "gpt-6-sol").isAvailable(in: []) == nil)
        #expect(BrainChoice().isAvailable(in: []) == nil)
    }

    @Test func aDepthTheModelLacksGoesAsTheFirstOffered() {
        let high = BrainChoice(model: "gpt-6-luna", depth: .high)
        #expect(high.effectiveDepth(supported: ["low", "medium", "xhigh"]) == .low)       // «Вдумчиво» is gone: «Быстро»
        #expect(high.effectiveDepth(supported: ["low", "medium", "high"]) == .high)
        #expect(high.effectiveDepth(supported: nil) == .high)                              // the list is unknown
        #expect(high.effectiveDepth(supported: ["max"]) == .high)                          // none of the three: as chosen
        #expect(BrainChoice(depth: .medium).effectiveDepth(supported: ["medium", "high"]) == .medium)
    }

    private static let luna = BrainChoice()
    private static let lunaMedium = BrainChoice(depth: .medium)
    private static let sol = BrainChoice(model: "gpt-6-sol", modelName: "GPT-6-Sol")

    @Test func aDepthOnlyChangeKeepsTheLiveThreadAndTheSpare() {
        var p = BrainThreadPolicy()
        #expect(p.choiceChanged(from: Self.luna, to: Self.lunaMedium, busy: false)
                == .init(live: .setDepth(.medium), rewarmSpare: false))
        #expect(p.pending == .keep)
        #expect(p.choiceChanged(from: Self.luna, to: Self.luna, busy: false) == .init(live: .keep, rewarmSpare: false))
    }

    @Test func aModelChangeDropsTheLiveThreadAndReWarmsTheSpare() {
        var p = BrainThreadPolicy()
        #expect(p.choiceChanged(from: Self.luna, to: Self.sol, busy: false) == .init(live: .drop, rewarmSpare: true))
        #expect(p.conversationEnded(busy: false) == .keep)                               // nothing was waiting
    }

    @Test func duringAConversationTheLiveThreadWaitsForItsEnd() {
        var p = BrainThreadPolicy()
        // The spare is not live: a new model re-warms it at once; the live thread stays until the conversation ends.
        #expect(p.choiceChanged(from: Self.luna, to: Self.sol, busy: true) == .init(live: .keep, rewarmSpare: true))
        // A depth picked afterwards does not undo the model change.
        #expect(p.choiceChanged(from: Self.sol, to: BrainChoice(model: "gpt-6-sol", depth: .high), busy: true)
                == .init(live: .keep, rewarmSpare: false))
        #expect(p.conversationEnded(busy: true) == .keep)                                // a chat turn still runs
        #expect(p.conversationEnded(busy: false) == .drop)
        #expect(p.conversationEnded(busy: false) == .keep)                               // only once
    }

    @Test func aDepthPickedDuringAConversationReachesTheLiveThreadAtItsEnd() {
        var p = BrainThreadPolicy()
        #expect(p.choiceChanged(from: Self.luna, to: Self.lunaMedium, busy: true) == .init(live: .keep, rewarmSpare: false))
        #expect(p.choiceChanged(from: Self.lunaMedium, to: BrainChoice(depth: .high), busy: true).live == .keep)
        #expect(p.conversationEnded(busy: false) == .setDepth(.high))                    // the last one wins
        // A change after the end, once nothing is busy, applies at once — even with a leftover from a reconnect.
        p.reset()
        #expect(p.choiceChanged(from: Self.lunaMedium, to: Self.luna, busy: false).live == .setDepth(.low))
    }
}
