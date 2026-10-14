import XCTest
import CryptoKit
import FrogCore
@testable import FrogApp

/// Checking and repairing the files of a downloaded model, on folders laid out as
/// the Hugging Face client leaves them. Nothing here uses the network.
@MainActor
final class ModelFileCheckTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    func testCompleteTextModelPassesAndAChangedOrMissingFileIsNamed() throws {
        let model = try XCTUnwrap(LocalModelDescriptor.find("qwen-0.6b"))
        let base = directory.appendingPathComponent(model.id)
        let installed = try Self.textModel(model, in: base)
        XCTAssertEqual(ModelFiles.check(model, folder: base, installed: installed, contents: true), ModelFileCheck())
        XCTAssertTrue(ModelFiles.check(model, folder: base, installed: installed, contents: true).passed)

        let weights = installed.appendingPathComponent("model.safetensors")
        try Data(repeating: 9, count: 4096).write(to: weights)
        let repo = "models/\(model.repository)"
        XCTAssertEqual(ModelFiles.check(model, folder: base, installed: installed, contents: true), ModelFileCheck(damaged: ["\(repo)/model.safetensors"]),
                       "Weights whose bytes no longer match the hash recorded at download are damaged")
        XCTAssertTrue(ModelFiles.check(model, folder: base, installed: installed, contents: false).passed, "Without reading the contents only presence counts")

        try FileManager.default.removeItem(at: installed.appendingPathComponent("tokenizer.json"))
        try FileManager.default.removeItem(at: installed.appendingPathComponent("added_tokens.json"))
        try Data().write(to: installed.appendingPathComponent("config.json"))
        let check = ModelFiles.check(model, folder: base, installed: installed, contents: true)
        XCTAssertEqual(check.missing, ["\(repo)/added_tokens.json", "\(repo)/tokenizer.json"], "A required file and a file the download fetched are both missed")
        XCTAssertEqual(check.damaged, ["\(repo)/config.json", "\(repo)/model.safetensors"], "An empty required file is damaged")
        XCTAssertEqual(check.summary, "2 files missing, 2 damaged: added_tokens.json, tokenizer.json, config.json…")
    }

    func testSpeechModelsNeedTheirCoreMLComponentsVocabularyAndTokenizer() throws {
        let parakeet = try XCTUnwrap(LocalModelDescriptor.find("parakeet-v3"))
        let parakeetBase = directory.appendingPathComponent(parakeet.id)
        let parakeetFolder = parakeetBase.appendingPathComponent("models/\(parakeet.repository)")
        for component in ["Preprocessor", "Encoder", "Decoder", "JointDecision"] {
            try Self.place(Data("core ml".utf8), at: "\(component).mlmodelc/coremldata.bin", repository: parakeet.repository, in: parakeetBase)
            try Self.place(Data(repeating: 1, count: 2048), at: "\(component).mlmodelc/weights/weight.bin", repository: parakeet.repository, in: parakeetBase, lfs: true)
        }
        XCTAssertEqual(ModelFiles.check(parakeet, folder: parakeetBase, installed: parakeetFolder, contents: true).missing, ["models/\(parakeet.repository)/parakeet_vocab.json"])

        let whisper = try XCTUnwrap(LocalModelDescriptor.find("whisper-tiny"))
        let variant = try XCTUnwrap(whisper.variant)
        let whisperBase = directory.appendingPathComponent(whisper.id)
        for component in ["AudioEncoder", "TextDecoder", "MelSpectrogram"] {
            try Self.place(Data("core ml".utf8), at: "\(variant)/\(component).mlmodelc/coremldata.bin", repository: whisper.repository, in: whisperBase)
        }
        try Self.place(Data("{}".utf8), at: "tokenizer.json", repository: "openai/whisper-tiny", in: whisperBase)
        let variantFolder = whisperBase.appendingPathComponent("models/\(whisper.repository)/\(variant)")
        XCTAssertTrue(ModelFiles.check(whisper, folder: whisperBase, installed: variantFolder, contents: true).passed)
        try FileManager.default.removeItem(at: whisperBase.appendingPathComponent("models/openai/whisper-tiny/tokenizer.json"))
        let check = ModelFiles.check(whisper, folder: whisperBase, installed: variantFolder, contents: true)
        XCTAssertEqual(check.missing, ["models/openai/whisper-tiny/tokenizer.json"], "The tokenizer WhisperKit fetched beside the model counts too")
        XCTAssertEqual(check.summary, "1 file missing: tokenizer.json")
    }

    func testDownloadThatLacksAFileItsRuntimeNeedsStaysUnfinished() async throws {
        let model = try XCTUnwrap(LocalModelDescriptor.find("qwen-0.6b"))
        let models = LocalModels(directory: directory, runtime: ModelFileFixtureInference(), downloader: { model, base, _ in
            let installed = try Self.textModel(model, in: base)
            try FileManager.default.removeItem(at: installed.appendingPathComponent("tokenizer.json"))
            try Data().write(to: installed.appendingPathComponent("config.json"))
            return try ModelFiles.requireComplete(model, folder: base, installed: installed)
        }, freeSpace: { _ in nil })
        models.download(model); await models.waitForDownload(model.id)
        XCTAssertFalse(models.installed.contains(model.id))
        XCTAssertEqual(models.unfinished, [model.id], "The files stay as an unfinished download that can be resumed")
        let error = try XCTUnwrap(models.errors[model.id])
        XCTAssertTrue(error.contains(model.name) && error.contains("tokenizer.json") && error.contains("config.json"), error)
        let config = models.root.appendingPathComponent("\(model.id)/models/\(model.repository)/config.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path), "An empty file is removed, so that resuming fetches it again")
    }

    func testCheckingFindsDamageAndRepairFetchesAgainOnlyWhatIsDamaged() async throws {
        let model = try XCTUnwrap(LocalModelDescriptor.find("qwen-0.6b"))
        let attempts = DownloadAttempts()
        let models = LocalModels(directory: directory, runtime: ModelFileFixtureInference(), downloader: { model, base, progress in
            let installed = base.appendingPathComponent("models/\(model.repository)")
            if await attempts.next() == 2 {
                // What the repair hands the library: the damaged weights are gone and
                // everything else is kept, so that only they are fetched again.
                XCTAssertFalse(FileManager.default.fileExists(atPath: installed.appendingPathComponent("model.safetensors").path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("tokenizer.json").path))
                progress(DownloadProgress(fraction: 0.5))
            }
            return try Self.textModel(model, in: base)
        }, freeSpace: { _ in nil })
        models.download(model); await models.waitForDownload(model.id)
        XCTAssertTrue(models.installed.contains(model.id))

        models.checkFiles(model.id)
        XCTAssertEqual(models.fileChecks[model.id], .checking)
        await models.waitForFileCheck(model.id)
        XCTAssertEqual(models.fileChecks[model.id], .finished(ModelFileCheck()))

        let weights = models.root.appendingPathComponent("\(model.id)/models/\(model.repository)/model.safetensors")
        try Data(repeating: 9, count: 4096).write(to: weights)
        models.checkFiles(model.id); await models.waitForFileCheck(model.id)
        XCTAssertEqual(models.fileChecks[model.id], .finished(ModelFileCheck(damaged: ["models/\(model.repository)/model.safetensors"])))

        try await models.repair(model.id)
        XCTAssertNil(models.fileChecks[model.id], "The row shows the download's progress instead of the old result")
        XCTAssertNotNil(models.progress[model.id])
        await models.waitForDownload(model.id)
        let count = await attempts.count
        XCTAssertEqual(count, 2)
        XCTAssertTrue(models.installed.contains(model.id), "A model being repaired stays downloaded, so its rules keep it")
        XCTAssertNil(models.errors[model.id])
        await models.waitForFileCheck(model.id)
        XCTAssertEqual(models.fileChecks[model.id], .finished(ModelFileCheck()), "The repaired files are checked again")
    }

    func testModelBeingRepairedIsNotUsedAndAFailedRepairKeepsTheModel() async throws {
        let model = try XCTUnwrap(LocalModelDescriptor.find("qwen-0.6b"))
        let attempts = DownloadAttempts()
        let gate = RepairGate()
        let models = LocalModels(directory: directory, runtime: ModelFileFixtureInference(), downloader: { model, base, _ in
            if await attempts.next() == 2 {
                await gate.wait()
                throw FrogError.message("The connection dropped")
            }
            return try Self.textModel(model, in: base)
        }, freeSpace: { _ in nil })
        models.download(model); await models.waitForDownload(model.id)
        _ = try await models.complete("hello", instructions: "Correct", modelID: model.id)
        XCTAssertEqual(models.loaded, [model.id])
        try Data(repeating: 9, count: 4096).write(to: models.root.appendingPathComponent("\(model.id)/models/\(model.repository)/model.safetensors"))
        models.checkFiles(model.id); await models.waitForFileCheck(model.id)

        try await models.repair(model.id)
        XCTAssertTrue(models.loaded.isEmpty, "The model leaves memory before its files are replaced")
        await gate.waitUntilStarted()
        do { _ = try await models.complete("hello", instructions: "Correct", modelID: model.id); XCTFail("A model being repaired must not run") }
        catch { XCTAssertTrue(error.localizedDescription.contains("repaired"), error.localizedDescription) }
        await gate.resume()
        await models.waitForDownload(model.id)
        XCTAssertEqual(models.errors[model.id], "The connection dropped")
        XCTAssertTrue(models.installed.contains(model.id))
        XCTAssertNil(models.fileChecks[model.id])
    }

    func testLoadFailureSaysTheFilesMayBeDamagedAndKeepsTheOriginalText() async throws {
        let model = try XCTUnwrap(LocalModelDescriptor.find("qwen-0.6b"))
        let models = LocalModels(directory: directory, runtime: ModelFileFixtureInference(failure: "Unexpected end of safetensors header"), downloader: { model, base, _ in
            try Self.textModel(model, in: base)
        }, freeSpace: { _ in nil })
        models.download(model); await models.waitForDownload(model.id)
        do { try await models.prepare(model.id); XCTFail("The load must fail") }
        catch {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("Unexpected end of safetensors header"), text)
            XCTAssertTrue(text.contains(model.name) && text.contains("Check files"), text)
        }
        XCTAssertFalse(models.busy)
    }

    /// An MLX text model as the Hugging Face client leaves it, its weights stored by LFS.
    nonisolated static func textModel(_ model: LocalModelDescriptor, in base: URL) throws -> URL {
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json", "added_tokens.json"] {
            try place(Data("{\"name\": \"\(name)\"}".utf8), at: name, repository: model.repository, in: base)
        }
        try place(Data(repeating: 7, count: 4096), at: "model.safetensors", repository: model.repository, in: base, lfs: true)
        return base.appendingPathComponent("models/\(model.repository)")
    }

    /// Writes a file and, under the repository's `.cache`, the commit and etag that the
    /// client records for it. The etag of an LFS file is the SHA-256 of its bytes.
    nonisolated static func place(_ data: Data, at path: String, repository: String, in base: URL, lfs: Bool = false) throws {
        let root = base.appendingPathComponent("models/\(repository)")
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        let etag = lfs ? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() : String(repeating: "ab", count: 20)
        let metadata = root.appendingPathComponent(".cache/huggingface/download/\(path).metadata")
        try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "\(String(repeating: "c0", count: 20))\n\(etag)\n1760000000.0\n".write(to: metadata, atomically: true, encoding: .utf8)
    }
}

private actor DownloadAttempts {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

private actor RepairGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func waitUntilStarted() async { while continuation == nil { await Task.yield() } }
    func resume() { continuation?.resume(); continuation = nil }
}

private actor ModelFileFixtureInference: LocalInferenceEngine {
    let failure: String?
    init(failure: String? = nil) { self.failure = failure }
    var loadedIDs = Set<String>()
    func prepare(model: LocalModelDescriptor, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws {
        if let failure { throw FrogError.message(failure) }
        loadedIDs.insert(model.id); await residency(loadedIDs)
    }
    func transcribe(_ samples: [Float], model: LocalModelDescriptor, url: URL, language: String?, residency: @Sendable (Set<String>) async -> Void) async throws -> String {
        try await prepare(model: model, url: url, residency: residency); return "hello"
    }
    func complete(_ text: String, instructions: String, id: String, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws -> String {
        loadedIDs.insert(id); await residency(loadedIDs); return text
    }
    func unload(keepingMetadata: Bool) { loadedIDs = [] }
}
