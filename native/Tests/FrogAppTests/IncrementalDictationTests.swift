import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class IncrementalDictationTests: XCTestCase {
    func testStopReusesCompletedAudioAndOnlyTranscribesTheEnding() async throws {
        let fixture = await makeFixture(seconds: 95)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var copied = ""
        let controller = DictationController(makeRecorder: { fixture.recorder }, authorize: { true }, copy: { copied = $0 }, monitorKeys: false, previewInterval: .seconds(3600))
        controller.start(rule: rule, preferences: WorkflowPreferences(), models: fixture.models)
        await controller.waitForWork()
        for _ in 0..<3 { try await controller.refreshPreview() }
        controller.stop(models: fixture.models)
        await controller.waitForWork()
        let calls = await fixture.engine.calls
        XCTAssertEqual(calls.map(\.count), [30, 30, 30, 5].map { $0 * 16000 })
        XCTAssertEqual(calls.map(\.firstSecond), [0, 30, 60, 90])
        XCTAssertEqual(copied, "Seconds 0–29. Seconds 30–59. Seconds 60–89. Seconds 90–94.")
        await fixture.models.unload()
    }

    func testExactPartialCoverageNeedsNoFinalInferenceAndCleanupRunsOnce() async throws {
        let fixture = await makeFixture(seconds: 35)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var copied = "", cleanupInputs: [String] = []
        let controller = DictationController(makeRecorder: { fixture.recorder }, authorize: { true }, copy: { copied = $0 }, monitorKeys: false, previewInterval: .seconds(3600))
        controller.cleanup = { text, _ in cleanupInputs.append(text); return "Cleaned: \(text)" }
        var rule = rule; rule.action?.cleanup = true
        controller.start(rule: rule, preferences: WorkflowPreferences(), models: fixture.models)
        await controller.waitForWork()
        try await controller.refreshPreview()
        try await controller.refreshPreview()
        controller.stop(models: fixture.models)
        await controller.waitForWork()
        let calls = await fixture.engine.calls
        XCTAssertEqual(calls.map(\.count), [30, 5].map { $0 * 16000 })
        XCTAssertEqual(cleanupInputs, ["Seconds 0–29. Seconds 30–34."])
        XCTAssertEqual(copied, "Cleaned: Seconds 0–29. Seconds 30–34.")
        await fixture.models.unload()
    }

    func testWordsRecordedAfterTheLastPreviewAreIncluded() async throws {
        let fixture = await makeFixture(seconds: 31)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var copied = ""
        let controller = DictationController(makeRecorder: { fixture.recorder }, authorize: { true }, copy: { copied = $0 }, monitorKeys: false, previewInterval: .seconds(3600))
        controller.start(rule: rule, preferences: WorkflowPreferences(), models: fixture.models)
        await controller.waitForWork()
        try await controller.refreshPreview()
        try await controller.refreshPreview()
        fixture.recorder.append(from: 31, seconds: 2)
        controller.stop(models: fixture.models)
        await controller.waitForWork()
        let calls = await fixture.engine.calls
        XCTAssertEqual(calls.map(\.count), [30, 1, 3].map { $0 * 16000 })
        XCTAssertEqual(copied, "Seconds 0–29. Seconds 30–32.")
        await fixture.models.unload()
    }

    func testStopReusesPreviewAlreadyInFlight() async throws {
        let fixture = await makeFixture(seconds: 35)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var copied = ""
        let controller = DictationController(makeRecorder: { fixture.recorder }, authorize: { true }, copy: { copied = $0 }, monitorKeys: false, previewInterval: .milliseconds(1))
        let started = expectation(description: "Preview inference started")
        await fixture.engine.pauseNext(started)
        controller.start(rule: rule, preferences: WorkflowPreferences(), models: fixture.models)
        await controller.waitForWork()
        await fulfillment(of: [started], timeout: 2)
        controller.stop(models: fixture.models)
        await fixture.engine.resume()
        await controller.waitForWork()
        let calls = await fixture.engine.calls
        XCTAssertEqual(calls.map(\.count), [30, 5].map { $0 * 16000 })
        XCTAssertEqual(copied, "Seconds 0–29. Seconds 30–34.")
        await fixture.models.unload()
    }

    func testCancelledPreviewCannotPopulateANewerRecording() async throws {
        let fixture = await makeFixture(seconds: 35)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var copied = ""
        let controller = DictationController(makeRecorder: { fixture.recorder }, authorize: { true }, copy: { copied = $0 }, monitorKeys: false, previewInterval: .seconds(3600))
        controller.start(rule: rule, preferences: WorkflowPreferences(), models: fixture.models)
        await controller.waitForWork()
        let started = expectation(description: "Preview inference started")
        await fixture.engine.pauseNext(started)
        let preview = Task { try await controller.refreshPreview() }
        await fulfillment(of: [started], timeout: 2)
        controller.cancel()
        controller.start(rule: rule, preferences: WorkflowPreferences(), models: fixture.models)
        await controller.waitForWork()
        await fixture.engine.resume()
        do { try await preview.value; XCTFail("Cancelled inference must not complete") }
        catch is CancellationError { }
        XCTAssertTrue(controller.liveText.isEmpty)
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(controller.phase, .recording)
        controller.cancel()
        await fixture.models.unload()
    }

    func testFailedPreviewIsRetriedWithoutDroppingAudio() async throws {
        let fixture = await makeFixture(seconds: 35)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var copied = ""
        let controller = DictationController(makeRecorder: { fixture.recorder }, authorize: { true }, copy: { copied = $0 }, monitorKeys: false, previewInterval: .seconds(3600))
        controller.start(rule: rule, preferences: WorkflowPreferences(), models: fixture.models)
        await controller.waitForWork()
        await fixture.engine.failNext()
        do { try await controller.refreshPreview(); XCTFail("Expected preview failure") }
        catch is PreviewFailure { }
        controller.stop(models: fixture.models)
        await controller.waitForWork()
        let calls = await fixture.engine.calls
        XCTAssertEqual(calls.map(\.count), [30, 35].map { $0 * 16000 })
        XCTAssertEqual(copied, "Seconds 0–34.")
        await fixture.models.unload()
    }

    private var rule: Rule {
        var rule = Rule.dictationPreset
        rule.action?.audioModelID = "whisper-base"; rule.action?.showRecordingPopup = false
        rule.action?.output = .copy
        return rule
    }

    private func makeFixture(seconds: Int) async -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = CountingSpeech()
        let models = LocalModels(directory: directory, runtime: engine, downloader: { _, base, _ in
            let url = base.appendingPathComponent("fixture")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        })
        let descriptor = LocalModelDescriptor.find("whisper-base")!
        models.download(descriptor); await models.waitForDownload(descriptor.id)
        return Fixture(directory: directory, models: models, engine: engine, recorder: BufferedRecording(seconds: seconds))
    }

    private struct Fixture {
        let directory: URL
        let models: LocalModels
        let engine: CountingSpeech
        let recorder: BufferedRecording
    }
}

@MainActor
private final class BufferedRecording: DictationRecording {
    private let seconds: Int
    private var receive: (@Sendable ([Float]) -> Void)?
    init(seconds: Int) { self.seconds = seconds }
    func start(device: UInt32?, samples: @escaping @Sendable ([Float]) -> Void) throws {
        receive = samples
        append(from: 0, seconds: seconds)
    }
    func append(from start: Int, seconds: Int) {
        receive?((start..<(start + seconds)).flatMap { Array(repeating: Float($0), count: 16000) })
    }
    func stop() { receive = nil }
}

private actor CountingSpeech: LocalInferenceEngine {
    struct Call: Sendable {
        let count: Int
        let firstSecond: Int
    }
    var calls: [Call] = []
    var loadedIDs: Set<String> = []
    private var pause: XCTestExpectation?
    private var continuation: CheckedContinuation<Void, Never>?
    private var shouldFail = false
    func pauseNext(_ started: XCTestExpectation) { pause = started }
    func resume() { continuation?.resume(); continuation = nil }
    func failNext() { shouldFail = true }
    func transcribe(_ samples: [Float], model: LocalModelDescriptor, url: URL, language: String?, residency: @Sendable (Set<String>) async -> Void) async throws -> String {
        loadedIDs = [model.id]; await residency(loadedIDs)
        calls.append(Call(count: samples.count, firstSecond: Int(samples.first ?? 0)))
        if let pause {
            self.pause = nil
            await withCheckedContinuation { continuation = $0; pause.fulfill() }
        }
        try Task.checkCancellation()
        if shouldFail { shouldFail = false; throw PreviewFailure() }
        return "Seconds \(Int(samples.first ?? 0))–\(Int(samples.last ?? 0))."
    }
    func complete(_ text: String, instructions: String, id: String, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws -> String { text }
    func unload() { loadedIDs = [] }
}

private struct PreviewFailure: Error {}
