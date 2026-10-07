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

    /// Feeds `values` one sample per frame; returns the clips the gate asked to recognise.
    private func feed(_ gate: inout WakeAudioGate, _ values: [Float], speech: Bool) -> [[Float]] {
        values.compactMap { gate.append([$0], speech: speech) }
    }

    /// One phrase checked (clip of 2s), then speech goes on during recognition: values 3…
    private func phraseThenSpeechDuringCheck(continuous: Bool) -> (WakeAudioGate, [[Float]]) {
        var gate = WakeAudioGate(sampleRate: 10, preRoll: 0.2, pause: 0.3, maxPhrase: 1, capacity: 12, continuous: continuous)
        _ = feed(&gate, [0, 0, 0], speech: false)
        var clips = feed(&gate, [2, 2, 2, 2, 2, 2, 2, 2, 2, 2], speech: true)          // 1 s → maxPhrase → check
        clips += feed(&gate, [3, 3, 3, 3], speech: true)                               // arrives while recognising
        return (gate, clips)
    }

    @Test func todayContinuedSpeechWaitsForAPauseAndIsNeverChecked() {
        var (gate, clips) = phraseThenSpeechDuringCheck(continuous: false)
        #expect(clips.count == 1)
        gate.reject()
        clips = feed(&gate, [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4], speech: true)        // TV without a pause
        #expect(clips.isEmpty)
    }

    @Test func continuousModeChecksTheSpeechThatArrivedDuringRecognition() throws {
        var (gate, clips) = phraseThenSpeechDuringCheck(continuous: true)
        #expect(clips.count == 1)
        gate.reject()
        clips = feed(&gate, [4, 4, 4, 4, 4, 4, 4, 4, 4, 4], speech: true)
        let next = try #require(clips.first)
        // Overlaps the previous clip by the pre-roll (last 2 samples of «2»), then the speech that came after.
        #expect(Array(next.prefix(6)) == [2, 2, 3, 3, 3, 3])
        #expect(next.count == 2 + 10)                                                 // pre-roll + maxPhrase (1 s)
    }

    @Test func continuousModeChecksSpeechThatStartedAndEndedDuringRecognition() throws {
        var gate = WakeAudioGate(sampleRate: 10, preRoll: 0.2, pause: 0.3, maxPhrase: 5, capacity: 12, continuous: true)
        _ = feed(&gate, [0, 0, 0], speech: false)
        _ = feed(&gate, [2, 2, 2], speech: true)
        #expect(feed(&gate, [0, 0, 0], speech: false).count == 1)                     // first phrase → check
        _ = feed(&gate, [5, 5], speech: true)                                          // «Чилк» said during the check
        _ = feed(&gate, [0, 0, 0, 0], speech: false)                                   // …then a pause
        gate.reject()
        let clip = try #require(feed(&gate, [0], speech: false).first)
        #expect(clip.contains(5))
    }

    @Test func continuousModeStillWaitsQuietlyWhenNothingWasSaid() {
        var gate = WakeAudioGate(sampleRate: 10, preRoll: 0.2, pause: 0.3, maxPhrase: 5, capacity: 12, continuous: true)
        _ = feed(&gate, [2, 2, 2], speech: true)
        #expect(feed(&gate, [0, 0, 0], speech: false).count == 1)
        _ = feed(&gate, [0, 0, 0, 0], speech: false)
        gate.reject()
        #expect(feed(&gate, Array(repeating: 0, count: 50), speech: false).isEmpty)  // silence costs nothing
    }

    /// Decision 2026-10-05 (MVP): a wake from a window that continued someone else's speech is «noisy». Its request
    /// must not be re-dictated from the window start (seconds of background before the name).
    @Test func aContinuationClipIsMarkedAndItsReplayStartsAfterTheCheckedWindow() throws {
        var (gate, _) = phraseThenSpeechDuringCheck(continuous: true)
        #expect(!gate.lastClipContinuedSpeech)                                         // first phrase came after silence
        gate.reject()
        _ = try #require(feed(&gate, [4, 4, 4, 4, 4, 4], speech: true).first)
        #expect(gate.lastClipContinuedSpeech)
        _ = feed(&gate, [7, 7], speech: true)                                          // spoken during this check
        #expect(gate.replayAfterClip() == [7, 7])
        #expect(gate.replay()?.prefix(2) == [2, 2])                                    // the full replay still exists
    }

    /// Slice 8b (decision 2): the share of voice in the 10 s before the checked clip.
    @Test func theSpeechShareBeforeTheClipIsMeasured() {
        var gate = WakeAudioGate(sampleRate: 10, preRoll: 0.2, pause: 0.3, maxPhrase: 1, capacity: 12, continuous: true)
        _ = feed(&gate, Array(repeating: 1, count: 80), speech: true)                // 8 s of a TV (checks in between)
        while gate.isChecking { gate.reject(); _ = feed(&gate, [0], speech: false) }
        _ = feed(&gate, Array(repeating: 0, count: 5), speech: false)
        _ = feed(&gate, Array(repeating: 2, count: 10), speech: true)
        #expect(gate.isChecking && gate.lastClipSpeechShare > 0.5)
        var quiet = WakeAudioGate(sampleRate: 10, preRoll: 0.2, pause: 0.3, maxPhrase: 5, capacity: 12)
        _ = feed(&quiet, Array(repeating: 1, count: 10), speech: true)               // a few words
        _ = feed(&quiet, Array(repeating: 0, count: 3), speech: false)
        quiet.reject()
        _ = feed(&quiet, Array(repeating: 0, count: 20), speech: false)
        _ = feed(&quiet, Array(repeating: 2, count: 10), speech: true)
        _ = feed(&quiet, Array(repeating: 0, count: 3), speech: false)
        #expect(quiet.isChecking && quiet.lastClipSpeechShare < 0.5)              // 1 s of ~3 s armed: not a TV
    }

    /// Slice 8b (decision 17): early = the first short pause or 1.5 s; a miss goes on to the whole phrase.
    @Test func earlyChecksComeAtTheFirstShortPauseOrAfterOneAndAHalfSeconds() {
        var gate = WakeAudioGate(sampleRate: 10, preRoll: 0.2, pause: 0.6, maxPhrase: 5, capacity: 12, early: true)
        _ = feed(&gate, [0, 0], speech: false)
        #expect(feed(&gate, [1, 1, 1, 1, 1], speech: true).isEmpty)
        let clips = feed(&gate, [0, 0], speech: false)                              // 0.2 s pause
        #expect(clips.count == 1 && gate.lastClipWasEarly)
        gate.reject()
        #expect(feed(&gate, [2, 2, 2], speech: true).isEmpty)
        let again = feed(&gate, [0, 0], speech: false)                              // the second early look
        #expect(again.count == 1 && gate.lastClipWasEarly)
        #expect(again[0].count == 2 + 5 + 2 + 3 + 2)                               // from the phrase's pre-roll
        gate.reject()
        #expect(feed(&gate, [0, 0, 0, 0], speech: false).isEmpty)                  // over, nothing new: no third check
        _ = feed(&gate, [4, 4, 4, 4], speech: true)                                 // a new phrase
        #expect(feed(&gate, [0, 0], speech: false).count == 1)
        gate.reject()
        _ = feed(&gate, [5, 5, 5, 5], speech: true)
        #expect(feed(&gate, [0, 0], speech: false).count == 1 && gate.lastClipWasEarly)   // second look
        gate.reject()
        _ = feed(&gate, [6, 6, 6], speech: true)
        let whole = feed(&gate, [0, 0, 0, 0, 0, 0], speech: false)                  // early looks used → whole phrase
        #expect(whole.count == 1 && !gate.lastClipWasEarly)
        #expect(whole[0].count == 2 + 4 + 2 + 4 + 2 + 3 + 6)
        var long = WakeAudioGate(sampleRate: 10, preRoll: 0.2, pause: 0.6, maxPhrase: 5, capacity: 12, early: true)
        _ = feed(&long, [0, 0], speech: false)
        let early = feed(&long, Array(repeating: 1, count: 15), speech: true)       // 1.5 s without a pause
        #expect(early.count == 1 && long.lastClipWasEarly)
        var second = WakeAudioGate(sampleRate: 10, preRoll: 0.2, pause: 0.6, maxPhrase: 5, capacity: 12, early: true)
        _ = feed(&second, [0, 0], speech: false)
        _ = feed(&second, [1, 1, 1], speech: true)                                 // «Так,»
        #expect(feed(&second, [0, 0], speech: false).count == 1)
        second.reject()
        _ = feed(&second, [2, 2, 2, 2], speech: true)                              // «Чилк,»
        #expect(feed(&second, [0, 0], speech: false).count == 1 && second.lastClipWasEarly)
        second.reject()
        _ = feed(&second, [3, 3, 3, 3], speech: true)
        #expect(feed(&second, [0, 0], speech: false).isEmpty)                      // two early looks at most
        var over = WakeAudioGate(sampleRate: 10, preRoll: 0.2, pause: 0.6, maxPhrase: 5, capacity: 12, early: true)
        _ = feed(&over, [0, 0], speech: false)
        _ = feed(&over, [1, 1, 1, 1], speech: true)
        _ = feed(&over, [0, 0], speech: false)                                      // early check…
        _ = feed(&over, [0, 0, 0, 0], speech: false)                                // …the phrase ends during it
        over.reject()
        #expect(feed(&over, [0, 0, 0], speech: false).isEmpty)                     // nothing new: no second check
        var off = WakeAudioGate(sampleRate: 10, preRoll: 0.2, pause: 0.6, maxPhrase: 5, capacity: 12)
        _ = feed(&off, [0, 0], speech: false)
        #expect(feed(&off, Array(repeating: 1, count: 15), speech: true).isEmpty)  // off by default
    }
}
