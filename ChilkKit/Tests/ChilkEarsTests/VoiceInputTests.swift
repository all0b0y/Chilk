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

    /// Decision 2026-10-05 (MVP): the request starts with what Whisper heard after the name; Apple gets only what
    /// was said after the checked clip (during recognition and preparation), in order, then the live microphone.
    @Test func aWakeUsesTheCheckedTextAndKeepsSpeechAfterTheClipInOrder() async throws {
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
        #expect(try input.prepareDictation(replayWake: true) == WakeHeard(request: "найди файл", amidSpeech: false))
        input.feed(Array(repeating: 0.3, count: 1_600), speech: true)
        var delivered: [Float] = []
        try input.attach { delivered += $0 }
        #expect(runs(delivered) == ["0.2×3200", "0.3×1600"])
        input.feed([0.4, 0.5], speech: true)
        #expect(Array(delivered.suffix(2)) == [0.4, 0.5])
        input.suspend()
    }

    /// A call amid continuous speech (a TV) is marked, so the conversation does not open follow-up windows into it.
    @Test func aWakeInContinuousSpeechIsMarkedAmidSpeech() async throws {
        let input = VoiceInput(recognize: { $0.contains(0.3) ? "Чилк, поставь таймер" : "ordinary speech" },
                               gate: WakeAudioGate(continuous: true))
        var woke = false
        input.arm { woke = true }
        input.feed(Array(repeating: 0, count: 9_600), speech: false)
        input.feed(Array(repeating: 0.1, count: 80_000), speech: true)             // 5 s → first check
        input.feed(Array(repeating: 0.2, count: 16_000), speech: true)             // the TV goes on during it
        await until { !input.isChecking }
        input.feed(Array(repeating: 0.3, count: 64_000), speech: true)             // «Чилк, поставь таймер» → next check
        input.feed(Array(repeating: 0.4, count: 3_200), speech: true)              // arrives during that check
        await until { woke }
        #expect(woke)
        #expect(try input.prepareDictation(replayWake: true) == WakeHeard(request: "поставь таймер", amidSpeech: true))
        input.feed(Array(repeating: 0.5, count: 1_600), speech: true)
        var delivered: [Float] = []
        try input.attach { delivered += $0 }
        #expect(runs(delivered) == ["0.4×3200", "0.5×1600"])
        input.suspend()
    }

    @Test func aWakeSoonAfterOtherSpeechIsMarkedAmidSpeech() async throws {
        let input = VoiceInput(recognize: { $0.contains(0.3) ? "Эй, Чилк" : "ordinary speech" })
        var woke = false
        input.arm { woke = true }
        input.feed(Array(repeating: 0.1, count: 8_000), speech: true)              // the TV says something…
        input.feed(Array(repeating: 0, count: 9_600), speech: false)
        await until { !input.isChecking }
        input.feed(Array(repeating: 0.3, count: 8_000), speech: true)              // …and right after: «Эй, Чилк»
        input.feed(Array(repeating: 0, count: 9_600), speech: false)
        await until { woke }
        #expect(try input.prepareDictation(replayWake: true) == WakeHeard(request: "", amidSpeech: true))
        input.suspend()
    }

    /// Waits for the main-actor check task (parallel test load can delay it well beyond a few yields).
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// «0.4×3200»: a readable failure instead of thousands of samples.
    private func runs(_ samples: [Float]) -> [String] {
        var out: [(Float, Int)] = []
        for s in samples { if out.last?.0 == s { out[out.count - 1].1 += 1 } else { out.append((s, 1)) } }
        return out.map { "\($0.0)×\($0.1)" }
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
