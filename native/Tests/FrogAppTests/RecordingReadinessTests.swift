import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class RecordingReadinessTests: XCTestCase {
    func testColdSpeechModelLoadsBeforeRecording() async throws {
        try await checkReadiness(pausing: "whisper-base", cleanup: false)
    }

    func testColdCleanupModelAlsoLoadsBeforeRecording() async throws {
        try await checkReadiness(pausing: "qwen-0.6b", cleanup: true)
    }

    func testReleasingHoldDuringPreparationCancelsBeforeMicrophoneStarts() async throws {
        try await checkReadiness(pausing: "whisper-base", cleanup: false, cancel: true)
    }

    func testPreparationFailureLeavesMicrophoneClosedAndReportsError() async throws {
        try await checkReadiness(pausing: "qwen-0.6b", cleanup: true, fail: true)
    }

    private func checkReadiness(pausing id: String, cleanup: Bool, cancel: Bool = false, fail: Bool = false) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpoint = expectation(description: "Preparation or premature microphone start")
        checkpoint.assertForOverFulfill = false
        let engine = ReadinessInference(pausing: id, checkpoint: checkpoint, fail: fail)
        let models = LocalModels(directory: directory, runtime: engine, downloader: { _, base, _ in
            let folder = base.appendingPathComponent("fixture")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        })
        let ids = cleanup ? ["whisper-base", "qwen-0.6b"] : ["whisper-base"]
        for id in ["whisper-base", "qwen-0.6b"] {
            models.download(try XCTUnwrap(LocalModelDescriptor.find(id)))
            await models.waitForDownload(id)
        }
        let recorder = ReadinessRecorder(checkpoint: checkpoint)
        let controller = DictationController(makeRecorder: { recorder }, authorize: { true }, copy: { _ in }, monitorKeys: false)
        var issue: Error?
        controller.onError = { issue = $0 }
        var rule = Rule.dictationPreset
        rule.action?.audioModelID = "whisper-base"; rule.action?.showRecordingPopup = false
        rule.action?.cleanup = cleanup; rule.action?.localTextModelID = "qwen-0.6b"
        rule.action?.recordingMode = .hold
        models.idleSeconds = 0
        controller.start(rule: rule, preferences: WorkflowPreferences(), models: models)
        let completion = Task { await controller.waitForWork() }
        await fulfillment(of: [checkpoint], timeout: 2)
        XCTAssertEqual(recorder.starts, 0, "The microphone must stay closed while a required model is loading")
        XCTAssertEqual(controller.phase, .preparing)
        XCTAssertEqual(controller.elapsed, 0)
        XCTAssertFalse(controller.noMicrophoneInput)
        XCTAssertEqual(controller.preparationMessage, id == "whisper-base" ? "Loading speech model…" : "Loading cleanup model…")
        if cancel { controller.requestStop(); XCTAssertEqual(controller.phase, .idle) }
        await engine.resume()
        await completion.value
        if cancel || fail {
            XCTAssertEqual(recorder.starts, 0)
            XCTAssertEqual(controller.phase, .idle)
            XCTAssertEqual(issue != nil, fail)
        } else {
            await models.unload()
            await models.waitForIdleUnload()
            XCTAssertEqual(models.loaded, Set(ids), "Only required models should be prepared, and remain resident during recording")
            XCTAssertEqual(recorder.starts, 1)
            XCTAssertEqual(controller.phase, .recording)
            XCTAssertNil(issue)
        }
        controller.cancel(); await models.waitForIdleUnload()
        XCTAssertTrue(models.loaded.isEmpty, "Idle unloading resumes after the session ends")
    }
}

@MainActor
private final class ReadinessRecorder: DictationRecording {
    private let checkpoint: XCTestExpectation
    var starts = 0
    init(checkpoint: XCTestExpectation) { self.checkpoint = checkpoint }
    func start(device: UInt32?, samples: @escaping @Sendable ([Float]) -> Void) throws {
        starts += 1; checkpoint.fulfill()
    }
    func stop() {}
}

private actor ReadinessInference: LocalInferenceEngine {
    var loadedIDs = Set<String>()
    private let pausing: String
    private let checkpoint: XCTestExpectation
    private let fail: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    init(pausing: String, checkpoint: XCTestExpectation, fail: Bool) { self.pausing = pausing; self.checkpoint = checkpoint; self.fail = fail }
    func prepare(model: LocalModelDescriptor, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws {
        if model.id == pausing { await withCheckedContinuation { continuation = $0; checkpoint.fulfill() } }
        try Task.checkCancellation()
        if fail && model.id == pausing { throw FrogError.message("Fixture model could not load") }
        loadedIDs.insert(model.id); await residency(loadedIDs)
    }
    func resume() { continuation?.resume(); continuation = nil }
    func transcribe(_ samples: [Float], model: LocalModelDescriptor, url: URL, language: String?, residency: @Sendable (Set<String>) async -> Void) async throws -> String { "Transcript" }
    func complete(_ text: String, instructions: String, id: String, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws -> String { text }
    func unload(keepingMetadata: Bool) { loadedIDs = [] }
}
