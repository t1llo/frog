import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class DictationControllerTests: XCTestCase {
    func testDefaultRecordingCopiesRawTranscriptOnceWithoutCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = SuspendedSpeech()
        let models = LocalModels(directory: directory, runtime: engine, downloader: { _, base, _ in
            let url = base.appendingPathComponent("fixture")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        })
        let descriptor = LocalModelDescriptor.find("whisper-base")!
        models.download(descriptor); await models.waitForDownload(descriptor.id)
        var copied: [String] = []
        var completed: [String] = []
        var cleanupCalls = 0
        let controller = DictationController(makeRecorder: { FixtureRecording() }, authorize: { true }, copy: { copied.append($0) }, monitorKeys: false)
        controller.cleanup = { _, _ in cleanupCalls += 1; return "LLM output" }
        controller.onFinish = { _, _, result, delivery in completed.append(result); XCTAssertEqual(delivery, "Copied") }
        var prefs = WorkflowPreferences(); prefs.showDictationPopup = false; prefs.audioModelID = descriptor.id
        controller.start(rule: .dictationPreset, preferences: prefs, models: models)
        await controller.waitForWork()
        controller.stop(models: models)
        controller.stop(models: models) // Repeated stop must not submit twice.
        await engine.waitUntilStarted(); await engine.resume()
        await controller.waitForWork()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(copied, ["Old transcript"])
        XCTAssertEqual(completed, copied)
        XCTAssertEqual(cleanupCalls, 0)
        await models.unload()
    }
    func testCancelledTranscriptionCannotChangeANewerRecordingOrRunCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = SuspendedSpeech()
        let models = LocalModels(directory: directory, runtime: engine, downloader: { _, base, _ in
            let url = base.appendingPathComponent("fixture")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        })
        let descriptor = LocalModelDescriptor.find("whisper-base")!
        models.download(descriptor); await models.waitForDownload(descriptor.id)
        var copied: [String] = []
        var cleanupCalls = 0
        let controller = DictationController(makeRecorder: { FixtureRecording() }, authorize: { true }, copy: { copied.append($0) }, monitorKeys: false)
        controller.cleanup = { text, _ in cleanupCalls += 1; return text }
        var prefs = WorkflowPreferences(); prefs.showDictationPopup = false; prefs.audioModelID = descriptor.id
        var rule = Rule.dictationPreset; rule.action?.cleanup = true
        controller.start(rule: rule, preferences: prefs, models: models)
        await controller.waitForWork()
        XCTAssertEqual(controller.phase, .recording)
        controller.stop(models: models)
        await engine.waitUntilStarted()
        // Capture the old work before cancellation clears the controller's handle.
        let captured = expectation(description: "Old work captured")
        let oldWork = Task { captured.fulfill(); await controller.waitForWork() }
        await fulfillment(of: [captured], timeout: 1)
        controller.cancel()
        controller.start(rule: rule, preferences: prefs, models: models)
        await controller.waitForWork()
        await engine.resume()
        await oldWork.value
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertTrue(controller.liveText.isEmpty)
        XCTAssertEqual(cleanupCalls, 0)
        XCTAssertTrue(copied.isEmpty)
        controller.cancel(); await models.unload()
    }
}

@MainActor
private final class FixtureRecording: DictationRecording {
    func start(device: UInt32?, samples: @escaping @Sendable ([Float]) -> Void) throws { samples(Array(repeating: 0.1, count: 8000)) }
    func stop() {}
}

private actor SuspendedSpeech: LocalInferenceEngine {
    var loadedIDs: Set<String> = []
    private var continuation: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async { while continuation == nil { await Task.yield() } }
    func resume() { continuation?.resume(); continuation = nil }
    func transcribe(_ samples: [Float], id: String, url: URL, language: String?, residency: @Sendable (Set<String>) async -> Void) async throws -> String {
        loadedIDs = [id]; await residency(loadedIDs)
        await withCheckedContinuation { continuation = $0 }
        return "Old transcript"
    }
    func complete(_ text: String, instructions: String, id: String, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws -> String { text }
    func unload() { loadedIDs = [] }
}
