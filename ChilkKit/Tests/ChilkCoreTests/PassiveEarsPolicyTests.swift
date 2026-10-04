import ChilkCore
import Testing

@Suite("Passive ears policy")
struct PassiveEarsPolicyTests {
    @Test func modelReadinessDoesNotOverrideConversationPause() {
        var policy = PassiveEarsPolicy()
        #expect(policy.allowed)
        policy.pause()
        #expect(!policy.allowed) // even if the model finishes loading now
        policy.conversationEnded()
        #expect(policy.allowed)
    }

    @Test func conversationEndDoesNotSilentlyRetryAnAudioFailure() {
        var policy = PassiveEarsPolicy()
        policy.pause()
        policy.fail()
        policy.conversationEnded()
        #expect(!policy.allowed)
        policy.retry()
        #expect(policy.allowed)
    }

    @Test func aManualRetryDoesNotOpenEarsInTheMiddleOfAConversation() {
        var policy = PassiveEarsPolicy()
        policy.pause()
        policy.fail()
        policy.retry()
        #expect(!policy.allowed)
        policy.conversationEnded()
        #expect(policy.allowed)
    }
}
