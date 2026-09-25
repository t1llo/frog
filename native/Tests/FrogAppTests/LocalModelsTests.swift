import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class LocalModelsTests: XCTestCase {
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
    var unloads = 0
    var calls = 0
    func transcribe(_ samples: [Float], id: String, url: URL, language: String?, residency: @Sendable (Set<String>) async -> Void) async throws -> String { loadedIDs.insert(id); calls += 1; await residency(loadedIDs); return "hello" }
    func complete(_ text: String, instructions: String, id: String, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws -> String {
        loadedIDs.insert(id); calls += 1; await residency(loadedIDs)
        if let gate { await gate.wait() }
        if fail { throw FrogError.message("Fixture inference failure") }
        return text
    }
    func unload() { loadedIDs = []; unloads += 1 }
}

private actor DownloadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func waitUntilStarted() async { while continuation == nil { await Task.yield() } }
    func resume() { continuation?.resume(); continuation = nil }
}
