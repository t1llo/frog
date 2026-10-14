import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class IncrementalDictationTests: XCTestCase {
    func testNewRecordingCleanupWaitsForInterruptedHistoryInsteadOfFailingBusy() async throws {
        let fixture = await makeFixture(seconds: 2)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let textModel = try XCTUnwrap(LocalModelDescriptor.find("qwen-0.6b"))
        fixture.models.download(textModel); await fixture.models.waitForDownload(textModel.id)
        try await fixture.models.prepare(textModel.id)
        var copied = ""
        let controller = DictationController(makeRecorder: { BufferedRecording(seconds: 2) }, authorize: { true }, copy: { copied = $0 }, monitorKeys: false, previewInterval: .seconds(3600))
        let model = AppModel(dataDirectory: fixture.directory, registerShortcuts: false, dictationController: controller, modelService: fixture.models)
        defer { model.shutdown() }
        var preferences = model.configuration.preferences; preferences.historyEnabled = true
        try model.savePreferences(preferences)
        let recoveryStarted = expectation(description: "Background recognition started")
        await fixture.engine.pauseNext(recoveryStarted)
        model.startDictation(rule)
        await controller.waitForWork()
        controller.interrupt(reason: .escape)
        await fulfillment(of: [recoveryStarted], timeout: 2)
        let cleanupStarted = expectation(description: "New recording reached cleanup")
        let cleanup = try XCTUnwrap(controller.cleanup)
        controller.cleanup = { text, rule in cleanupStarted.fulfill(); return try await cleanup(text, rule) }
        controller.externalTranscription = { _, _ in "New speech" }
        var nextRule = rule
        nextRule.action?.audioProviderID = UUID(); nextRule.action?.cleanup = true
        nextRule.action?.localTextModelID = textModel.id
        model.startDictation(nextRule)
        await controller.waitForWork()
        controller.stop(models: fixture.models)
        await fulfillment(of: [cleanupStarted], timeout: 2)
        XCTAssertEqual(controller.phase, .correcting)
        XCTAssertTrue(copied.isEmpty)
        await fixture.engine.resume()
        await controller.waitForHistoryRecovery()
        await controller.waitForWork()
        XCTAssertEqual(copied, "Cleaned: New speech")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.history.first(where: { $0.interruption == .escape })?.processedText, "Seconds 0–1.")
    }

    func testInterruptedHistoryReusesCompletedAndInFlightPreviewWithoutUpdatingANewerRecording() async throws {
        let fixture = await makeFixture(seconds: 35)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var copied = ""
        let controller = DictationController(makeRecorder: { BufferedRecording(seconds: 35) }, authorize: { true }, copy: { copied = $0 }, monitorKeys: false, previewInterval: .seconds(3600))
        let model = AppModel(dataDirectory: fixture.directory, registerShortcuts: false, dictationController: controller, modelService: fixture.models)
        defer { model.shutdown() }
        var preferences = model.configuration.preferences; preferences.historyEnabled = true
        try model.savePreferences(preferences)
        fixture.models.idleSeconds = 0
        model.startDictation(rule)
        await controller.waitForWork()
        try await controller.refreshPreview()
        let started = expectation(description: "Ending preview started")
        await fixture.engine.pauseNext(started)
        let preview = Task { try await controller.refreshPreview() }
        await fulfillment(of: [started], timeout: 2)
        controller.interrupt(reason: .escape)
        model.startDictation(rule)
        await controller.waitForWork()
        XCTAssertEqual(controller.phase, .recording)
        await fixture.engine.resume()
        try await preview.value
        await controller.waitForHistoryRecovery()
        let calls = await fixture.engine.calls
        XCTAssertEqual(calls.map(\.count), [30, 5].map { $0 * 16000 })
        XCTAssertEqual(model.history.first?.processedText, "Seconds 0–29. Seconds 30–34.")
        XCTAssertEqual(model.history.first?.interruption, .escape)
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertTrue(controller.liveText.isEmpty)
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(fixture.models.loaded, ["whisper-base"], "Recovery must not release the newer recording's residency hold")
        controller.cancel()
        await fixture.models.waitForIdleUnload()
        XCTAssertTrue(fixture.models.loaded.isEmpty)
    }

    func testCancelThenRecordStartsMicrophoneWhileOldRecognitionFinishesCancelling() async throws {
        let fixture = await makeFixture(seconds: 2)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var copied = ""
        let controller = DictationController(makeRecorder: { fixture.recorder }, authorize: { true }, copy: { copied = $0 }, monitorKeys: false, previewInterval: .seconds(3600))
        let model = AppModel(dataDirectory: fixture.directory, registerShortcuts: false, dictationController: controller, modelService: fixture.models)
        model.startDictation(rule)
        await controller.waitForWork()
        let started = expectation(description: "First recognition started")
        await fixture.engine.pauseNext(started)
        let oldPreview = Task { try await controller.refreshPreview() }
        await fulfillment(of: [started], timeout: 2)
        controller.cancel()
        model.startDictation(rule)
        await controller.waitForWork()
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertNil(model.errorMessage)
        controller.stop(models: fixture.models)
        await Task.yield()
        XCTAssertEqual(controller.phase, .transcribing)
        XCTAssertTrue(copied.isEmpty)
        await fixture.engine.resume()
        _ = try? await oldPreview.value
        await controller.waitForWork()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(copied, "Seconds 0–1.")
        XCTAssertNil(model.errorMessage)
        await fixture.models.unload()
    }
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

    func testPreviewWaitsLongerTheMoreAudioEachPassHasToReadAgain() {
        let delay = { DictationController.previewDelay(interval: .seconds(2), uncommittedSamples: $0 * 16000) }
        XCTAssertEqual(delay(0), .seconds(2))
        XCTAssertEqual(delay(9), .seconds(2))
        XCTAssertEqual(delay(10), .seconds(3))
        XCTAssertEqual(delay(19), .seconds(3))
        XCTAssertEqual(delay(20), .seconds(4))
        XCTAssertEqual(delay(26), .seconds(4))
        // The pass that completes a window keeps its text, so it is not put off past the full window.
        // A window is complete once a second of audio follows it.
        XCTAssertEqual(delay(27), .seconds(4))
        XCTAssertEqual(delay(28), .milliseconds(3250))
        XCTAssertEqual(delay(29), .milliseconds(2250))
        XCTAssertEqual(delay(30), .seconds(2))
        XCTAssertEqual(delay(95), .seconds(2))
        // A test's hour-long interval must never be cut short by an almost full window.
        XCTAssertEqual(DictationController.previewDelay(interval: .seconds(3600), uncommittedSamples: 29 * 16000), .seconds(3600))
    }

    func testLivePreviewOfALongWindowRunsHalfAsOften() async throws {
        let fixture = await makeFixture(seconds: 21)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let interval = Duration.milliseconds(40)
        let controller = DictationController(makeRecorder: { fixture.recorder }, authorize: { true }, copy: { _ in }, monitorKeys: false,
                                             previewInterval: interval, inputDevices: { [] }, presentsPopup: false)
        var live = rule; live.action?.showRecordingPopup = true
        let began = ContinuousClock.now
        controller.start(rule: live, preferences: WorkflowPreferences(), models: fixture.models)
        await controller.waitForWork()
        var passes = 0
        for _ in 0..<1000 where passes < 6 {
            // A live microphone has delivered new audio before every pass.
            fixture.recorder.append(samples: 16)
            try await Task.sleep(for: .milliseconds(10))
            passes = await fixture.engine.calls.count
        }
        let elapsed = began.duration(to: .now)
        controller.cancel()
        XCTAssertGreaterThanOrEqual(passes, 6)
        // With over 20 seconds to read again, each pass waits two intervals.
        XCTAssertLessThanOrEqual(passes, Int(elapsed / (interval * 2)))
        await fixture.models.unload()
    }

    func testEndingUnderASecondAfterAFullWindowIsTranscribedWithThatWindow() async throws {
        let fixture = await makeFixture(seconds: 30)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        // Like both speech engines, refuse audio shorter than a second.
        await fixture.engine.refuseUnderASecond()
        var copied = ""
        let controller = DictationController(makeRecorder: { fixture.recorder }, authorize: { true }, copy: { copied = $0 }, monitorKeys: false,
                                             previewInterval: .seconds(3600), inputDevices: { [] }, presentsPopup: false)
        controller.start(rule: rule, preferences: WorkflowPreferences(), models: fixture.models)
        await controller.waitForWork()
        fixture.recorder.append(samples: 8000, value: 30)
        try await controller.refreshPreview()
        controller.stop(models: fixture.models)
        await controller.waitForWork()
        let calls = await fixture.engine.calls
        XCTAssertEqual(calls.map(\.count), [30 * 16000, 30 * 16000 + 8000])
        XCTAssertEqual(copied, "Seconds 0–30.")
        XCTAssertEqual(controller.phase, .idle)
        await fixture.models.unload()
    }

    func testWindowReadBeforeTheAudioAfterItArrivedIsNotReadAgain() async throws {
        let fixture = await makeFixture(seconds: 30)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var copied = ""
        let controller = DictationController(makeRecorder: { fixture.recorder }, authorize: { true }, copy: { copied = $0 }, monitorKeys: false,
                                             previewInterval: .seconds(3600), inputDevices: { [] }, presentsPopup: false)
        controller.start(rule: rule, preferences: WorkflowPreferences(), models: fixture.models)
        await controller.waitForWork()
        fixture.recorder.append(samples: 8000, value: 30)
        try await controller.refreshPreview()
        fixture.recorder.append(samples: 16000, value: 31)
        try await controller.refreshPreview()
        XCTAssertEqual(controller.liveText, "Seconds 0–29.")
        controller.stop(models: fixture.models)
        await controller.waitForWork()
        let calls = await fixture.engine.calls
        XCTAssertEqual(calls.map(\.count), [30 * 16000, 24000])
        XCTAssertEqual(calls.map(\.firstSecond), [0, 30])
        XCTAssertEqual(copied, "Seconds 0–29. Seconds 30–31.")
        await fixture.models.unload()
    }

    func testWindowsInAScriptWrittenWithoutSpacesAreJoinedWithoutOne() async throws {
        let fixture = await makeFixture(seconds: 35)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        await fixture.engine.answerWithoutSpaces()
        var copied = ""
        let controller = DictationController(makeRecorder: { fixture.recorder }, authorize: { true }, copy: { copied = $0 }, monitorKeys: false,
                                             previewInterval: .seconds(3600), inputDevices: { [] }, presentsPopup: false)
        controller.start(rule: rule, preferences: WorkflowPreferences(), models: fixture.models)
        await controller.waitForWork()
        try await controller.refreshPreview()
        try await controller.refreshPreview()
        XCTAssertEqual(controller.liveText, "第0秒到第29秒。第30秒到第34秒。")
        controller.stop(models: fixture.models)
        await controller.waitForWork()
        XCTAssertEqual(copied, "第0秒到第29秒。第30秒到第34秒。")
        await fixture.models.unload()
    }

    func testOnlyPiecesInScriptsWrittenWithSpacesAreJoinedWithOne() {
        XCTAssertEqual(DictationTranscript.join(["今日は", " いい天気です。"]), "今日はいい天気です。")
        XCTAssertEqual(DictationTranscript.join(["สวัสดี", "ครับ"]), "สวัสดีครับ")
        XCTAssertEqual(DictationTranscript.join(["Hello.", "", "World"]), "Hello. World")
        // Korean separates its words with spaces.
        XCTAssertEqual(DictationTranscript.join(["안녕하세요.", "반갑습니다."]), "안녕하세요. 반갑습니다.")
        XCTAssertEqual(DictationTranscript.join(["Frog", "日本"]), "Frog 日本")
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
    func start(deviceUID: String?, samples: @escaping @Sendable ([Float]) -> Void) throws {
        receive = samples
        append(from: 0, seconds: seconds)
    }
    func append(from start: Int, seconds: Int) {
        receive?((start..<(start + seconds)).flatMap { Array(repeating: Float($0), count: 16000) })
    }
    func append(samples count: Int, value: Float = 0) { receive?(Array(repeating: value, count: count)) }
    func stop() { receive = nil }
}

private actor CountingSpeech: LocalInferenceEngine {
    struct Call: Sendable {
        let count: Int
        let firstSecond: Int
    }
    var calls: [Call] = []
    var loadedIDs: Set<String> = []
    func prepare(model: LocalModelDescriptor, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws { loadedIDs.insert(model.id); await residency(loadedIDs) }
    private var pause: XCTestExpectation?
    private var continuation: CheckedContinuation<Void, Never>?
    private var shouldFail = false
    private var minimumCount = 0
    private var withoutSpaces = false
    func pauseNext(_ started: XCTestExpectation) { pause = started }
    func resume() { continuation?.resume(); continuation = nil }
    func failNext() { shouldFail = true }
    func refuseUnderASecond() { minimumCount = 16000 }
    func answerWithoutSpaces() { withoutSpaces = true }
    func transcribe(_ samples: [Float], model: LocalModelDescriptor, url: URL, language: String?, residency: @Sendable (Set<String>) async -> Void) async throws -> String {
        loadedIDs.insert(model.id); await residency(loadedIDs)
        calls.append(Call(count: samples.count, firstSecond: Int(samples.first ?? 0)))
        if let pause {
            self.pause = nil
            await withCheckedContinuation { continuation = $0; pause.fulfill() }
        }
        try Task.checkCancellation()
        if shouldFail { shouldFail = false; throw PreviewFailure() }
        if samples.count < minimumCount { throw PreviewFailure() }
        let first = Int(samples.first ?? 0), last = Int(samples.last ?? 0)
        return withoutSpaces ? "第\(first)秒到第\(last)秒。" : "Seconds \(first)–\(last)."
    }
    func complete(_ text: String, instructions: String, id: String, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws -> String { "Cleaned: \(text)" }
    func unload(keepingMetadata: Bool) { loadedIDs = [] }
}

private struct PreviewFailure: Error {}
