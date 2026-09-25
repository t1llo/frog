import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class LocalModelsTests: XCTestCase {
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
    var loadedIDs = Set<String>()
    var unloads = 0
    var calls = 0
    func transcribe(_ samples: [Float], id: String, url: URL) async throws -> String { loadedIDs.insert(id); calls += 1; return "hello" }
    func complete(_ text: String, instructions: String, id: String, url: URL) async throws -> String { loadedIDs.insert(id); calls += 1; return text }
    func unload() { loadedIDs = []; unloads += 1 }
}

private actor DownloadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func waitUntilStarted() async { while continuation == nil { await Task.yield() } }
    func resume() { continuation?.resume(); continuation = nil }
}
