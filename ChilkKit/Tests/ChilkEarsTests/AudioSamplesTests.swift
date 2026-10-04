import AVFoundation
@testable import ChilkEars
import Testing

@Suite("Audio format")
struct AudioSamplesTests {
    @Test func stereo44100BecomesMono16000AndKeepsItsLevel() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        for channel in 0..<2 {
            for i in 0..<44_100 { buffer.floatChannelData![channel][i] = 0.1 }
        }
        let samples = try AudioSamples().convert(buffer)
        #expect(samples.count >= 15_900 && samples.count <= 16_100)
        #expect(abs(samples.dropFirst(100).reduce(0, +) / Float(samples.count - 100) - 0.1) < 0.01)
        let replay = try #require(AudioSamples.buffer(samples))
        #expect(replay.format.sampleRate == 16_000)
        #expect(replay.format.channelCount == 1)
        #expect(Int(replay.frameLength) == samples.count)
    }
}
