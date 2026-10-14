import XCTest
import AppKit
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
        // The timer and the preview text are drawn by the popup, which observes the controller itself.
        controller.refreshRecordingFeedback(elapsed: 1)
        controller.updatePreview("Words so far")
        XCTAssertEqual(updates, 0)
        withExtendedLifetime(observation) {}
    }
    func testRecordingStateAndHistoryRecoveryStillRedrawTheWholeApp() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = DictationController(makeRecorder: { FixtureRecording() }, authorize: { true }, copy: { _ in },
                                             monitorKeys: false, inputDevices: { [] }, presentsPopup: false)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, dictationController: controller)
        controller.externalTranscription = { _, _ in "Recovered words." }
        // Recover without History, so only the controller's own state reaches the model.
        controller.onInterruption = { _ in true }
        controller.onHistoryRecovered = { _, _ in }
        var rule = Rule.dictationPreset
        rule.action?.audioModelID = "fixture-speech"; rule.action?.audioProviderID = UUID()
        rule.action?.showRecordingPopup = false
        var updates = 0
        let observation = model.objectWillChange.sink { updates += 1 }
        model.startDictation(rule)
        await controller.waitForWork()
        XCTAssertEqual(controller.phase, .recording)
        // Settings, Rules and Models turn editing off while Frog dictates: preparing and recording.
        XCTAssertEqual(updates, 2)
        controller.interrupt()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.recoveringHistoryIDs.count, 1)
        XCTAssertEqual(updates, 4, "Ending the recording and History marking its entry as recovering")
        await controller.waitForHistoryRecovery()
        XCTAssertTrue(controller.recoveringHistoryIDs.isEmpty)
        XCTAssertEqual(updates, 5, "History no longer marks the entry as recovering")
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
    func testNormalSpeechHasUsefulMeterRangeWithoutAmplifyingNoiseOrRecordedAudio() {
        let samples = AudioSamples()
        // Deterministic 200 Hz clips at representative RMS levels, not DC offsets.
        func clip(rms: Double) -> [Float] {
            (0..<1600).map { Float(sqrt(2) * rms * sin(2 * .pi * 200 * Double($0) / 16000)) }
        }
        let noise = clip(rms: 0.001), quiet = clip(rms: 0.005)
        let ordinary = clip(rms: 0.02), loud = clip(rms: 0.2)
        samples.append(noise)
        XCTAssertLessThan(samples.inputLevel, 0.1, "Background noise must not look like loud speech")
        samples.append(quiet)
        XCTAssertGreaterThan(samples.inputLevel, 0.2, "Quiet speech should be visible")
        let quietLevel = samples.inputLevel
        samples.append(ordinary)
        XCTAssertGreaterThan(samples.inputLevel, 0.45, "Normal speech must occupy useful waveform height")
        XCTAssertLessThan(samples.inputLevel, 0.8, "Normal speech needs headroom for louder words")
        XCTAssertGreaterThan(samples.inputLevel, quietLevel)
        samples.append(loud)
        XCTAssertGreaterThan(samples.inputLevel, 0.9)
        XCTAssertEqual(samples.snapshot(), noise + quiet + ordinary + loud, "Meter gain must never alter inference audio")
    }
    func testMeterCatchesSyllablesAndSettlesBetweenPhrases() throws {
        let meter = MicrophoneMeter()
        meter.append(0.6)
        let attack = try XCTUnwrap(meter.levels.last)
        XCTAssertGreaterThan(attack, 0.5, "A syllable should appear on the first feedback tick")
        meter.append(0)
        let release = try XCTUnwrap(meter.levels.last)
        XCTAssertGreaterThan(release, 0.2, "A single quiet callback must not abruptly erase the syllable")
        XCTAssertLessThan(release, attack)
        for _ in 0..<12 { meter.append(0) }
        XCTAssertEqual(meter.levels.last, 0, "Silence must settle; the meter must not keep pretending to hear speech")
        meter.append(1); meter.reset()
        XCTAssertTrue(meter.levels.allSatisfy { $0 == 0 })
        meter.append(.nan)
        XCTAssertEqual(meter.levels.last, 0)
    }
    func testPopupGeometryGrowsOnlyForRecordingAndRealTranscriptWithinTheScreen() {
        let screen = NSRect(x: -1440, y: 80, width: 1440, height: 820)
        func frame(_ phase: DictationController.Phase, _ text: String = "") -> NSRect {
            DictationPopupLayout.frame(phase: phase, text: text, visibleFrame: screen)
        }
        let loading = frame(.preparing), recording = frame(.recording)
        XCTAssertEqual(loading.size, NSSize(width: 300, height: 50))
        XCTAssertGreaterThan(recording.height, loading.height)
        XCTAssertEqual(recording.midX, loading.midX)
        XCTAssertEqual(recording.minY, loading.minY, "Expansion stays anchored to the bottom center")
        XCTAssertEqual(frame(.preparing, "Ignored prior transcript"), loading)
        XCTAssertEqual(frame(.transcribing), loading)
        XCTAssertEqual(frame(.correcting), loading)
        let short = frame(.recording, "A short sentence.")
        let longText = String(repeating: "A long transcript with more words. ", count: 100)
        let long = frame(.recording, longText)
        XCTAssertGreaterThan(short.height, recording.height)
        XCTAssertLessThan(short.height, long.height)
        XCTAssertLessThanOrEqual(long.height, 220, "Long transcripts scroll instead of covering the desktop")
        XCTAssertEqual(frame(.transcribing, longText), loading)
        XCTAssertEqual(frame(.correcting, longText), loading)
        let smallScreen = NSRect(x: -700, y: -200, width: 280, height: 180)
        XCTAssertTrue(smallScreen.contains(DictationPopupLayout.frame(phase: .recording, text: longText, visibleFrame: smallScreen)))
    }
    func testSuccessfulDeliveryReportsRawTextAndOnlyFrozenRecordingTime() async throws {
        for output: TranscriptOutput in [.copy, .paste] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let models = LocalModels(directory: directory)
            var clock = ContinuousClock.now
            var copied = "", delivered: [(Double, String)] = [], pastes = 0
            let controller = DictationController(makeRecorder: { FixtureRecording() }, authorize: {
                clock = clock.advanced(by: .seconds(60)); return true
            }, copy: { copied = $0 }, monitorKeys: false, inputDevices: { [] }, paste: {
                pastes += 1; clock = clock.advanced(by: .seconds(20))
            }, now: { clock })
            controller.externalTranscription = { _, _ in clock = clock.advanced(by: .seconds(90)); return "Raw words, 日本語 👩🏽‍💻." }
            controller.cleanup = { _, _ in clock = clock.advanced(by: .seconds(30)); return "Cleaned output." }
            controller.onSuccessfulDelivery = { delivered.append(($0, $1)) }
            var rule = Rule.dictationPreset
            rule.action?.audioModelID = "fixture"; rule.action?.audioProviderID = UUID()
            rule.action?.showRecordingPopup = false; rule.action?.output = output; rule.action?.cleanup = true
            controller.start(rule: rule, preferences: WorkflowPreferences(), models: models)
            await controller.waitForWork()
            clock = clock.advanced(by: .milliseconds(7250))
            controller.requestStop(); controller.requestStop()
            await controller.waitForWork()
            XCTAssertEqual(delivered.count, 1)
            XCTAssertEqual(delivered.first?.0 ?? 0, 7.25, accuracy: 0.0001)
            XCTAssertEqual(delivered.first?.1, "Raw words, 日本語 👩🏽‍💻.")
            XCTAssertEqual(copied, "Cleaned output.")
            XCTAssertEqual(pastes, output == .paste ? 1 : 0)
        }
    }

    func testFailedPasteRetainsCopyFallbackButDoesNotReportSuccessfulDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = LocalModels(directory: directory)
        var copied = "", finished = "", successes = 0, issues = 0
        let controller = DictationController(makeRecorder: { FixtureRecording() }, authorize: { true }, copy: { copied = $0 }, monitorKeys: false,
            inputDevices: { [] }, paste: { throw FrogError.message("Fixture target unavailable") })
        controller.externalTranscription = { _, _ in "Retained transcript" }
        controller.onSuccessfulDelivery = { _, _ in successes += 1 }
        controller.onFinish = { _, _, _, delivery in finished = delivery }
        controller.onError = { _ in issues += 1 }
        var rule = Rule.dictationPreset
        rule.action?.audioModelID = "fixture"; rule.action?.audioProviderID = UUID()
        rule.action?.showRecordingPopup = false; rule.action?.output = .paste
        controller.start(rule: rule, preferences: WorkflowPreferences(), models: models)
        await controller.waitForWork(); controller.requestStop(); await controller.waitForWork()
        XCTAssertEqual(copied, "Retained transcript")
        XCTAssertEqual(finished, "Copied")
        XCTAssertEqual(issues, 1)
        XCTAssertEqual(successes, 0)
    }
    func testPasteThatCannotHappenNamesWhatStandsInItsWay() throws {
        XCTAssertEqual(try DictationTarget.application(trusted: true, frontmost: 40, own: 7), 40)
        XCTAssertThrowsError(try DictationTarget.application(trusted: false, frontmost: 40, own: 7)) {
            // Focusing a field does not help someone whose Mac does not let Frog paste at all.
            XCTAssertEqual($0.localizedDescription, "Allow Frog in System Settings → Privacy & Security → Accessibility to paste. The transcript is copied.")
        }
        for frontmost: pid_t? in [7, nil] {
            XCTAssertThrowsError(try DictationTarget.application(trusted: true, frontmost: frontmost, own: 7)) {
                XCTAssertEqual($0.localizedDescription, "Focus an input field in another app to paste. The transcript is copied.")
            }
        }
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
        var successfulDeliveries = 0
        let controller = DictationController(makeRecorder: { FixtureRecording() }, authorize: { true }, copy: {
            copied = $0
            activeController?.cancel()
        }, monitorKeys: false)
        activeController = controller
        controller.onSuccessfulDelivery = { _, _ in successfulDeliveries += 1 }
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
        XCTAssertEqual(successfulDeliveries, 0)
    }
    func testDefaultRecordingCopiesRawTranscriptOnceWithoutCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = SuspendedSpeech()
        let models = LocalModels(directory: directory, runtime: engine, downloader: { _, base, _ in
            let url = base.appendingPathComponent("fixture")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }, freeSpace: LocalModels.unlimitedFreeSpace)
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
    func testPressWhileTranscribingSaysSoUntilTheNextRecording() async throws {
        let controller = DictationController(makeRecorder: { FixtureRecording() }, authorize: { true }, copy: { _ in },
                                             monitorKeys: false, inputDevices: { [] }, paste: {}, presentsPopup: false)
        let models = LocalModels(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var release: CheckedContinuation<Void, Never>?
        controller.externalTranscription = { _, _ in await withCheckedContinuation { release = $0 }; return "Words." }
        var rule = Rule.dictationPreset
        rule.action?.audioModelID = "fixture-speech"; rule.action?.audioProviderID = UUID()
        rule.action?.showRecordingPopup = false
        XCTAssertFalse(controller.showPressWhileFinishing(), "Nothing is being finished")
        controller.start(rule: rule, preferences: WorkflowPreferences(), models: models)
        await controller.waitForWork()
        XCTAssertFalse(controller.finishing)
        controller.stop(models: models)
        while release == nil { await Task.yield() }
        XCTAssertTrue(controller.finishing)
        XCTAssertEqual(controller.statusText, "Transcribing…")
        XCTAssertFalse(controller.showPressWhileFinishing(), "Without a popup the caller says it")
        XCTAssertEqual(controller.statusText, "Still transcribing…")
        release?.resume()
        await controller.waitForWork()
        XCTAssertEqual(controller.phase, .idle)
        controller.start(rule: rule, preferences: WorkflowPreferences(), models: models)
        await controller.waitForWork()
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertFalse(controller.pressedWhileFinishing)
        controller.cancel()
    }

    func testCancelledTranscriptionCannotChangeANewerRecordingOrRunCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = SuspendedSpeech()
        let models = LocalModels(directory: directory, runtime: engine, downloader: { _, base, _ in
            let url = base.appendingPathComponent("fixture")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }, freeSpace: LocalModels.unlimitedFreeSpace)
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
    func start(deviceUID: String?, samples: @escaping @Sendable ([Float]) -> Void) throws { samples(Array(repeating: 0.1, count: 8000)) }
    func stop() {}
}

private actor SuspendedSpeech: LocalInferenceEngine {
    var loadedIDs: Set<String> = []
    func prepare(model: LocalModelDescriptor, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws { loadedIDs.insert(model.id); await residency(loadedIDs) }
    private var continuation: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async { while continuation == nil { await Task.yield() } }
    func resume() { continuation?.resume(); continuation = nil }
    func transcribe(_ samples: [Float], model: LocalModelDescriptor, url: URL, language: String?, residency: @Sendable (Set<String>) async -> Void) async throws -> String {
        loadedIDs = [model.id]; await residency(loadedIDs)
        await withCheckedContinuation { continuation = $0 }
        return "Old transcript"
    }
    func complete(_ text: String, instructions: String, id: String, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws -> String { text }
    func unload(keepingMetadata: Bool) { loadedIDs = [] }
}
