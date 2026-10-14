import XCTest
@testable import FrogCore

final class LocalModelCatalogTests: XCTestCase {
    func testFreshInventoryOffersFourSpeechModelsAndTheRecommendedDefault() {
        let configuration = Configuration()
        let audio = configuration.modelInventory(installed: []).filter { $0.kind == .audio }
        XCTAssertEqual(audio.count, 4)
        XCTAssertEqual(Set(audio.map(\.id)).count, 4)
        XCTAssertEqual(audio.filter { $0.backend == .whisperKit }.count, 3)
        XCTAssertEqual(audio.filter { $0.backend == .parakeet }.count, 1)
        XCTAssertEqual(audio.filter(\.isRecommended).map(\.id), ["parakeet-v3", configuration.preferences.workflowSettings.audioModelID])
        XCTAssertEqual(configuration.modelInventory(installed: []).filter { $0.kind == .text }, LocalModelDescriptor.catalog.filter { $0.kind == .text })
    }
    func testOriginalSpeechSelectionsRoundTripAndRemainRecoverable() throws {
        for id in ["whisper-tiny", "whisper-base", "whisper-small", "whisper-medium", "whisper-large-v3", "whisper-large-v3-turbo", "parakeet-v3", "parakeet-v2"] {
            var configuration = Configuration()
            var rule = Rule.dictationPreset
            rule.action?.audioModelID = id
            configuration.rules = [rule]
            var workflow = WorkflowPreferences(); workflow.audioModelID = id
            configuration.preferences.workflows = workflow
            let restored = try ConfigurationFile.decode(ConfigurationFile.encode(configuration))
            XCTAssertEqual(restored, configuration)
            XCTAssertNotNil(restored.localModel(id))
            XCTAssertTrue(restored.modelInventory(installed: []).contains { $0.id == id }, "Selected downloads must remain recoverable: \(id)")
        }
        XCTAssertEqual(LocalModelDescriptor.find("whisper-small")?.variant, "openai_whisper-small")
        XCTAssertEqual(LocalModelDescriptor.find("whisper-large-v3-turbo")?.variant, "openai_whisper-large-v3-v20240930_turbo_632MB")
    }
    func testEveryCatalogModelHasANameOfItsOwn() {
        let names = LocalModelDescriptor.catalog.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "Two rows with one name cannot be told apart in a list or a rule")
        XCTAssertEqual(LocalModelDescriptor.find("whisper-large-v3-turbo-626mb")?.name, "Whisper Large v3 Turbo")
        XCTAssertEqual(LocalModelDescriptor.find("whisper-large-v3-turbo")?.name, "Whisper Large v3 Turbo · earlier build", "The earlier conversion keeps its ID for saved rules")
    }
    func testInventoryRetainsInstalledRuleSelectedAndExplicitlyRevealedLegacyModels() {
        var configuration = Configuration()
        XCTAssertFalse(configuration.modelInventory(installed: []).contains { $0.id == "whisper-medium" })
        var rule = Rule.dictationPreset; rule.action?.audioModelID = "whisper-small"
        configuration.rules = [rule]
        let inventory = configuration.modelInventory(installed: ["whisper-medium"], including: ["parakeet-v2"])
        for id in ["whisper-small", "whisper-medium", "parakeet-v2"] {
            XCTAssertTrue(inventory.contains { $0.id == id })
        }
        XCTAssertFalse(inventory.contains { $0.id == "whisper-base" })
        XCTAssertEqual(Set(inventory.map(\.id)).count, inventory.count)
    }
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
        XCTAssertTrue(restored.modelInventory(installed: []).contains(model))
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
    func testSpeechLanguageCapabilitiesMatchEachRuntime() {
        XCTAssertTrue(LocalModelDescriptor.find("whisper-small")!.supportsLanguageSelection)
        XCTAssertFalse(LocalModelDescriptor.find("parakeet-v3")!.supportsLanguageSelection)
        XCTAssertTrue(LocalModelDescriptor.find("parakeet-v2")!.englishOnly)
        XCTAssertFalse(LocalModelDescriptor.find("parakeet-v3")!.englishOnly)
    }
    func testEveryCatalogModelKnowsTheBytesItsDownloadFetches() throws {
        for model in LocalModelDescriptor.catalog {
            let bytes = try XCTUnwrap(model.downloadBytes, "\(model.id) needs a byte count for the free-space check")
            XCTAssertGreaterThan(bytes, 50_000_000, model.id)
            XCTAssertLessThan(bytes, 4_000_000_000, model.id)
            XCTAssertEqual(model.downloadSize, LocalModelDescriptor.byteCount(bytes), model.id)
        }
        XCTAssertEqual(LocalModelDescriptor.find(LocalModelDescriptor.defaultAudioModelID)?.downloadSize, "629.5 MB")
        XCTAssertEqual(LocalModelDescriptor.find("qwen-1.7b")?.downloadSize, "984 MB")
        XCTAssertEqual(LocalModelDescriptor.find("whisper-large-v3")?.downloadSize, "3.09 GB")
    }
    func testSavedCustomModelWithoutAByteCountStillLoadsAndShowsItsText() throws {
        let id = HuggingFaceSource.modelID(repository: "owner/mlx-model", variant: nil, backend: .mlx)
        let saved = #"{"id":"\#(id)","name":"mlx-model","kind":"text","repository":"owner/mlx-model","size":"See source for size","backend":"mlx"}"#
        let model = try JSONDecoder().decode(LocalModelDescriptor.self, from: Data(saved.utf8))
        XCTAssertNil(model.downloadBytes)
        XCTAssertEqual(model.downloadSize, "See source for size")
        XCTAssertNoThrow(try model.validateCustom())
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(model), as: UTF8.self).contains("downloadBytes"), "Older versions read the same file")

        let measured = LocalModelDescriptor(id: id, name: "mlx-model", kind: .text, repository: "owner/mlx-model", size: "See source for size", downloadBytes: 1_234_567_890)
        XCTAssertEqual(try JSONDecoder().decode(LocalModelDescriptor.self, from: JSONEncoder().encode(measured)), measured)
        XCTAssertEqual(measured.downloadSize, "1.23 GB")
        XCTAssertNoThrow(try measured.validateCustom())
        for implausible: Int64 in [0, -1, 500_000_000_001] {
            let model = LocalModelDescriptor(id: id, name: "mlx-model", kind: .text, repository: "owner/mlx-model", size: "See source for size", downloadBytes: implausible)
            XCTAssertThrowsError(try model.validateCustom(), "\(implausible)")
        }
    }
    func testInspectionSumsExactlyTheFilesTheDownloadFetches() throws {
        let text = try HuggingFaceSource("owner/mlx-model")
        let config = try data(["model_type": "qwen3", "quantization": ["bits": 4, "group_size": 64]])
        let fetched: [String: Int64] = ["config.json": 1_000, "tokenizer.json": 2_000_000, "tokenizer_config.json": 5_000, "model-00001-of-00002.safetensors": 400_000_000,
                                        "model-00002-of-00002.safetensors": 100_000_000, "model.safetensors.index.json": 30_000, "chat_template.jinja": 4_000, "merges.txt": 1_600_000, "tokenizer.model": 500_000]
        let skipped: [String: Int64] = ["README.md": 9_000, ".gitattributes": 1_500, "pytorch_model.bin": 900_000_000, "model.gguf": 300_000_000]
        let siblings = fetched.merging(skipped) { $1 }.map { ["rfilename": $0.key, "size": $0.value] as [String: Any] }
        let model = try XCTUnwrap(HuggingFaceModels.descriptors(source: text, metadata: data(["siblings": siblings]), textConfig: config).first)
        XCTAssertEqual(model.downloadBytes, fetched.values.reduce(0, +))

        let speech = try HuggingFaceSource("owner/speech")
        let parts = ["AudioEncoder", "TextDecoder", "MelSpectrogram"]
        var files: [String: Int64] = ["config.json": 2_000, "README.md": 8_000]
        for (index, part) in parts.enumerated() {
            files["openai_whisper-tiny/\(part).mlmodelc/coremldata.bin"] = 1_000 + Int64(index)
            files["openai_whisper-tiny/\(part).mlmodelc/weights/weight.bin"] = 20_000_000
            files["openai_whisper-base/\(part).mlmodelc/coremldata.bin"] = 2_000
            files["openai_whisper-base/\(part).mlmodelc/weights/weight.bin"] = 50_000_000
        }
        files["openai_whisper-tiny/config.json"] = 3_000
        let variants = try HuggingFaceModels.descriptors(source: speech, metadata: data(["siblings": files.map { ["rfilename": $0.key, "size": $0.value] }]), textConfig: nil)
        XCTAssertEqual(variants.map(\.variant), ["openai_whisper-base", "openai_whisper-tiny"])
        XCTAssertEqual(variants.map(\.downloadBytes), [150_006_000, 60_006_003], "Only the files of the chosen variant folder are fetched")

        // Metadata read without `blobs=true`, or with a file whose size is missing.
        let unsized = try HuggingFaceModels.descriptors(source: text, metadata: data(["siblings": fetched.keys.map { ["rfilename": $0] }]), textConfig: config)
        XCTAssertNil(unsized.first?.downloadBytes)
        XCTAssertEqual(unsized.first?.downloadSize, "See source for size")
        var partly = siblings; partly.append(["rfilename": "extra.safetensors"])
        XCTAssertNil(try HuggingFaceModels.descriptors(source: text, metadata: data(["siblings": partly]), textConfig: config).first?.downloadBytes)
    }
    func testCheckingASourceAsksHuggingFaceForTheFileSizes() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        MetadataFixture.respond = { url in
            switch (url.path, url.query) {
            case ("/api/models/owner/mlx-model", "blobs=true"):
                return try? self.data(["siblings": [["rfilename": "config.json", "size": 1_000], ["rfilename": "tokenizer.json", "size": 2_000], ["rfilename": "tokenizer_config.json", "size": 3_000],
                                                    ["rfilename": "model.safetensors", "size": 400_000_000], ["rfilename": "README.md", "size": 5_000]], "library_name": "mlx"])
            case ("/owner/mlx-model/resolve/main/config.json", nil): return try? self.data(["model_type": "qwen3"])
            default: return nil
            }
        }
        defer { MetadataFixture.respond = nil }
        let models = try await HuggingFaceModels(session: session).inspect("owner/mlx-model")
        XCTAssertEqual(models.map(\.downloadBytes), [400_006_000])
    }
    private func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
}

/// Answers Hugging Face requests from fixtures; anything else gets a 404.
private final class MetadataFixture: URLProtocol {
    nonisolated(unsafe) static var respond: ((URL) -> Data?)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let body = Self.respond?(url)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
