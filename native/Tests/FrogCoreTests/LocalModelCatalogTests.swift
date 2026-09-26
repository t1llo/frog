import XCTest
@testable import FrogCore

final class LocalModelCatalogTests: XCTestCase {
    func testKnownParakeetSourceRequiresAllNativeComponents() throws {
        let source = try HuggingFaceSource("FluidInference/parakeet-tdt-0.6b-v3-coreml")
        let files = ["Preprocessor", "Encoder", "Decoder", "JointDecision"].map { "\($0).mlmodelc/coremldata.bin" } + ["parakeet_vocab.json"]
        let models = try HuggingFaceModels.descriptors(source: source, metadata: data(["siblings": files.map { ["rfilename": $0] }]), textConfig: nil)
        XCTAssertEqual(models.map(\.id), ["parakeet-v3"])
        XCTAssertThrowsError(try HuggingFaceModels.descriptors(source: source, metadata: data(["siblings": []]), textConfig: nil))
    }
    func testHuggingFaceLinksCanonicalizeAndRejectUnsupportedLocations() throws {
        let id = try HuggingFaceSource("mlx-community/Qwen3-4B-4bit")
        XCTAssertEqual(try HuggingFaceSource(" https://huggingface.co/mlx-community/Qwen3-4B-4bit/ "), id)
        let folder = try HuggingFaceSource("https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-base")
        XCTAssertEqual(folder.variant, "openai_whisper-base")
        for input in ["https://example.com/owner/model", "http://huggingface.co/owner/model", "../model", "owner/..", "owner/model/../other", "https://user:pass@huggingface.co/owner/model", "https://huggingface.co/owner/model?token=secret", "https://huggingface.co/owner/model/resolve/main/weights.bin", "https://huggingface.co/owner/model/tree/other/variant"] {
            XCTAssertThrowsError(try HuggingFaceSource(input), input)
        }
    }
    func testCustomMLXSourceRoundTripsAndResolvesRuleAndDefaultReferences() throws {
        let source = try HuggingFaceSource("owner/mlx-model")
        let metadata = try data(["gated": false, "siblings": ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"].map { ["rfilename": $0] }])
        let config = try data(["model_type": "qwen3", "quantization": ["bits": 4, "group_size": 64]])
        let model = try XCTUnwrap(HuggingFaceModels.descriptors(source: source, metadata: metadata, textConfig: config).first)
        XCTAssertEqual(model.backend, .mlx)
        XCTAssertEqual(model.id, HuggingFaceSource.modelID(repository: "owner/mlx-model", variant: nil, backend: .mlx))
        var configuration = Configuration(); configuration.localModels = [model]
        var prefs = WorkflowPreferences(); prefs.defaultLocalTextModelID = model.id; prefs.cleanupModelID = model.id
        configuration.preferences.workflows = prefs
        configuration.rules[0].action = RuleAction(); configuration.rules[0].action?.localTextModelID = model.id
        let restored = try ConfigurationFile.decode(ConfigurationFile.encode(configuration))
        XCTAssertEqual(restored, configuration)
        XCTAssertEqual(restored.localModel(model.id), model)
        configuration.localModels = []
        XCTAssertThrowsError(try ConfigurationFile.validate(configuration), "Referenced custom sources cannot silently disappear")
    }
    func testWhisperInspectionOffersOnlyCompleteRequestedVariants() throws {
        let source = try HuggingFaceSource("https://huggingface.co/owner/speech/tree/main/openai_whisper-tiny")
        let paths = ["AudioEncoder", "TextDecoder", "MelSpectrogram"].map { "openai_whisper-tiny/\($0).mlmodelc/coremldata.bin" } + ["incomplete/AudioEncoder.mlmodelc/coremldata.bin"]
        let models = try HuggingFaceModels.descriptors(source: source, metadata: data(["siblings": paths.map { ["rfilename": $0] }]), textConfig: nil)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].variant, "openai_whisper-tiny")
        XCTAssertEqual(models[0].backend, .whisperKit)
        XCTAssertEqual(models[0].filesURL.absoluteString, "https://huggingface.co/owner/speech/tree/main/openai_whisper-tiny")
        XCTAssertNoThrow(try models[0].validateCustom())
    }
    func testRawWeightsAndGatedRepositoriesAreNotOfferedAsCompatible() throws {
        let source = try HuggingFaceSource("owner/raw-model")
        let files = ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"].map { ["rfilename": $0] }
        let config = try data(["model_type": "llama"])
        XCTAssertThrowsError(try HuggingFaceModels.descriptors(source: source, metadata: data(["siblings": files]), textConfig: config))
        XCTAssertThrowsError(try HuggingFaceModels.descriptors(source: source, metadata: data(["siblings": files, "library_name": "mlx", "gated": "manual"]), textConfig: config))
    }
    func testFirstInstalledAudioBecomesDefaultButSecondDoesNotReplaceIt() {
        var config = Configuration()
        let first = LocalModelDescriptor.find("parakeet-v3")!
        let second = LocalModelDescriptor.find("whisper-base")!
        config.selectSoleInstalledModel(first, installed: [first.id])
        XCTAssertEqual(config.preferences.workflowSettings.audioModelID, first.id)
        config.selectSoleInstalledModel(second, installed: [first.id, second.id])
        XCTAssertEqual(config.preferences.workflowSettings.audioModelID, first.id)
    }
    func testFirstLocalTextModelKeepsAnExistingProviderChoice() {
        var config = Configuration()
        let provider = ProviderConfiguration(); config.providers = [provider]; config.defaultProviderID = provider.id
        let model = LocalModelDescriptor.find("llama-1b")!
        config.selectSoleInstalledModel(model, installed: [model.id])
        XCTAssertEqual(config.preferences.workflowSettings.defaultLocalTextModelID, model.id)
        XCTAssertEqual(config.preferences.workflowSettings.effectiveTextSource, .provider)
        var localOnly = Configuration()
        localOnly.selectSoleInstalledModel(model, installed: [model.id])
        XCTAssertEqual(localOnly.preferences.workflowSettings.effectiveTextSource, .frog)
    }
    func testSpeechLanguageCapabilitiesMatchEachRuntime() {
        XCTAssertTrue(LocalModelDescriptor.find("whisper-small")!.supportsLanguageSelection)
        XCTAssertFalse(LocalModelDescriptor.find("parakeet-v3")!.supportsLanguageSelection)
        XCTAssertTrue(LocalModelDescriptor.find("parakeet-v2")!.englishOnly)
        XCTAssertFalse(LocalModelDescriptor.find("parakeet-v3")!.englishOnly)
    }
    private func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
}
