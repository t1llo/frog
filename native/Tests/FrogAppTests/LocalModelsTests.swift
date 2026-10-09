import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class LocalModelsTests: XCTestCase {
    func testLegacySpeechDownloadsSurviveRestartAndKeepTheirOriginalRuntimeSources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = LocalModels(directory: directory, runtime: FixtureInference(), downloader: Self.fixtureDownload)
        let ids = ["whisper-small", "whisper-large-v3-turbo", "parakeet-v2"]
        for id in ids {
            models.download(try XCTUnwrap(LocalModelDescriptor.find(id))); await models.waitForDownload(id)
        }
        let engine = FixtureInference()
        let restarted = LocalModels(directory: directory, runtime: engine)
        restarted.updateCatalog(Configuration().modelCatalog)
        XCTAssertEqual(restarted.installed, Set(ids))
        for id in ids {
            _ = try await restarted.transcribe([0.1], modelID: id)
            let source = await engine.lastSpeechModel
            XCTAssertEqual(source, LocalModelDescriptor.find(id))
        }
        await restarted.unload()
    }
    func testCustomSourceInstallsRescansAndReachesTheSpeechRuntimeWithItsLanguagePolicy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FixtureInference()
        let models = LocalModels(directory: directory, runtime: engine, downloader: Self.fixtureDownload)
        let repository = "fixture/whisperkit"
        let variant = "openai_whisper-tiny.en"
        let custom = LocalModelDescriptor(id: HuggingFaceSource.modelID(repository: repository, variant: variant, backend: .whisperKit), name: "English fixture", kind: .audio, repository: repository, variant: variant, size: "Fixture")
        var installations = 0
        models.onInstall = { XCTAssertEqual($0.id, custom.id); installations += 1 }
        models.updateCatalog(LocalModelDescriptor.catalog + [custom])
        models.download(custom); await models.waitForDownload(custom.id)
        XCTAssertEqual(installations, 1)
        let restarted = LocalModels(directory: directory, runtime: FixtureInference())
        restarted.updateCatalog(models.catalog)
        XCTAssertTrue(restarted.installed.contains(custom.id))
        _ = try await models.transcribe([0.1], modelID: custom.id, language: "de")
        let requestedModel = await engine.lastSpeechModel
        let requestedLanguage = await engine.lastLanguage
        XCTAssertEqual(requestedModel, custom)
        XCTAssertEqual(requestedLanguage, "en", "English-only models must not receive a conflicting global language hint")
        await models.unload()
    }
    func testChangingIdlePolicyToImmediateUnloadsAnAlreadyResidentModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FixtureInference()
        let models = LocalModels(directory: directory, runtime: engine, downloader: Self.fixtureDownload)
        let descriptor = LocalModelDescriptor.find("qwen-0.6b")!
        models.download(descriptor); await models.waitForDownload(descriptor.id)
        _ = try await models.complete("hello", instructions: "Correct", modelID: descriptor.id)
        models.idleSeconds = 0
        await models.waitForIdleUnload()
        XCTAssertTrue(models.loaded.isEmpty)
        let unloads = await engine.unloads
        XCTAssertEqual(unloads, 1)
        models.shutdown()
    }
    func testResidencyIsVisibleDuringInferenceAndSurvivesInferenceFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DownloadGate()
        let models = LocalModels(directory: directory, runtime: FixtureInference(gate: gate, fail: true), downloader: Self.fixtureDownload)
        let descriptor = LocalModelDescriptor.find("qwen-0.6b")!
        models.download(descriptor); await models.waitForDownload(descriptor.id)
        let request = Task { try await models.complete("hello", instructions: "Correct", modelID: descriptor.id) }
        await gate.waitUntilStarted()
        XCTAssertTrue(models.busy)
        XCTAssertEqual(models.loaded, [descriptor.id])
        await gate.resume()
        do { _ = try await request.value; XCTFail("Fixture should fail") } catch {}
        XCTAssertEqual(models.loaded, [descriptor.id])
        await models.unload()
        XCTAssertTrue(models.loaded.isEmpty)
    }
    func testChangingStoragePreservesOldDownloadsAndPersistsNewLocation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = LocalModels(directory: directory, runtime: FixtureInference(), downloader: Self.fixtureDownload)
        let descriptor = LocalModelDescriptor.find("qwen-0.6b")!
        models.download(descriptor); await models.waitForDownload(descriptor.id)
        let original = models.root
        try await models.changeDirectory(to: directory.appendingPathComponent("custom"))
        XCTAssertTrue(models.installed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.appendingPathComponent(descriptor.id).path))
        models.download(descriptor); await models.waitForDownload(descriptor.id)
        let restarted = LocalModels(directory: directory)
        XCTAssertEqual(restarted.root, models.root)
        XCTAssertTrue(restarted.installed.contains(descriptor.id))
        try await models.changeDirectory(to: original)
        XCTAssertTrue(models.installed.contains(descriptor.id))
    }
    func testChangingStorageDuringDownloadIsRejectedAndForeignFolderIsPreserved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DownloadGate()
        let models = LocalModels(directory: directory, downloader: { model, base, progress in
            let folder = try await Self.fixtureDownload(model, base, progress)
            await gate.wait()
            return folder
        })
        let descriptor = LocalModelDescriptor.find("whisper-base")!
        models.download(descriptor); await gate.waitUntilStarted()
        let original = models.root
        do { try await models.changeDirectory(to: directory.appendingPathComponent("custom")); XCTFail("Active download must keep its root") } catch {}
        XCTAssertEqual(models.root, original)
        models.cancelDownload(descriptor.id); await gate.resume(); await models.waitForDownload(descriptor.id)
        let existing = original.appendingPathComponent(descriptor.id)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: existing.appendingPathComponent("user-file"))
        models.download(descriptor)
        XCTAssertNotNil(models.errors[descriptor.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.appendingPathComponent("user-file").path))
    }
    func testInstalledModelSurvivesRestartAndIdleUnloadReleasesResidency() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FixtureInference()
        let models = LocalModels(directory: directory, runtime: engine, downloader: Self.fixtureDownload)
        let descriptor = LocalModelDescriptor.find("qwen-0.6b")!
        models.download(descriptor); await models.waitForDownload(descriptor.id)
        XCTAssertTrue(models.installed.contains(descriptor.id))
        XCTAssertTrue(LocalModels(directory: directory).installed.contains(descriptor.id))
        models.idleSeconds = 0
        let output = try await models.complete("hello", instructions: "Correct", modelID: descriptor.id)
        XCTAssertEqual(output, "hello")
        await models.waitForIdleUnload()
        XCTAssertTrue(models.loaded.isEmpty)
        let unloads = await engine.unloads
        XCTAssertEqual(unloads, 1)
        let cancelledUnload = await engine.cancelledUnload
        XCTAssertFalse(cancelledUnload, "The idle task must not cancel itself before native resources are released")
        try await models.remove(descriptor.id)
        XCTAssertFalse(models.installed.contains(descriptor.id))
    }

    func testCancelledDownloadRemovesPartialFilesAndCannotInstallLateResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DownloadGate()
        let models = LocalModels(directory: directory, downloader: { model, base, progress in
            let folder = try await Self.fixtureDownload(model, base, progress)
            await gate.wait()
            return folder
        })
        let descriptor = LocalModelDescriptor.find("whisper-base")!
        models.download(descriptor)
        await gate.waitUntilStarted()
        models.cancelDownload(descriptor.id)
        await gate.resume()
        await models.waitForDownload(descriptor.id)
        XCTAssertFalse(models.installed.contains(descriptor.id))
        XCTAssertNil(models.progress[descriptor.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Models/\(descriptor.id)").path))
    }

    func testUnavailableModelFailsWithoutCallingInference() async throws {
        let engine = FixtureInference()
        let models = LocalModels(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), runtime: engine)
        do { _ = try await models.complete("hello", instructions: "Correct", modelID: "qwen-0.6b"); XCTFail("Missing installation must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Download")) }
        let calls = await engine.calls
        XCTAssertEqual(calls, 0)
    }

    nonisolated private static func fixtureDownload(_ model: LocalModelDescriptor, _ base: URL, _ progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let folder = base.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: folder.appendingPathComponent("weights"))
        progress(1)
        return folder
    }
}

private actor FixtureInference: LocalInferenceEngine {
    let gate: DownloadGate?
    let fail: Bool
    init(gate: DownloadGate? = nil, fail: Bool = false) { self.gate = gate; self.fail = fail }
    var loadedIDs = Set<String>()
    func prepare(model: LocalModelDescriptor, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws { loadedIDs.insert(model.id); await residency(loadedIDs) }
    var unloads = 0
    var cancelledUnload = false
    var calls = 0
    var lastSpeechModel: LocalModelDescriptor?
    var lastLanguage: String?
    func transcribe(_ samples: [Float], model: LocalModelDescriptor, url: URL, language: String?, residency: @Sendable (Set<String>) async -> Void) async throws -> String {
        lastSpeechModel = model; lastLanguage = language
        loadedIDs.insert(model.id); calls += 1; await residency(loadedIDs); return "hello"
    }
    func complete(_ text: String, instructions: String, id: String, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws -> String {
        loadedIDs.insert(id); calls += 1; await residency(loadedIDs)
        if let gate { await gate.wait() }
        if fail { throw FrogError.message("Fixture inference failure") }
        return text
    }
    func unload(keepingMetadata: Bool) { cancelledUnload = Task.isCancelled; loadedIDs = []; unloads += 1 }
}

private actor DownloadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func waitUntilStarted() async { while continuation == nil { await Task.yield() } }
    func resume() { continuation?.resume(); continuation = nil }
}
