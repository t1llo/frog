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
    private var decoderLayers = 2
    /// The files come through the same Hugging Face client as MLX models, not
    /// FluidAudio's downloader, so the progress has bytes, speed and time left too.
    static func download(_ model: LocalModelDescriptor, base: URL, progress: @escaping @Sendable (FrogCore.DownloadProgress) -> Void) async throws -> URL {
        let patterns = model.parakeetComponents.map { "\($0).mlmodelc/*" } + ["parakeet_vocab.json"]
        let meter = DownloadMeter(folder: base, expected: model.downloadBytes)
        return try await meter.reporting(to: progress) {
            try await HubApi.modelFolder(base).snapshot(from: model.repository, matching: patterns) { progress(meter.snapshot($0)) }
        }
    }
    static func version(_ model: LocalModelDescriptor) -> AsrModelVersion {
        switch model.variant { case "v2": .v2; case "ultra": .ultra; default: .v3 }
    }
    func load(from directory: URL, model: LocalModelDescriptor) async throws {
        let version = Self.version(model)
        let names = model.parakeetComponents
        @Sendable func component(_ name: String, cpuOnly: Bool = false) async throws -> MLModel {
            try Task.checkCancellation()
            let config = MLModelConfiguration()
            // FluidAudio's ANE default also serves iOS background execution. On
            // macOS, GPU avoids the encoder's lengthy cold ANE specialization
            // while retaining accelerated inference. Keep the frontend on CPU.
            config.computeUnits = cpuOnly ? .cpuOnly : .cpuAndGPU
            return try await MLModel.load(contentsOf: directory.appendingPathComponent(name + ".mlmodelc"), configuration: config)
        }
        // The four components are independent: loading them side by side takes about
        // as long as the encoder alone.
        async let preprocessor = component(names[0], cpuOnly: true)
        async let encoder = component(names[1])
        async let decoder = component(names[2])
        async let joint = component(names[3])
        let rawVocabulary = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: directory.appendingPathComponent("parakeet_vocab.json")))
        let vocabulary = Dictionary(uniqueKeysWithValues: rawVocabulary.compactMap { key, value in Int(key).map { ($0, value) } })
        guard !vocabulary.isEmpty else { throw FrogError.message("The Parakeet vocabulary is empty. Delete and download the model again.") }
        let config = MLModelConfiguration(); config.computeUnits = .cpuAndGPU
        let models = try await AsrModels(encoder: encoder, preprocessor: preprocessor, decoder: decoder, joint: joint, configuration: config, vocabulary: vocabulary, version: version)
        let engine = AsrManager(models: models)
        try Task.checkCancellation()
        manager = engine; decoderLayers = version.decoderLayers
        // The first prediction of each component is slow while Core ML prepares it
        // for the GPU. Paying that here, on silence, keeps it out of the first
        // dictation's preview and transcript.
        _ = try? await transcribe([Float](repeating: 0, count: Self.warmUpSamples))
        try Task.checkCancellation()
    }
    /// A little over the second that Parakeet needs at least, at 16 kHz.
    static let warmUpSamples = 17_600
    /// Each transcription starts from a fresh decoder state, so a stopped preview
    /// never hands the end of its utterance to the next transcription.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw FrogError.message("The Parakeet model is not loaded.") }
        var state = try TdtDecoderState(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func unload() async { await manager?.cleanup(); manager = nil }
}
#endif
