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
    static func download(_ model: LocalModelDescriptor, base: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let patterns = ["Preprocessor.mlmodelc/*", "Encoder.mlmodelc/*", "Decoder.mlmodelc/*", "JointDecision.mlmodelc/*", "parakeet_vocab.json"]
        return try await HubApi(downloadBase: base).snapshot(from: model.repository, matching: patterns) { progress($0.fractionCompleted) }
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
        manager = engine
    }
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw FrogError.message("The Parakeet model is not loaded.") }
        let result = try await manager.transcribe(samples)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func unload() async { await manager?.cleanup(); manager = nil }
}
#endif
