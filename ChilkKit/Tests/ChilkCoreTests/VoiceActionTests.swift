import Foundation
import Testing
@testable import ChilkCore

@Suite("Voice action boundaries")
@MainActor
struct VoiceActionTests {
    enum WriteFailure: Error { case denied }

    @Test func aFailedWaterWriteDoesNotCreditTheNeedInMemory() throws {
        let e = BalanceEngine()
        e.makeDue(.water)
        let before = e.state
        #expect(throws: WriteFailure.denied) {
            try e.tookRest(.water, persisting: { _ in throw WriteFailure.denied })
        }
        #expect(e.state == before)
        var persisted: BalanceState?
        let events = try e.tookRest(.water, persisting: { persisted = $0 })
        #expect(!events.isEmpty)
        #expect(persisted == e.state)
        #expect(e.pressure(.water) == 0)
    }

    @Test func minimalContextIncludesTheFullDateAndTimezone() {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let zone = TimeZone(secondsFromGMT: 3 * 3600)!
        let text = VoiceContext.text(sittingMinutes: 12, now: fixed, zone: zone)
        #expect(text.contains("2023-11-15T01:13:20+03:00"))
        #expect(text.contains(zone.identifier))
        #expect(text.contains("12 мин"))
    }
}
