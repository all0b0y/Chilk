import ChilkCore
import Testing

/// Decision 2026-10-05: a failed microphone restarts by itself (2 / 10 / 60 s), then Chilk says so.
@Suite("Ears recovery")
struct EarsRecoveryTests {
    @Test func threeQuietRestartsThenGiveUp() {
        var r = EarsRecovery()
        #expect(r.failed(at: 0) == .retry(after: 2))
        r.started(at: 2)
        #expect(r.failed(at: 3) == .retry(after: 10))              // came back and broke again at once
        #expect(r.failed(at: 13) == .retry(after: 60))             // did not even start
        #expect(r.failed(at: 73) == .giveUp)
        #expect(r.failed(at: 200) == .giveUp)                      // stays given up until the user acts
        r.reset()
        #expect(r.failed(at: 300) == .retry(after: 2))
    }

    @Test func aMicrophoneThatWorkedForAWhileIsAFreshIncident() {
        var r = EarsRecovery()
        _ = r.failed(at: 0)
        _ = r.failed(at: 2)
        r.started(at: 12)
        #expect(r.failed(at: 12 + EarsRecovery.healthyAfter) == .retry(after: 2))
        #expect(r.attempts == 1)
    }
}
