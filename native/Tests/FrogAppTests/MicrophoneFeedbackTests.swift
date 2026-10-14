import AVFoundation
import XCTest
import FrogCore
@testable import FrogApp

/// Persistent device UIDs, as CoreAudio forms them for USB inputs.
private let deskMicrophone = "AppleUSBAudioEngine:Fixture:Desk Microphone:1"
private let unpluggedMicrophone = "AppleUSBAudioEngine:Fixture:Unplugged Microphone:2"

@MainActor
final class MicrophoneFeedbackTests: XCTestCase {
    func testAvailableSavedMicrophoneRemainsSelected() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.start(microphoneID: deskMicrophone)
        await fixture.controller.waitForWork()
        XCTAssertEqual(fixture.controller.phase, .recording)
        XCTAssertEqual(fixture.recorders.count, 1)
        XCTAssertEqual(fixture.recorders.first?.device, deskMicrophone)
        XCTAssertEqual(fixture.controller.selectedMicrophoneID, deskMicrophone)
    }

    func testSavedMicrophoneIsUsedAgainOnceItIsReconnected() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        var issues: [String] = []
        fixture.controller.onError = { issues.append($0.localizedDescription) }
        fixture.devices = []
        fixture.start(microphoneID: deskMicrophone)
        await fixture.controller.waitForWork()
        XCTAssertNil(fixture.recorders.last?.device, "An unplugged microphone records from the macOS default")
        XCTAssertNil(fixture.controller.selectedMicrophoneID)
        fixture.controller.cancel()
        // Plugged in again the device has a new device number, but the same persistent identifier.
        fixture.devices = [MicrophoneDevice(uid: deskMicrophone, name: "Test microphone")]
        fixture.start(microphoneID: deskMicrophone)
        await fixture.controller.waitForWork()
        XCTAssertEqual(fixture.recorders.last?.device, deskMicrophone)
        XCTAssertEqual(fixture.controller.selectedMicrophoneID, deskMicrophone)
        XCTAssertTrue(issues.isEmpty)
    }

    func testDeviceNumberSavedByAnEarlierVersionRecordsFromSystemDefault() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        var issues: [String] = []
        fixture.controller.onError = { issues.append($0.localizedDescription) }
        fixture.start(microphoneID: "42")
        await fixture.controller.waitForWork()
        XCTAssertEqual(fixture.controller.phase, .recording)
        XCTAssertEqual(fixture.recorders.count, 1, "A device number names no input today and must not be opened")
        XCTAssertNil(fixture.recorders.first?.device)
        XCTAssertNil(fixture.controller.selectedMicrophoneID)
        XCTAssertTrue(issues.isEmpty)
    }

    func testListedMicrophonesCarryTheIdentifierTheRecorderOpens() {
        // Passes without assertions on a Mac that has no audio input.
        for device in MicrophoneDevice.connected {
            XCTAssertNotNil(AVCaptureDevice(uniqueID: device.uid), "\(device.name) cannot be opened by its identifier")
            XCTAssertNil(UInt32(device.uid), "A persistent identifier is never a bare device number")
        }
    }

    func testExplicitlyChoosingTheActiveFallbackSavesSystemDefault() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = AppModel(dataDirectory: fixture.directory, registerShortcuts: false, dictationController: fixture.controller, modelService: fixture.models)
        defer { model.shutdown() }
        var preferences = model.configuration.preferences.workflowSettings
        preferences.microphoneID = unpluggedMicrophone
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
        preferences.microphoneID = unpluggedMicrophone
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
        XCTAssertEqual(try ConfigurationStore(directory: fixture.directory).load().preferences.workflowSettings.microphoneID, unpluggedMicrophone, "A temporary disconnection must not overwrite the saved preference")
        fixture.recorders.first?.emit(0.1)
        fixture.controller.selectMicrophone(deskMicrophone)
        XCTAssertEqual(fixture.controller.selectedMicrophoneID, deskMicrophone)
        XCTAssertEqual(fixture.recorders.last?.device, deskMicrophone)
        XCTAssertEqual(try ConfigurationStore(directory: fixture.directory).load().preferences.workflowSettings.microphoneID, deskMicrophone)
        fixture.recorders.last?.emit(0.2)
        fixture.controller.stop(models: fixture.models)
        await fixture.controller.waitForWork()
        XCTAssertTrue(audio == Array(repeating: Float(0.1), count: 3200) + Array(repeating: Float(0.2), count: 3200), "Both default-input and manually selected input must reach transcription")
    }

    func testSavedMicrophoneThatFailsToOpenRetriesDefaultWithoutAcceptingItsLateAudio() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.rejectDevice = { $0 == deskMicrophone }
        var issues: [String] = []
        var audio: [Float] = []
        fixture.controller.onError = { issues.append($0.localizedDescription) }
        fixture.controller.externalTranscription = { samples, _ in audio = samples; return "Transcript" }
        fixture.start(microphoneID: deskMicrophone)
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
        for preferred in [nil, deskMicrophone] {
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

    func testInputThatStopsDeliveringIsReplacedByTheSystemDefaultWithoutSavingIt() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        var issues: [String] = [], saved = false
        var audio: [Float] = []
        fixture.controller.externalTranscription = { samples, _ in audio = samples; return "Transcript" }
        fixture.start(microphoneID: deskMicrophone)
        await fixture.controller.waitForWork()
        fixture.controller.onError = { issues.append($0.localizedDescription) }
        fixture.controller.onMicrophoneChange = { _ in saved = true }
        fixture.recorders[0].emit(0.1)
        fixture.controller.refreshRecordingFeedback(elapsed: 1)
        // The microphone was unplugged: its capture delivers nothing more.
        fixture.devices = []
        fixture.controller.refreshRecordingFeedback(elapsed: 2)
        XCTAssertEqual(fixture.recorders.count, 1, "An input counts as lost only after two seconds without sound")
        fixture.controller.refreshRecordingFeedback(elapsed: 3)
        XCTAssertEqual(fixture.recorders.count, 2)
        XCTAssertTrue(fixture.recorders[0].stopped)
        let replacement = try XCTUnwrap(fixture.recorders.dropFirst().first, "A lost input must be replaced")
        XCTAssertNil(replacement.device, "The macOS default input takes over")
        XCTAssertNil(fixture.controller.selectedMicrophoneID, "The popup must show the input that is recording")
        XCTAssertTrue(fixture.controller.noMicrophoneInput, "The warning stays until the new input delivers")
        XCTAssertEqual(fixture.controller.statusText, "Starting microphone…")
        XCTAssertEqual(issues.count, 1, "With the popup hidden, the person must learn of the change")
        XCTAssertFalse(saved, "A fallback is not the person's choice")
        fixture.controller.refreshRecordingFeedback(elapsed: 5)
        XCTAssertEqual(fixture.recorders.count, 2, "The new input is given time to deliver its first sound")
        replacement.emit(0.2)
        fixture.controller.refreshRecordingFeedback(elapsed: 5)
        XCTAssertFalse(fixture.controller.noMicrophoneInput)
        fixture.controller.stop(models: fixture.models)
        await fixture.controller.waitForWork()
        XCTAssertTrue(audio == Array(repeating: Float(0.1), count: 3200) + Array(repeating: Float(0.2), count: 3200), "Audio from both inputs must reach transcription")
        XCTAssertEqual(issues.count, 1)
        XCTAssertFalse(saved)
    }

    func testInputThatHasNotDeliveredYetIsNotReplaced() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        var issues: [String] = []
        fixture.start(microphoneID: deskMicrophone)
        await fixture.controller.waitForWork()
        fixture.controller.onError = { issues.append($0.localizedDescription) }
        // A Bluetooth input can take longer than two seconds to start.
        fixture.controller.refreshRecordingFeedback(elapsed: 3)
        XCTAssertTrue(fixture.controller.noMicrophoneInput)
        XCTAssertEqual(fixture.recorders.count, 1)
        XCTAssertEqual(fixture.controller.selectedMicrophoneID, deskMicrophone)
        XCTAssertTrue(issues.isEmpty)
    }

    func testLostInputWithNoOtherToOpenTranscribesWhatWasRecorded() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        var issues: [String] = []
        var audio: [Float] = []
        fixture.controller.externalTranscription = { samples, _ in audio = samples; return "Transcript" }
        fixture.start()
        await fixture.controller.waitForWork()
        fixture.controller.onError = { issues.append($0.localizedDescription) }
        fixture.recorders[0].emit(0.1)
        fixture.controller.refreshRecordingFeedback(elapsed: 0)
        fixture.rejectDevice = { _ in true }
        fixture.controller.refreshRecordingFeedback(elapsed: 2)
        await fixture.controller.waitForWork()
        XCTAssertTrue(audio == Array(repeating: Float(0.1), count: 3200), "What was said before the input was lost must reach transcription")
        XCTAssertEqual(fixture.copied, ["Transcript"])
        XCTAssertEqual(issues.count, 1, "The person must learn why the recording ended")
        XCTAssertEqual(fixture.controller.phase, .idle)
        XCTAssertTrue(fixture.recorders.allSatisfy(\.stopped))
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
        fixture.controller.selectMicrophone(deskMicrophone)
        XCTAssertEqual(fixture.recorders[1].device, deskMicrophone)
        XCTAssertTrue(fixture.recorders[0].stopped)
        XCTAssertEqual(fixture.controller.selectedMicrophoneID, deskMicrophone)
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
        fixture.controller.selectMicrophone(unpluggedMicrophone)
        XCTAssertTrue(reported)
        XCTAssertFalse(saved)
        XCTAssertNil(fixture.controller.selectedMicrophoneID)
        XCTAssertEqual(fixture.controller.phase, .recording)
        XCTAssertNil(fixture.recorders.last?.device)
        fixture.recorders.last?.emit(0.1)
        fixture.controller.refreshRecordingFeedback(elapsed: 3)
        XCTAssertFalse(fixture.controller.noMicrophoneInput)
    }

    func testMicrophoneSwitchContinuesWithSystemDefaultWhenThePreviousInputIsGoneToo() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        var issues: [String] = [], saved = false
        var audio: [Float] = []
        fixture.controller.externalTranscription = { samples, _ in audio = samples; return "Transcript" }
        fixture.start(microphoneID: deskMicrophone)
        await fixture.controller.waitForWork()
        fixture.controller.onError = { issues.append($0.localizedDescription) }
        fixture.controller.onMicrophoneChange = { _ in saved = true }
        fixture.recorders[0].emit(0.1)
        // The active microphone was unplugged, and the one chosen instead cannot be opened either.
        fixture.rejectDevice = { $0 != nil }
        fixture.controller.selectMicrophone(unpluggedMicrophone)
        XCTAssertEqual(fixture.controller.phase, .recording, "A failed switch must not end the recording")
        XCTAssertNil(fixture.recorders.last?.device, "The macOS default input takes over")
        XCTAssertNil(fixture.controller.selectedMicrophoneID, "The popup must show the input that is recording")
        XCTAssertEqual(issues.count, 1)
        XCTAssertFalse(saved, "A fallback is not the person's choice")
        fixture.recorders.last?.emit(0.2)
        fixture.controller.stop(models: fixture.models)
        await fixture.controller.waitForWork()
        XCTAssertEqual(audio, Array(repeating: Float(0.1), count: 3200) + Array(repeating: Float(0.2), count: 3200))
    }

    func testMicrophoneSwitchThatLeavesNoInputTranscribesWhatWasRecorded() async throws {
        for preferred in [nil, deskMicrophone] {
            let fixture = Fixture()
            defer { fixture.cleanUp() }
            var issues: [String] = []
            var audio: [Float] = []
            fixture.controller.externalTranscription = { samples, _ in audio = samples; return "Transcript" }
            fixture.start(microphoneID: preferred)
            await fixture.controller.waitForWork()
            fixture.controller.onError = { issues.append($0.localizedDescription) }
            fixture.recorders[0].emit(0.1)
            fixture.rejectDevice = { _ in true }
            fixture.controller.selectMicrophone(unpluggedMicrophone)
            await fixture.controller.waitForWork()
            XCTAssertEqual(audio, Array(repeating: Float(0.1), count: 3200), "What was said before the switch must reach transcription")
            XCTAssertEqual(fixture.copied, ["Transcript"])
            XCTAssertEqual(issues.count, 1, "The person must learn why the recording ended")
            XCTAssertEqual(fixture.controller.phase, .idle)
            XCTAssertTrue(fixture.recorders.allSatisfy(\.stopped))
        }
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

    func testPopupInvitesSpeechOnlyOnceTheMicrophoneDeliversSound() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.start()
        await fixture.controller.waitForWork()
        XCTAssertEqual(fixture.controller.phase, .recording)
        fixture.controller.refreshRecordingFeedback(elapsed: 0)
        XCTAssertEqual(fixture.controller.statusText, "Starting microphone…", "The opened microphone has not delivered a buffer yet")
        fixture.recorders[0].emit(0)
        fixture.controller.refreshRecordingFeedback(elapsed: 0)
        XCTAssertEqual(fixture.controller.statusText, "Listening…", "Silence is sound from a running microphone")
        fixture.controller.cancel()
        fixture.start()
        await fixture.controller.waitForWork()
        fixture.recorders[0].emit(0.8)
        fixture.controller.refreshRecordingFeedback(elapsed: 0)
        XCTAssertEqual(fixture.controller.statusText, "Starting microphone…", "The next recording waits for its own microphone")
        fixture.recorders[1].emit(0.1)
        fixture.controller.refreshRecordingFeedback(elapsed: 0)
        XCTAssertEqual(fixture.controller.statusText, "Listening…")
    }

    func testChangingMicrophoneWaitsForTheNewMicrophoneBeforeListeningAgain() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.start()
        await fixture.controller.waitForWork()
        fixture.recorders[0].emit(0.1)
        fixture.controller.refreshRecordingFeedback(elapsed: 0)
        XCTAssertEqual(fixture.controller.statusText, "Listening…")
        // Sound that arrived after the last feedback tick belongs to the microphone being replaced.
        fixture.recorders[0].emit(0.1)
        fixture.controller.selectMicrophone(deskMicrophone)
        fixture.recorders[0].emit(0.9)
        fixture.controller.refreshRecordingFeedback(elapsed: 0)
        XCTAssertEqual(fixture.controller.statusText, "Starting microphone…")
        XCTAssertFalse(fixture.controller.noMicrophoneInput)
        fixture.recorders[1].emit(0.2)
        fixture.controller.refreshRecordingFeedback(elapsed: 0)
        XCTAssertEqual(fixture.controller.statusText, "Listening…")
    }

    func testPopupMicrophoneSelectionIsSavedForTheNextRecording() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = AppModel(dataDirectory: fixture.directory, registerShortcuts: false, dictationController: fixture.controller)
        fixture.start()
        await fixture.controller.waitForWork()
        fixture.controller.selectMicrophone(deskMicrophone)
        XCTAssertEqual(model.configuration.preferences.workflowSettings.microphoneID, deskMicrophone)
        XCTAssertEqual(try ConfigurationStore(directory: fixture.directory).load().preferences.workflowSettings.microphoneID, deskMicrophone)
    }

    @MainActor
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        lazy var models = LocalModels(directory: directory)
        var recorders: [InputRecorder] = []
        var rejectDevice: (String?) -> Bool = { _ in false }
        var devices = [MicrophoneDevice(uid: deskMicrophone, name: "Test microphone")]
        var copied: [String] = []
        lazy var controller = DictationController(makeRecorder: { [unowned self] in
            let recorder = InputRecorder(); recorder.rejectDevice = rejectDevice; recorders.append(recorder); return recorder
        }, authorize: { true }, copy: { [unowned self] in copied.append($0) }, monitorKeys: false, inputDevices: { [unowned self] in devices })
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
    var device: String?
    var stopped = false
    var rejectDevice: (String?) -> Bool = { _ in false }
    func start(deviceUID: String?, samples: @escaping @Sendable ([Float]) -> Void) throws {
        device = deviceUID; receive = samples
        if rejectDevice(deviceUID) { throw FrogError.message("Fixture microphone is unavailable.") }
    }
    func stop() { stopped = true }
    func emit(_ value: Float) { receive?(Array(repeating: value, count: 3200)) }
}

@MainActor
private final class FinishingRecorder: DictationRecording {
    private var receive: (@Sendable ([Float]) -> Void)?
    func start(deviceUID: String?, samples: @escaping @Sendable ([Float]) -> Void) throws {
        receive = samples; samples(Array(repeating: 0.1, count: 3200))
    }
    func stop() { receive = nil }
    func finish() async {
        await Task.yield()
        receive?(Array(repeating: 0.2, count: 3200))
        stop()
    }
}
