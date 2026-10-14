#if arch(arm64)
import CoreML
import Foundation
import FluidAudio
import FrogCore
import Hub

/// Only the explicit download action contacts the hub. Inference uses local files,
/// bypassing FluidAudio's convenience loaders and their auto-download recovery.
actor ParakeetRuntime {
    private var manager: AsrManager?
    /// The files come through the same Hugging Face client as MLX models, not
    /// FluidAudio's downloader, so the progress has bytes, speed and time left too.
    static func download(_ model: LocalModelDescriptor, base: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let patterns = ["Preprocessor.mlmodelc/*", "Encoder.mlmodelc/*", "Decoder.mlmodelc/*", "JointDecision.mlmodelc/*", "parakeet_vocab.json"]
        let meter = DownloadMeter(folder: base, expected: model.downloadBytes)
        return try await meter.reporting(to: progress) {
            try await HubApi.modelFolder(base).snapshot(from: model.repository, matching: patterns) { progress(meter.snapshot($0)) }
        }
    }
    func load(from directory: URL, version: AsrModelVersion) async throws {
        func component(_ name: String, cpuOnly: Bool = false) async throws -> MLModel {
            try Task.checkCancellation()
            let config = MLModelConfiguration()
            // FluidAudio's ANE default also serves iOS background execution. On
            // macOS, GPU avoids the encoder's lengthy cold ANE specialization
            // while retaining accelerated inference. Keep the frontend on CPU.
            config.computeUnits = cpuOnly ? .cpuOnly : .cpuAndGPU
            return try await MLModel.load(contentsOf: directory.appendingPathComponent(name + ".mlmodelc"), configuration: config)
        }
        let preprocessor = try await component("Preprocessor", cpuOnly: true)
        let encoder = try await component("Encoder")
        let decoder = try await component("Decoder")
        let joint = try await component("JointDecision")
        let rawVocabulary = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: directory.appendingPathComponent("parakeet_vocab.json")))
        let vocabulary = Dictionary(uniqueKeysWithValues: rawVocabulary.compactMap { key, value in Int(key).map { ($0, value) } })
        guard !vocabulary.isEmpty else { throw FrogError.message("The Parakeet vocabulary is empty. Delete and download the model again.") }
        let config = MLModelConfiguration(); config.computeUnits = .cpuAndGPU
        let models = AsrModels(encoder: encoder, preprocessor: preprocessor, decoder: decoder, joint: joint, configuration: config, vocabulary: vocabulary, version: version)
        let engine = AsrManager()
        try Task.checkCancellation()
        try await engine.initialize(models: models)
        try Task.checkCancellation()
        manager = engine; decoderNeedsReset = false
    }
    /// FluidAudio resets its decoder only after a transcription that succeeds. A stopped preview
    /// would otherwise hand the end of its utterance to the next transcription.
    private var decoderNeedsReset = false
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw FrogError.message("The Parakeet model is not loaded.") }
        if decoderNeedsReset { try await manager.resetDecoderState(); decoderNeedsReset = false }
        do {
            let result = try await manager.transcribe(samples)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { decoderNeedsReset = true; throw error }
    }
    func unload() async { await manager?.cleanup(); manager = nil }
}
#endif
