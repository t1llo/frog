import XCTest
import FrogCore
import WhisperKit
@testable import FrogApp

@MainActor
final class MicrophoneFeedbackTests: XCTestCase {
    func testAvailableSavedMicrophoneRemainsSelected() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.start(microphoneID: "42")
        await fixture.controller.waitForWork()
        XCTAssertEqual(fixture.controller.phase, .recording)
        XCTAssertEqual(fixture.recorders.count, 1)
        XCTAssertEqual(fixture.recorders.first?.device, 42)
        XCTAssertEqual(fixture.controller.selectedMicrophoneID, "42")
    }

    func testExplicitlyChoosingTheActiveFallbackSavesSystemDefault() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = AppModel(dataDirectory: fixture.directory, registerShortcuts: false, dictationController: fixture.controller, modelService: fixture.models)
        defer { model.shutdown() }
        var preferences = model.configuration.preferences.workflowSettings
        preferences.microphoneID = "404"
        try model.saveWorkflowPreferences(preferences)
        fixture.start(microphoneID: preferences.microphoneID)
        await fixture.controller.waitForWork()
        fixture.controller.selectMicrophone(nil)
        XCTAssertEqual(fixture.controller.phase, .recording)
        XCTAssertEqual(fixture.recorders.count, 1, "Saving the already-active default must not interrupt recording")
        XCTAssertNil(try ConfigurationStore(directory: fixture.directory).load().preferences.workflowSettings.microphoneID)
    }

    func testUnavailableSavedMicrophoneStartsWithSystemDefaultAndCanStillBeChanged() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = AppModel(dataDirectory: fixture.directory, registerShortcuts: false, dictationController: fixture.controller, modelService: fixture.models)
        defer { model.shutdown() }
        var preferences = model.configuration.preferences.workflowSettings
        preferences.microphoneID = "404"
        try model.saveWorkflowPreferences(preferences)
        var issues: [String] = []
        var audio: [Float] = []
        fixture.controller.onError = { issues.append($0.localizedDescription) }
        fixture.controller.externalTranscription = { samples, _ in audio = samples; return "Transcript" }
        fixture.start(microphoneID: preferences.microphoneID)
        await fixture.controller.waitForWork()
        XCTAssertEqual(fixture.controller.phase, .recording)
        XCTAssertEqual(fixture.recorders.count, 1)
        XCTAssertNil(fixture.recorders.first?.device, "A nil device opens the macOS default input")
        XCTAssertNil(fixture.controller.selectedMicrophoneID, "The popup must show the active fallback")
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(try ConfigurationStore(directory: fixture.directory).load().preferences.workflowSettings.microphoneID, "404", "A temporary disconnection must not overwrite the saved preference")
        fixture.recorders.first?.emit(0.1)
        fixture.controller.selectMicrophone("42")
        XCTAssertEqual(fixture.controller.selectedMicrophoneID, "42")
        XCTAssertEqual(fixture.recorders.last?.device, 42)
        XCTAssertEqual(try ConfigurationStore(directory: fixture.directory).load().preferences.workflowSettings.microphoneID, "42")
        fixture.recorders.last?.emit(0.2)
        fixture.controller.stop(models: fixture.models)
        await fixture.controller.waitForWork()
        XCTAssertTrue(audio == Array(repeating: Float(0.1), count: 3200) + Array(repeating: Float(0.2), count: 3200), "Both default-input and manually selected input must reach transcription")
    }

    func testSavedMicrophoneThatFailsToOpenRetriesDefaultWithoutAcceptingItsLateAudio() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.rejectDevice = { $0 == 42 }
        var issues: [String] = []
        var audio: [Float] = []
        fixture.controller.onError = { issues.append($0.localizedDescription) }
        fixture.controller.externalTranscription = { samples, _ in audio = samples; return "Transcript" }
        fixture.start(microphoneID: "42")
        await fixture.controller.waitForWork()
        XCTAssertEqual(fixture.controller.phase, .recording)
        XCTAssertEqual(fixture.recorders.count, 2, "The device can disappear after enumeration; opening must retry with the default")
        XCTAssertTrue(fixture.recorders.first?.stopped == true)
        XCTAssertNil(fixture.recorders.last?.device)
        XCTAssertNil(fixture.controller.selectedMicrophoneID)
        XCTAssertTrue(issues.isEmpty)
        fixture.recorders.first?.emit(0.9)
        fixture.recorders.last?.emit(0.1)
        fixture.controller.stop(models: fixture.models)
        await fixture.controller.waitForWork()
        XCTAssertTrue(audio == Array(repeating: Float(0.1), count: 3200), "Audio from the failed input must not reach transcription")
    }

    func testUnavailableDefaultFailsOnceInsteadOfPretendingToRecord() async {
        for preferred in [nil, "42"] {
            let fixture = Fixture()
            defer { fixture.cleanUp() }
            fixture.rejectDevice = { _ in true }
            var issues: [String] = []
            fixture.controller.onError = { issues.append($0.localizedDescription) }
            fixture.start(microphoneID: preferred)
            await fixture.controller.waitForWork()
            XCTAssertEqual(fixture.controller.phase, .idle)
            XCTAssertEqual(fixture.recorders.count, preferred == nil ? 1 : 2)
            XCTAssertTrue(fixture.recorders.allSatisfy(\.stopped))
            XCTAssertEqual(issues.count, 1)
        }
    }

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
        XCTAssertFalse(fixture.controller.noMicrophoneInput, "Silence still delivers valid microphone buffers")
        fixture.controller.refreshRecordingFeedback(elapsed: 5)
        XCTAssertTrue(fixture.controller.noMicrophoneInput)
    }

    func testQuietAndSilentBuffersDoNotClaimTheMicrophoneIsMissing() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.start()
        await fixture.controller.waitForWork()
        for elapsed in 1...8 {
            fixture.recorders[0].emit(elapsed.isMultiple(of: 2) ? 0 : 0.0001)
            fixture.controller.refreshRecordingFeedback(elapsed: elapsed)
            XCTAssertFalse(fixture.controller.noMicrophoneInput, "A quiet but connected microphone is still supplying audio")
        }
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
        var rejectDevice: (UInt32?) -> Bool = { _ in false }
        lazy var controller = DictationController(makeRecorder: { [unowned self] in
            let recorder = InputRecorder(); recorder.rejectDevice = rejectDevice; recorders.append(recorder); return recorder
        }, authorize: { true }, copy: { _ in }, monitorKeys: false, inputDevices: { [AudioDevice(id: 42, name: "Test microphone")] })
        func start(microphoneID: String? = nil) {
            var rule = Rule.dictationPreset
            rule.action?.audioModelID = "fixture"; rule.action?.audioProviderID = UUID()
            rule.action?.showRecordingPopup = false; rule.action?.output = .copy
            var preferences = WorkflowPreferences(); preferences.microphoneID = microphoneID
            controller.start(rule: rule, preferences: preferences, models: models)
        }
        func cleanUp() { controller.cancel(); try? FileManager.default.removeItem(at: directory) }
    }
}

@MainActor
private final class InputRecorder: DictationRecording {
    private var receive: (@Sendable ([Float]) -> Void)?
    var device: UInt32?
    var stopped = false
    var rejectDevice: (UInt32?) -> Bool = { _ in false }
    func start(device: UInt32?, samples: @escaping @Sendable ([Float]) -> Void) throws {
        self.device = device; receive = samples
        if rejectDevice(device) { throw FrogError.message("Fixture microphone is unavailable.") }
    }
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
