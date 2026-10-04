import ChilkCore
import Testing

@Suite("Wake audio gate")
struct WakeAudioGateTests {
    @Test func silenceCostsNoRecognitionAndTheFirstPhraseIncludesPreroll() {
        var gate = WakeAudioGate(sampleRate: 10, preRoll: 0.6, pause: 0.3, maxPhrase: 5, capacity: 12)
        for _ in 0..<20 { #expect(gate.append([0], speech: false) == nil) }
        for _ in 0..<5 { #expect(gate.append([1], speech: true) == nil) }
        #expect(gate.append([0], speech: false) == nil)
        #expect(gate.append([0], speech: false) == nil)
        let clip = gate.append([0], speech: false)
        #expect(clip == Array(repeating: Float(0), count: 6) + Array(repeating: Float(1), count: 5) + [0, 0, 0])
        #expect(gate.isChecking)
    }
}
