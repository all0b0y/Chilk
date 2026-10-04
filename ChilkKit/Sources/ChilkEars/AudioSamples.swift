import AVFoundation
import Foundation
import WhisperKit

/// Reuse the resampler across microphone callbacks; copying Float32 data lets it safely cross actors.
public final class AudioSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private static let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    public init() {}

    public func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        try lock.withLock {
            if buffer.format == Self.format { return AudioProcessor.convertBufferToArray(buffer: buffer) }
            if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: Self.format) }
            guard let converter else { throw EarsError.noAudioFormat }
            let out = try AudioProcessor.resampleBuffer(buffer, with: converter)
            return AudioProcessor.convertBufferToArray(buffer: out)
        }
    }

    public static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            buffer.floatChannelData![0].update(from: pointer.baseAddress!, count: samples.count)
        }
        return buffer
    }

    /// Offline harness and the app's demo use the same 16 kHz format as the microphone path.
    public static func load(file: URL) throws -> [Float] {
        try AudioProcessor.loadAudioAsFloatArray(fromPath: file.path)
    }
}
