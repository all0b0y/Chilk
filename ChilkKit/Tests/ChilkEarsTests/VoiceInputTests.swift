import ChilkCore
@testable import ChilkEars
import Testing

@Suite("Shared voice input")
@MainActor
struct VoiceInputTests {
    @Test func recognizerGetsPrerollOnlyOnce() async {
        let pending = PendingRecognition()
        let input = VoiceInput(recognize: { samples in
            #expect(samples.firstIndex(where: { $0 != 0 }) == 11_200)
            return await pending.wait()
        })
        input.arm {}
        input.feed(Array(repeating: 0, count: 11_200), speech: false)
        input.feed(Array(repeating: 0.1, count: 8_000), speech: true)
        input.feed(Array(repeating: 0, count: 9_600), speech: false)
        await pending.waitUntilStarted()
        await pending.complete("ordinary speech")
        for _ in 0..<100 { if !input.isChecking { break }; await Task.yield() }
        #expect(!input.isChecking)
        input.suspend()
    }

    @Test func aHotkeyNeverReplaysAmbientAudio() throws {
        let input = VoiceInput(recognize: { _ in "" })
        input.arm {}
        input.feed(Array(repeating: 0.2, count: 100), speech: false)
        try input.prepareDictation(replayWake: false)
        var delivered: [Float] = []
        try input.attach { delivered += $0 }
        #expect(delivered.isEmpty)
        input.suspend()
    }

    @Test func aHotkeyDiscardsOldQueuedMicrophonePackets() throws {
        let input = VoiceInput(recognize: { _ in "" })
        try input.prepareDictation(replayWake: false, at: 10)
        input.feed([0.1, 0.2], capturedAt: 9)
        input.feed([0.3], capturedAt: 10)
        var delivered: [Float] = []
        try input.attach { delivered += $0 }
        input.feed([0.4], capturedAt: 9)
        input.feed([0.5], capturedAt: 11)
        #expect(delivered == [0.3, 0.5])
        input.suspend()
    }

    @Test func aHotkeyKeepsThePartOfAPacketAfterThePress() throws {
        let input = VoiceInput(recognize: { _ in "" })
        try input.prepareDictation(replayWake: false, at: 0.01)
        input.feed((0..<320).map { Float($0) }, capturedAt: 0)
        var delivered: [Float] = []
        try input.attach { delivered += $0 }
        #expect(delivered == (160..<320).map { Float($0) })
        input.suspend()
    }

    @Test func switchingOffDiscardsALateWakeResult() async {
        let pending = PendingRecognition()
        let input = VoiceInput(recognize: { _ in await pending.wait() })
        var woke = false
        input.arm { woke = true }
        input.feed(Array(repeating: 0.1, count: 8_000), speech: true)
        input.feed(Array(repeating: 0, count: 9_600), speech: false)
        await pending.waitUntilStarted()
        input.suspend()
        await pending.complete("Чилк")
        for _ in 0..<100 { await Task.yield() }
        #expect(!woke)
        #expect(input.mode == .suspended)
    }

    @Test func aPreparationOverrunDoesNotDeliverAHalfRequest() throws {
        let input = VoiceInput(recognize: { _ in "" })
        try input.prepareDictation(replayWake: false)
        input.feed(Array(repeating: 0.1, count: 16_000 * 13))
        var delivered: [Float] = []
        #expect(throws: VoiceInput.InputError.self) { try input.attach { delivered += $0 } }
        #expect(delivered.isEmpty)
    }

    @Test func wakeKeepsSpeechDuringRecognitionAndPreparationInOrder() async throws {
        let pending = PendingRecognition()
        let input = VoiceInput(recognize: { _ in await pending.wait() })
        var woke = false
        input.arm { woke = true }
        input.feed(Array(repeating: 0, count: 9_600), speech: false)
        input.feed(Array(repeating: 0.1, count: 8_000), speech: true)
        input.feed(Array(repeating: 0, count: 9_600), speech: false)
        await pending.waitUntilStarted()
        input.feed(Array(repeating: 0.2, count: 3_200), speech: true)
        await pending.complete("Чилк, найди файл")
        for _ in 0..<100 { if woke { break }; await Task.yield() }
        #expect(woke)
        try input.prepareDictation(replayWake: true)
        input.feed(Array(repeating: 0.3, count: 1_600), speech: true)
        var delivered: [Float] = []
        try input.attach { delivered += $0 }
        var expected = Array(repeating: Float(0), count: 9_600)
        expected += Array(repeating: Float(0.1), count: 8_000)
        expected += Array(repeating: Float(0), count: 9_600)
        expected += Array(repeating: Float(0.2), count: 3_200)
        expected += Array(repeating: Float(0.3), count: 1_600)
        #expect(delivered == expected)
        input.feed([0.4, 0.5], speech: true)
        #expect(Array(delivered.suffix(2)) == [0.4, 0.5])
        input.suspend()
    }
}

actor PendingRecognition {
    private var continuation: CheckedContinuation<String, Never>?
    private var started = false
    func wait() async -> String {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
    func complete(_ text: String) { continuation?.resume(returning: text); continuation = nil }
}
