import XCTest
import FrogCore
import WhisperKit
@testable import FrogApp

@MainActor
final class MicrophoneFeedbackTests: XCTestCase {
    func testStopIncludesTheFinalAudioDeliveredWhileCaptureFinishes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = FinishingRecorder()
        let models = LocalModels(directory: directory)
        let controller = DictationController(makeRecorder: { recorder }, authorize: { true }, copy: { _ in }, monitorKeys: false)
        var received: [Float] = []
        controller.externalTranscription = { samples, _ in received = samples; return "Complete sentence" }
        var rule = Rule.dictationPreset
        rule.action?.audioModelID = "fixture"; rule.action?.audioProviderID = UUID()
        rule.action?.showRecordingPopup = false; rule.action?.output = .copy
        controller.start(rule: rule, preferences: WorkflowPreferences(), models: models)
        await controller.waitForWork()
        controller.stop(models: models)
        await controller.waitForWork()
        XCTAssertEqual(received.count, 6400, "The final capture buffer must reach transcription before input is invalidated.")
        XCTAssertEqual(received.last, 0.2)
    }
    func testMissingInputWarnsAfterTwoSecondsAndClearsWhenAudioReturns() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.start()
        await fixture.controller.waitForWork()
        fixture.controller.refreshRecordingFeedback(elapsed: 1)
        XCTAssertFalse(fixture.controller.noMicrophoneInput)
        fixture.controller.refreshRecordingFeedback(elapsed: 2)
        XCTAssertTrue(fixture.controller.noMicrophoneInput)
        fixture.recorders[0].emit(0.1)
        fixture.controller.refreshRecordingFeedback(elapsed: 2)
        XCTAssertFalse(fixture.controller.noMicrophoneInput)
        fixture.recorders[0].emit(0)
        fixture.controller.refreshRecordingFeedback(elapsed: 3)
        XCTAssertFalse(fixture.controller.noMicrophoneInput)
        fixture.controller.refreshRecordingFeedback(elapsed: 4)
        XCTAssertTrue(fixture.controller.noMicrophoneInput)
    }

    func testSwitchingMicrophonesPreservesAudioAndRejectsStoppedInput() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        var audio: [Float] = []
        fixture.controller.externalTranscription = { samples, _ in audio = samples; return "Transcript" }
        fixture.start()
        await fixture.controller.waitForWork()
        fixture.recorders[0].emit(0.1)
        fixture.controller.selectMicrophone("42")
        XCTAssertEqual(fixture.recorders[1].device, 42)
        XCTAssertTrue(fixture.recorders[0].stopped)
        XCTAssertEqual(fixture.controller.selectedMicrophoneID, "42")
        fixture.recorders[0].emit(0.9)
        fixture.recorders[1].emit(0.2)
        fixture.controller.stop(models: fixture.models)
        await fixture.controller.waitForWork()
        XCTAssertEqual(audio, Array(repeating: Float(0.1), count: 3200) + Array(repeating: Float(0.2), count: 3200))
    }

    func testFailedMicrophoneSwitchReturnsToPreviousInput() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.start()
        await fixture.controller.waitForWork()
        var reported = false, saved = false
        fixture.controller.onError = { _ in reported = true }
        fixture.controller.onMicrophoneChange = { _ in saved = true }
        fixture.controller.selectMicrophone("404")
        XCTAssertTrue(reported)
        XCTAssertFalse(saved)
        XCTAssertNil(fixture.controller.selectedMicrophoneID)
        XCTAssertEqual(fixture.controller.phase, .recording)
        XCTAssertNil(fixture.recorders.last?.device)
        fixture.recorders.last?.emit(0.1)
        fixture.controller.refreshRecordingFeedback(elapsed: 3)
        XCTAssertFalse(fixture.controller.noMicrophoneInput)
    }

    func testNewRecordingDoesNotAcceptCallbacksFromPreviousRecording() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.start()
        await fixture.controller.waitForWork()
        fixture.controller.cancel()
        fixture.start()
        await fixture.controller.waitForWork()
        fixture.recorders[0].emit(0.8)
        fixture.controller.refreshRecordingFeedback(elapsed: 2)
        XCTAssertTrue(fixture.controller.noMicrophoneInput)
        fixture.recorders[1].emit(0.2)
        fixture.controller.refreshRecordingFeedback(elapsed: 2)
        XCTAssertFalse(fixture.controller.noMicrophoneInput)
    }

    func testPopupMicrophoneSelectionIsSavedForTheNextRecording() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = AppModel(dataDirectory: fixture.directory, registerShortcuts: false, dictationController: fixture.controller)
        fixture.start()
        await fixture.controller.waitForWork()
        fixture.controller.selectMicrophone("42")
        XCTAssertEqual(model.configuration.preferences.workflowSettings.microphoneID, "42")
        XCTAssertEqual(try ConfigurationStore(directory: fixture.directory).load().preferences.workflowSettings.microphoneID, "42")
    }

    @MainActor
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        lazy var models = LocalModels(directory: directory)
        var recorders: [InputRecorder] = []
        lazy var controller = DictationController(makeRecorder: { [unowned self] in
            let recorder = InputRecorder(); recorders.append(recorder); return recorder
        }, authorize: { true }, copy: { _ in }, monitorKeys: false, inputDevices: { [AudioDevice(id: 42, name: "Test microphone")] })
        func start() {
            var rule = Rule.dictationPreset
            rule.action?.audioModelID = "fixture"; rule.action?.audioProviderID = UUID()
            rule.action?.showRecordingPopup = false; rule.action?.output = .copy
            controller.start(rule: rule, preferences: WorkflowPreferences(), models: models)
        }
        func cleanUp() { controller.cancel(); try? FileManager.default.removeItem(at: directory) }
    }
}

@MainActor
private final class InputRecorder: DictationRecording {
    private var receive: (@Sendable ([Float]) -> Void)?
    var device: UInt32?
    var stopped = false
    func start(device: UInt32?, samples: @escaping @Sendable ([Float]) -> Void) throws { self.device = device; receive = samples }
    func stop() { stopped = true }
    func emit(_ value: Float) { receive?(Array(repeating: value, count: 3200)) }
}

@MainActor
private final class FinishingRecorder: DictationRecording {
    private var receive: (@Sendable ([Float]) -> Void)?
    func start(device: UInt32?, samples: @escaping @Sendable ([Float]) -> Void) throws {
        receive = samples; samples(Array(repeating: 0.1, count: 3200))
    }
    func stop() { receive = nil }
    func finish() async {
        await Task.yield()
        receive?(Array(repeating: 0.2, count: 3200))
        stop()
    }
}
