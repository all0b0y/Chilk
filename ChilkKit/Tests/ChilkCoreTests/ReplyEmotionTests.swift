import ChilkCore
import Foundation
import Testing

@Suite("The answer's emotion field (slice 9e, decision 33)")
struct ReplyEmotionTests {
    @Test func theSchemaRequiresTheEmotionWithEveryValue() {
        let s = Dialogue.schema
        let props = s["properties"] as? [String: Any]
        let emotion = props?["emotion"] as? [String: Any]
        #expect((emotion?["enum"] as? [String]) == ReplyEmotion.allCases.map(\.rawValue))
        #expect((s["required"] as? [String])?.contains("emotion") == true)
        #expect(ReplyEmotion.allCases.map(\.rawValue).contains("none"))
    }

    @Test func theFieldIsReadAndMapped() {
        #expect(Dialogue.emotion(#"{"reply":"Ха!","mode":"answer","emotion":"laugh_hard"}"#) == .laughHard)
        #expect(ReplyEmotion.laughHard.play?.emotion == .laugh && ReplyEmotion.laughHard.play?.strong == true)
        #expect(ReplyEmotion.shy.play?.emotion == .shy && ReplyEmotion.shy.play?.strong == false)
        #expect(ReplyEmotion.none.play == nil)
        #expect(Dialogue.emotion(#"{"reply":"Ок","mode":"answer","emotion":"jump"}"#) == .none)   // unknown: none
        #expect(Dialogue.emotion("Просто текст") == .none)                                       // no schema: none
        #expect(Dialogue.parse(#"{"reply":"Ок","mode":"done","emotion":"cheer"}"#).mode == .done)
    }

    @Test func everyPlayableValueIsAnEmotionHeCanShow() {
        for r in ReplyEmotion.allCases where r != .none && r != .laughHard {
            #expect(r.play?.emotion.rawValue == r.rawValue)
        }
        #expect(Set(ReplyEmotion.allCases.compactMap { $0.play?.emotion }) == Set(Emotion.allCases))
    }
}
