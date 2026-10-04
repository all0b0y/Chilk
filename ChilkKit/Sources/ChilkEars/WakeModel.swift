import Foundation
@preconcurrency import WhisperKit

/// The exact full turbo model validated in spike 003; never auto-select a smaller/quantized model.
/// Only downloaded weights/tokenizers touch the network. Recorded audio stays on this Mac.
public actor WakeModel {
    public static let variant = "openai_whisper-large-v3-v20240930_turbo"
    public enum State: Sendable { case downloading(Double), learning, ready }
    public enum ModelError: Error, CustomStringConvertible {
        case missing, notReady
        public var description: String {
            switch self { case .missing: "wake model missing or incomplete"; case .notReady: "wake model not ready" }
        }
    }
    private var kit: WhisperKit?
    public init() {}

    /// Explicit folder = development/offline override. Missing overrides fail, rather than silently downloading.
    public func prepare(folder: URL? = nil, base: URL,
                        progress: @escaping @Sendable (State) -> Void = { _ in }) async throws {
        guard kit == nil else { progress(.ready); return }
        let local = folder ?? base.appending(path: "models/argmaxinc/whisperkit-coreml/\(Self.variant)")
        let required = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "config.json"]
        let present = required.allSatisfy { FileManager.default.fileExists(atPath: local.appending(path: $0).path) }
        let selected: URL
        if present { selected = local }
        else if folder != nil { throw ModelError.missing }
        else {
            progress(.downloading(0))
            selected = try await WhisperKit.download(variant: Self.variant, downloadBase: base) { value in
                progress(.downloading(value.fractionCompleted))
            }
        }
        progress(.learning)
        let config = WhisperKitConfig(model: Self.variant, modelFolder: selected.path,
                                      tokenizerFolder: base, verbose: false, logLevel: .error,
                                      prewarm: true, load: true, download: false)
        kit = try await WhisperKit(config)
        progress(.ready)
    }

    /// These short windows need text, not segment timing. Timestamp decoding dropped opening names
    /// in the actual VAD windows even when the raw recordings worked (verified against the pinned CLI).
    nonisolated static func decodingOptions(prompt: [Int]?) -> DecodingOptions {
        DecodingOptions(language: "ru", skipSpecialTokens: true, withoutTimestamps: true,
                        promptTokens: prompt, concurrentWorkerCount: 1)
    }

    public func recognize(_ samples: [Float]) async throws -> String {
        guard let kit else { throw ModelError.notReady }
        let prompt = kit.tokenizer?.encode(text: " Чилк").filter { $0 < kit.tokenizer!.specialTokens.specialTokenBegin }
        let options = Self.decodingOptions(prompt: prompt)
        let result = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return result.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
