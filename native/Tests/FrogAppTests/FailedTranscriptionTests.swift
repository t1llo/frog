import XCTest
import AppKit
import FrogCore
@testable import FrogApp

/// A final transcription that fails must not cost the recording when repeating it can help.
@MainActor
final class FailedTranscriptionTests: XCTestCase {
    func testTransientExternalFailureKeepsTheRecordingAndRetrySendsItAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = LocalModels(directory: directory)
        var copied: [String] = [], uploads: [[Float]] = [], issues: [String] = [], finished = 0
        let controller = makeController(recording: { SpokenRecording(seconds: 2) }, copy: { copied.append($0) })
        controller.externalTranscription = { audio, _ in
            uploads.append(audio)
            if uploads.count < 3 { throw URLError(.notConnectedToInternet) }
            return "Recovered speech."
        }
        controller.onError = { issues.append($0.localizedDescription) }
        controller.onTranscript = { _, _, _, _ in finished += 1 }
        controller.start(rule: externalRule, preferences: WorkflowPreferences(), models: models)
        await controller.waitForWork()
        controller.stop(models: models)
        await controller.waitForWork()
        XCTAssertEqual(controller.phase, .failed, "A failed upload must not discard the recording")
        XCTAssertTrue(controller.active)
        XCTAssertEqual(controller.failure, URLError(.notConnectedToInternet).localizedDescription)
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(controller.liveText.isEmpty, "An external model has recognised nothing yet")
        controller.copyPartialTranscript()
        XCTAssertTrue(copied.isEmpty)

        controller.retryTranscription()
        XCTAssertEqual(controller.phase, .transcribing)
        await controller.waitForWork()
        XCTAssertEqual(controller.phase, .failed, "A second failure keeps the recording as well")
        XCTAssertEqual(issues.count, 2)

        controller.retryTranscription()
        await controller.waitForWork()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(copied, ["Recovered speech."])
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(uploads.count, 3)
        XCTAssertEqual(uploads[0].count, 2 * 16000)
        XCTAssertEqual(uploads[1], uploads[0], "Retry sends the recording that failed, not a new one")
        XCTAssertEqual(uploads[2], uploads[0])
        XCTAssertEqual(issues.count, 2)
        controller.retryTranscription()
        await controller.waitForWork()
        XCTAssertEqual(uploads.count, 3, "A delivered recording is gone")
    }

    func testARetryDoesNotSayStillTranscribingForAPressDuringTheFailedPass() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = LocalModels(directory: directory)
        let controller = makeController(recording: { SpokenRecording(seconds: 2) }, copy: { _ in })
        var release: CheckedContinuation<Void, Never>?, uploads = 0
        controller.externalTranscription = { _, _ in
            uploads += 1
            await withCheckedContinuation { release = $0 }
            if uploads == 1 { throw URLError(.notConnectedToInternet) }
            return "Recovered speech."
        }
        controller.start(rule: externalRule, preferences: WorkflowPreferences(), models: models)
        await controller.waitForWork()
        controller.stop(models: models)
        while release == nil { await Task.yield() }
        _ = controller.showPressWhileFinishing()
        XCTAssertEqual(controller.statusText, "Still transcribing…")
        release?.resume(); release = nil
        await controller.waitForWork()
        XCTAssertEqual(controller.phase, .failed)

        controller.retryTranscription()
        while release == nil { await Task.yield() }
        XCTAssertEqual(controller.statusText, "Transcribing…", "No shortcut was pressed during the retry")
        release?.resume()
        await controller.waitForWork()
        XCTAssertEqual(controller.phase, .idle)
    }

    func testFailedLocalEndingKeepsFinishedWindowsAndRetryTranscribesOnlyTheEnding() async throws {
        let fixture = await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var copied: [String] = [], issues: [String] = []
        let controller = makeController(recording: { SpokenRecording(seconds: 65) }, copy: { copied.append($0) })
        controller.onError = { issues.append($0.localizedDescription) }
        fixture.models.idleSeconds = 0
        controller.start(rule: localRule, preferences: WorkflowPreferences(), models: fixture.models)
        await controller.waitForWork()
        try await controller.refreshPreview()
        try await controller.refreshPreview()
        await fixture.engine.failNext()
        controller.stop(models: fixture.models)
        await controller.waitForWork()
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertEqual(controller.failure, "Fixture speech model failed.")
        XCTAssertEqual(issues, ["Fixture speech model failed."])
        XCTAssertEqual(controller.liveText, "Seconds 0–29. Seconds 30–59.", "Finished windows stay visible")
        XCTAssertTrue(copied.isEmpty, "An incomplete transcript is never delivered as the result")
        await fixture.models.waitForIdleUnload()
        XCTAssertTrue(fixture.models.loaded.isEmpty, "A recording waiting for a decision must not keep the model in memory")

        controller.copyPartialTranscript()
        XCTAssertEqual(copied, ["Seconds 0–29. Seconds 30–59."])
        XCTAssertEqual(controller.phase, .failed, "Copying the partial text keeps the recording")

        controller.retryTranscription()
        await controller.waitForWork()
        XCTAssertEqual(controller.phase, .idle)
        let calls = await fixture.engine.calls
        XCTAssertEqual(calls.map(\.count), [30, 30, 5, 5].map { $0 * 16000 })
        XCTAssertEqual(calls.map(\.firstSecond), [0, 30, 60, 60])
        XCTAssertEqual(copied.last, "Seconds 0–29. Seconds 30–59. Seconds 60–64.")
        XCTAssertEqual(issues.count, 1)
        await fixture.models.unload()
    }

    func testFailuresThatARetryCannotFixStillEndTheSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = LocalModels(directory: directory)
        let permanent: [Error] = [FrogError.message("Add an API key for Fixture."), SpeechClient.StatusFailure(status: 401),
                                  SpeechClient.StatusFailure(status: 404), FrogError.message("The speech model returned no transcript.")]
        for error in permanent {
            var uploads = 0, issues: [String] = []
            let controller = makeController(recording: { SpokenRecording(seconds: 2) }, copy: { _ in XCTFail("Nothing was transcribed") })
            controller.externalTranscription = { _, _ in uploads += 1; throw error }
            controller.onError = { issues.append($0.localizedDescription) }
            controller.start(rule: externalRule, preferences: WorkflowPreferences(), models: models)
            await controller.waitForWork()
            controller.stop(models: models)
            await controller.waitForWork()
            XCTAssertEqual(controller.phase, .idle, error.localizedDescription)
            XCTAssertEqual(issues, [error.localizedDescription])
            controller.retryTranscription()
            await controller.waitForWork()
            XCTAssertEqual(uploads, 1, "A recording that ended its session is not kept")
        }

        var uploads = 0, issues: [String] = []
        let controller = makeController(recording: { ShortRecording() }, copy: { _ in XCTFail("Nothing was recorded") })
        controller.externalTranscription = { _, _ in uploads += 1; throw URLError(.timedOut) }
        controller.onError = { issues.append($0.localizedDescription) }
        controller.start(rule: externalRule, preferences: WorkflowPreferences(), models: models)
        await controller.waitForWork()
        controller.stop(models: models)
        await controller.waitForWork()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(issues, ["No speech recorded. Hold the shortcut longer, or use toggle mode."])
        XCTAssertEqual(uploads, 0)
    }

    func testLocalRecordingTooShortForTheEngineStillEndsTheSession() async throws {
        let fixture = await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        // Like Parakeet, refuse audio shorter than a second: the same samples fail on every retry.
        await fixture.engine.refuseUnderASecond()
        var issues: [String] = []
        let controller = makeController(recording: { ShortRecording(count: 8000) }, copy: { _ in XCTFail("Nothing was transcribed") })
        controller.onError = { issues.append($0.localizedDescription) }
        controller.start(rule: localRule, preferences: WorkflowPreferences(), models: fixture.models)
        await controller.waitForWork()
        controller.stop(models: fixture.models)
        await controller.waitForWork()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(issues, [TooShortFailure().localizedDescription])
        controller.retryTranscription()
        await controller.waitForWork()
        let calls = await fixture.engine.calls
        XCTAssertEqual(calls.map(\.count), [8000], "A recording that ended its session is not kept")
        await fixture.models.unload()
    }

    func testDiscardingAFailedTranscriptionDropsTheRecordingWithoutHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = LocalModels(directory: directory)
        var uploads = 0, interruptions = 0, recoveries = 0
        let controller = makeController(recording: { SpokenRecording(seconds: 2) }, copy: { _ in XCTFail("Nothing was transcribed") })
        controller.externalTranscription = { _, _ in uploads += 1; throw SpeechClient.StatusFailure(status: 503) }
        controller.onInterruption = { _ in interruptions += 1; return true }
        controller.onHistoryRecovered = { _, _ in recoveries += 1 }
        controller.start(rule: externalRule, preferences: WorkflowPreferences(), models: models)
        await controller.waitForWork()
        controller.stop(models: models)
        await controller.waitForWork()
        XCTAssertEqual(controller.phase, .failed)
        controller.interrupt(reason: .cancelled)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(controller.failure.isEmpty)
        XCTAssertEqual(interruptions, 0, "A failed request creates no History entry")
        controller.retryTranscription()
        await controller.waitForWork(); await controller.waitForHistoryRecovery()
        XCTAssertEqual(uploads, 1, "A discarded recording is never sent again")
        XCTAssertEqual(recoveries, 0)
    }

    func testRecordingShortcutCannotStartOrDeliverWhileAFailedTranscriptionWaits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = LocalModels(directory: directory)
        var uploads = 0, recordings = 0
        let controller = makeController(recording: { recordings += 1; return SpokenRecording(seconds: 2) }, copy: { _ in XCTFail("Nothing was transcribed") })
        controller.externalTranscription = { _, _ in uploads += 1; throw URLError(.networkConnectionLost) }
        let rule = externalRule
        controller.start(rule: rule, preferences: WorkflowPreferences(), models: models)
        await controller.waitForWork()
        controller.stop(models: models)
        await controller.waitForWork()
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertEqual(controller.ruleID, rule.id)
        controller.stop(models: models); controller.requestStop()
        controller.start(rule: rule, preferences: WorkflowPreferences(), models: models)
        await controller.waitForWork()
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(recordings, 1, "The kept recording is not replaced by a new one")
        controller.cancel()
        XCTAssertEqual(controller.phase, .idle)
    }

    func testFailurePopupHasRoomForItsReasonAndTheRecognisedTextWithinTheScreen() {
        let screen = NSRect(x: -1440, y: 80, width: 1440, height: 820)
        func frame(_ phase: DictationController.Phase, _ text: String = "") -> NSRect {
            DictationPopupLayout.frame(phase: phase, text: text, visibleFrame: screen)
        }
        let failed = frame(.failed), recording = frame(.recording)
        XCTAssertEqual(failed.width, recording.width)
        XCTAssertGreaterThan(failed.height, frame(.transcribing).height)
        XCTAssertEqual(failed.midX, recording.midX)
        XCTAssertEqual(failed.minY, recording.minY)
        let partial = frame(.failed, "Text recognised before the failure.")
        XCTAssertGreaterThan(partial.height, failed.height)
        let long = frame(.failed, String(repeating: "A long transcript with more words. ", count: 100))
        XCTAssertLessThanOrEqual(long.height, 220)
        let smallScreen = NSRect(x: -700, y: -200, width: 280, height: 180)
        XCTAssertTrue(smallScreen.contains(DictationPopupLayout.frame(phase: .failed, text: "Partial", visibleFrame: smallScreen)))
    }

    private func makeController(recording: @escaping @MainActor () -> any DictationRecording, copy: @escaping (String) -> Void) -> DictationController {
        DictationController(makeRecorder: recording, authorize: { true }, copy: copy, monitorKeys: false,
                            previewInterval: .seconds(3600), inputDevices: { [] }, presentsPopup: false)
    }

    private var externalRule: Rule {
        var rule = Rule.dictationPreset
        rule.action?.audioModelID = "fixture-speech"; rule.action?.audioProviderID = UUID()
        rule.action?.showRecordingPopup = false; rule.action?.output = .copy
        return rule
    }

    private var localRule: Rule {
        var rule = Rule.dictationPreset
        rule.action?.audioModelID = "whisper-base"; rule.action?.showRecordingPopup = false
        rule.action?.output = .copy
        return rule
    }

    private func makeFixture() async -> (directory: URL, models: LocalModels, engine: FailingSpeech) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = FailingSpeech()
        let models = LocalModels(directory: directory, runtime: engine, downloader: { _, base, _ in
            let url = base.appendingPathComponent("fixture")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }, freeSpace: LocalModels.unlimitedFreeSpace)
        let descriptor = LocalModelDescriptor.find("whisper-base")!
        models.download(descriptor); await models.waitForDownload(descriptor.id)
        return (directory, models, engine)
    }
}

@MainActor
private final class SpokenRecording: DictationRecording {
    private let seconds: Int
    init(seconds: Int) { self.seconds = seconds }
    func start(deviceUID: String?, samples: @escaping @Sendable ([Float]) -> Void) throws {
        samples((0..<seconds).flatMap { Array(repeating: Float($0), count: 16000) })
    }
    func stop() {}
}

@MainActor
private final class ShortRecording: DictationRecording {
    private let count: Int
    init(count: Int = 1600) { self.count = count }
    func start(deviceUID: String?, samples: @escaping @Sendable ([Float]) -> Void) throws { samples(Array(repeating: 0.1, count: count)) }
    func stop() {}
}

private actor FailingSpeech: LocalInferenceEngine {
    struct Call: Sendable {
        let count: Int
        let firstSecond: Int
    }
    var calls: [Call] = []
    var loadedIDs: Set<String> = []
    private var shouldFail = false
    private var minimumCount = 0
    func failNext() { shouldFail = true }
    func refuseUnderASecond() { minimumCount = 16000 }
    func prepare(model: LocalModelDescriptor, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws { loadedIDs.insert(model.id); await residency(loadedIDs) }
    func transcribe(_ samples: [Float], model: LocalModelDescriptor, url: URL, language: String?, residency: @Sendable (Set<String>) async -> Void) async throws -> String {
        loadedIDs.insert(model.id); await residency(loadedIDs)
        calls.append(Call(count: samples.count, firstSecond: Int(samples.first ?? 0)))
        if shouldFail { shouldFail = false; throw FixtureFailure() }
        if samples.count < minimumCount { throw TooShortFailure() }
        return "Seconds \(Int(samples.first ?? 0))–\(Int(samples.last ?? 0))."
    }
    func complete(_ text: String, instructions: String, id: String, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws -> String { text }
    func unload(keepingMetadata: Bool) { loadedIDs = [] }
}

private struct FixtureFailure: LocalizedError {
    var errorDescription: String? { "Fixture speech model failed." }
}

private struct TooShortFailure: LocalizedError {
    var errorDescription: String? { "Fixture speech model needs at least a second of audio." }
}
