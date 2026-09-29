import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class DictationControllerTests: XCTestCase {
    func testMicrophoneOnlyUpdatesDoNotInvalidateTheWholeApp() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = DictationController(monitorKeys: false)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, dictationController: controller)
        var updates = 0
        let observation = model.objectWillChange.sink { updates += 1 }
        for _ in 0..<10 { controller.refreshRecordingFeedback(elapsed: 0) }
        XCTAssertEqual(updates, 0)
        controller.refreshRecordingFeedback(elapsed: 1)
        XCTAssertEqual(updates, 1)
        withExtendedLifetime(observation) {}
    }
    func testMicrophoneMeterReflectsSamplesAndReturnsToSilence() {
        let samples = AudioSamples()
        XCTAssertEqual(samples.inputLevel, 0)
        samples.append(Array(repeating: 0.05, count: 1600))
        let quiet = samples.inputLevel
        XCTAssertGreaterThan(quiet, 0)
        samples.append(Array(repeating: 0.1, count: 1600))
        XCTAssertGreaterThan(samples.inputLevel, quiet)
        samples.append(Array(repeating: 0, count: 1600))
        XCTAssertEqual(samples.inputLevel, 0)
        samples.append(Array(repeating: 1, count: 1600))
        XCTAssertEqual(samples.inputLevel, 1)
        samples.clear()
        XCTAssertEqual(samples.inputLevel, 0)
    }
    func testSilentPreviewDoesNotEraseRecognizedSpeech() {
        let controller = DictationController(monitorKeys: false)
        controller.updatePreview("First sentence. Second sentence.")
        controller.updatePreview("   \n")
        XCTAssertEqual(controller.liveText, "First sentence. Second sentence.")
    }
    func testPreviewRetainsEarlierWindowsAndRevisesOnlyCurrentWindow() {
        let controller = DictationController(monitorKeys: false)
        controller.updatePreview("First thirty seconds.", completingWindow: true)
        controller.updatePreview("New sentence")
        controller.updatePreview("New sentence revised.")
        XCTAssertEqual(controller.liveText, "First thirty seconds. New sentence revised.")
        controller.updatePreview("", completingWindow: true)
        controller.updatePreview("Next minute.")
        XCTAssertEqual(controller.liveText, "First thirty seconds. New sentence revised. Next minute.")
    }
    func testCompletedAudioAppearsInHistoryAndSurvivesReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = DictationController(makeRecorder: { FixtureRecording() }, authorize: { true }, copy: { _ in }, monitorKeys: false)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, dictationController: controller)
        var prefs = model.configuration.preferences; prefs.historyEnabled = true
        try model.savePreferences(prefs)
        var rule = Rule.dictationPreset
        rule.action?.audioModelID = "fixture-speech"
        rule.action?.audioProviderID = UUID()
        rule.action?.showRecordingPopup = false
        rule.action?.output = .copy
        controller.externalTranscription = { _, _ in "An audio history entry." }
        model.startDictation(rule)
        await controller.waitForWork()
        controller.stop(models: model.localModels)
        await controller.waitForWork()
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history.first?.category, .audio)
        XCTAssertEqual(model.history.first?.processedText, "An audio history entry.")
        XCTAssertEqual(try HistoryStore(directory: directory).load(preferences: prefs), model.history)
    }
    func testTranscriptAlreadyCopiedIsNotLostFromHistoryWhenDeliveryIsCancelled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        weak var activeController: DictationController?
        var copied = ""
        let controller = DictationController(makeRecorder: { FixtureRecording() }, authorize: { true }, copy: {
            copied = $0
            activeController?.cancel()
        }, monitorKeys: false)
        activeController = controller
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, dictationController: controller)
        var prefs = model.configuration.preferences; prefs.historyEnabled = true
        try model.savePreferences(prefs)
        var rule = Rule.dictationPreset
        rule.action?.audioModelID = "fixture-speech"; rule.action?.audioProviderID = UUID()
        rule.action?.showRecordingPopup = false; rule.action?.output = .copy
        controller.externalTranscription = { _, _ in "Completed before delivery was cancelled." }
        model.startDictation(rule)
        await controller.waitForWork()
        controller.stop(models: model.localModels)
        await controller.waitForWork()
        XCTAssertEqual(copied, "Completed before delivery was cancelled.")
        XCTAssertEqual(model.history.first?.processedText, copied)
        XCTAssertEqual(model.history.first?.category, .audio)
    }
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
        var rule = Rule.dictationPreset; rule.action?.audioModelID = descriptor.id; rule.action?.showRecordingPopup = false
        controller.start(rule: rule, preferences: prefs, models: models)
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
        rule.action?.audioModelID = descriptor.id; rule.action?.showRecordingPopup = false
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
    func transcribe(_ samples: [Float], model: LocalModelDescriptor, url: URL, language: String?, residency: @Sendable (Set<String>) async -> Void) async throws -> String {
        loadedIDs = [model.id]; await residency(loadedIDs)
        await withCheckedContinuation { continuation = $0 }
        return "Old transcript"
    }
    func complete(_ text: String, instructions: String, id: String, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws -> String { text }
    func unload() { loadedIDs = [] }
}
