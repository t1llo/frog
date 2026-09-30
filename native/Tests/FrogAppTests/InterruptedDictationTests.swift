import AppKit
import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class InterruptedDictationTests: XCTestCase {
    func testNativeEscapeRecordsAnInterruptionWithoutDelivery() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(monitorKeys: true)
        defer { fixture.cleanUp() }
        let started = expectation(description: "Escaped speech recovery started")
        let gate = TranscriptGate(started: started)
        fixture.controller.externalTranscription = { _, _ in await gate.wait() }
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSView(); window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        await fixture.start()
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApplication.shared.sendEvent(escape)
        XCTAssertEqual(fixture.controller.phase, .idle)
        await fulfillment(of: [started], timeout: 2)
        let id = try XCTUnwrap(fixture.model.history.first?.id)
        XCTAssertEqual(fixture.model.history.first?.interruption, .escape)
        XCTAssertTrue(fixture.controller.recoveringHistoryIDs.contains(id))
        await gate.resume("Full transcript recovered after Escape.")
        await fixture.controller.waitForHistoryRecovery()
        XCTAssertEqual(fixture.model.history.first?.id, id)
        XCTAssertEqual(fixture.model.history.first?.processedText, "Full transcript recovered after Escape.")
        XCTAssertEqual(fixture.model.history.first?.transcriptState, .complete)
        XCTAssertTrue(fixture.controller.recoveringHistoryIDs.isEmpty)
        XCTAssertTrue(fixture.copied.isEmpty)
    }

    func testEscapeRecoversFinalAudioAndPersistsItsMarkerWithoutDeliveryOrCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var received: [Float] = []
        fixture.controller.externalTranscription = { audio, _ in received = audio; return "Full interrupted transcript" }
        await fixture.start(cleanup: true)
        fixture.controller.interrupt(reason: .escape)
        fixture.controller.interrupt(reason: .escape)
        XCTAssertEqual(fixture.controller.phase, .idle)
        XCTAssertEqual(fixture.model.history.count, 1, "History should show the interruption immediately")
        await fixture.controller.waitForHistoryRecovery()
        XCTAssertEqual(received.count, 3200, "Recovery must drain the final microphone buffer")
        XCTAssertEqual(received.last, 0.2)
        let entry = try XCTUnwrap(fixture.model.history.first)
        XCTAssertEqual(entry.interruption, .escape)
        XCTAssertEqual(entry.transcriptState, .complete)
        XCTAssertEqual(entry.category, .audio)
        XCTAssertEqual(entry.processedText, "Full interrupted transcript")
        XCTAssertTrue(fixture.copied.isEmpty)
        XCTAssertEqual(fixture.cleanups, 0)
        XCTAssertTrue(fixture.recorders[0].stopped)
        XCTAssertEqual(try HistoryStore(directory: fixture.directory).load(preferences: fixture.model.configuration.preferences), [entry])
    }

    func testEscapeDuringRecognitionReusesItsRequestWithoutChangingANewerRecording() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let started = expectation(description: "Transcription started")
        let gate = TranscriptGate(started: started)
        var requests = 0
        fixture.controller.externalTranscription = { _, _ in
            requests += 1
            return requests == 1 ? await gate.wait() : "New recording"
        }
        await fixture.start()
        fixture.controller.stop(models: fixture.model.localModels)
        await fulfillment(of: [started], timeout: 2)
        fixture.controller.interrupt(reason: .escape)
        await fixture.start(name: "New rule")
        await gate.resume("Recovered old recording")
        await fixture.controller.waitForHistoryRecovery()
        XCTAssertEqual(requests, 1, "Escape must reuse in-flight provider work")
        XCTAssertEqual(fixture.controller.phase, .recording)
        XCTAssertTrue(fixture.controller.liveText.isEmpty)
        XCTAssertTrue(fixture.copied.isEmpty)
        XCTAssertEqual(fixture.model.history.first?.processedText, "Recovered old recording")
        XCTAssertEqual(fixture.model.history.first?.ruleName, "Interrupted rule")
        fixture.controller.stop(models: fixture.model.localModels)
        await fixture.controller.waitForWork()
        XCTAssertEqual(fixture.copied, ["New recording"])
        XCTAssertEqual(fixture.model.history.count, 2)
        XCTAssertEqual(fixture.model.history.filter { $0.interruption == .escape }.count, 1)
    }

    func testEscapeDuringCleanupSavesRawSpeechWithoutWaitingForCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let started = expectation(description: "Cleanup started")
        let gate = TranscriptGate(started: started)
        fixture.controller.externalTranscription = { _, _ in "Raw speech" }
        fixture.controller.cleanup = { _, _ in await gate.wait() }
        await fixture.start(cleanup: true)
        fixture.controller.stop(models: fixture.model.localModels)
        await fulfillment(of: [started], timeout: 2)
        let captured = expectation(description: "Original work captured")
        let originalWork = Task { captured.fulfill(); await fixture.controller.waitForWork() }
        await fulfillment(of: [captured], timeout: 2)
        fixture.controller.interrupt(reason: .escape)
        await fixture.controller.waitForHistoryRecovery()
        XCTAssertEqual(fixture.model.history.first?.processedText, "Raw speech")
        XCTAssertEqual(fixture.model.history.first?.interruption, .escape)
        await gate.resume("Late cleanup")
        await originalWork.value
        XCTAssertTrue(fixture.copied.isEmpty)
        XCTAssertEqual(fixture.model.history.count, 1)
    }

    func testHistoryOffOrInvalidatedBeforeEscapeDoesNotTranscribeOrSave() async throws {
        for enabledAtStart in [false, true] {
            let fixture = try Fixture(historyEnabled: enabledAtStart)
            defer { fixture.cleanUp() }
            var requests = 0
            fixture.controller.externalTranscription = { _, _ in requests += 1; return "Must not be saved" }
            await fixture.start()
            if enabledAtStart { try fixture.setHistory(false) }
            try fixture.setHistory(true)
            fixture.controller.interrupt(reason: .escape)
            await fixture.controller.waitForHistoryRecovery()
            XCTAssertEqual(requests, 0)
            XCTAssertTrue(fixture.model.history.isEmpty)
            XCTAssertTrue(fixture.copied.isEmpty)
        }
    }

    func testClearingImmediatelyAfterEscapeCancelsRecognitionBeforeItStarts() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var requests = 0
        fixture.controller.externalTranscription = { _, _ in requests += 1; return "Must not be sent" }
        await fixture.start()
        fixture.controller.interrupt(reason: .escape)
        try fixture.model.clearHistory()
        await fixture.controller.waitForHistoryRecovery()
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(fixture.recorders[0].stopped)
        XCTAssertTrue(fixture.model.history.isEmpty)
    }

    func testDeletedClearedOrDisabledHistoryCannotBeRepopulatedByRecovery() async throws {
        for action in ["delete", "clear", "disable"] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let started = expectation(description: "Recovery started for \(action)")
            let gate = TranscriptGate(started: started)
            var requestCancelled = false
            fixture.controller.externalTranscription = { _, _ in
                let text = await gate.wait(); requestCancelled = Task.isCancelled; return text
            }
            await fixture.start()
            fixture.controller.interrupt(reason: .escape)
            let id = try XCTUnwrap(fixture.model.history.first?.id)
            await fulfillment(of: [started], timeout: 2)
            switch action {
            case "delete": try fixture.model.deleteHistory(id: id)
            case "clear": try fixture.model.clearHistory()
            default: try fixture.setHistory(false); try fixture.setHistory(true)
            }
            await gate.resume("Late private transcript")
            await fixture.controller.waitForHistoryRecovery()
            XCTAssertTrue(requestCancelled, "Invalidating history must also cancel its transcription work")
            XCTAssertTrue(fixture.controller.recoveringHistoryIDs.isEmpty)
            if action == "disable" {
                XCTAssertEqual(fixture.model.history.count, 1, "Disabling preserves entries already saved")
                XCTAssertTrue(fixture.model.history[0].processedText.isEmpty)
            } else { XCTAssertTrue(fixture.model.history.isEmpty) }
            let saved = (try? String(contentsOf: fixture.model.historyFileURL, encoding: .utf8)) ?? ""
            XCTAssertFalse(saved.contains("Late private transcript"))
        }
    }

    func testRecoveryFailureKeepsTheInterruptedEntryAndAvailablePreview() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.externalTranscription = { _, _ in throw FrogError.message("Fixture offline") }
        await fixture.start()
        fixture.controller.updatePreview("Available partial speech")
        fixture.controller.interrupt(reason: .escape)
        await fixture.controller.waitForHistoryRecovery()
        XCTAssertEqual(fixture.model.history.first?.processedText, "Available partial speech")
        XCTAssertEqual(fixture.model.history.first?.transcriptState, .failed)
        XCTAssertEqual(fixture.model.history.first?.interruption, .escape)
        XCTAssertTrue(fixture.copied.isEmpty)
    }

    func testEscapeDuringPreparationDoesNotCreateAnEmptyRecording() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.externalTranscription = { _, _ in XCTFail("No capture took place"); return "" }
        var rule = Rule.dictationPreset
        rule.action?.audioModelID = "fixture-speech"; rule.action?.audioProviderID = UUID()
        rule.action?.showRecordingPopup = false
        fixture.model.startDictation(rule)
        XCTAssertEqual(fixture.controller.phase, .preparing)
        fixture.controller.interrupt(reason: .escape)
        await fixture.controller.waitForHistoryRecovery()
        XCTAssertTrue(fixture.recorders.isEmpty)
        XCTAssertTrue(fixture.model.history.isEmpty)
        XCTAssertEqual(fixture.controller.phase, .idle)
    }

    func testCancelledDeliveryMarksTheExistingCompletedEntryWithoutDuplicatingIt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.afterCopy = { [weak fixture] in fixture?.controller.interrupt(reason: .escape) }
        fixture.controller.externalTranscription = { _, _ in "Raw transcript" }
        fixture.controller.cleanup = { _, _ in "Cleaned transcript" }
        await fixture.start(cleanup: true)
        fixture.controller.stop(models: fixture.model.localModels)
        await fixture.controller.waitForWork()
        await fixture.controller.waitForHistoryRecovery()
        XCTAssertEqual(fixture.model.history.count, 1)
        XCTAssertEqual(fixture.model.history.first?.interruption, .escape)
        XCTAssertEqual(fixture.model.history.first?.originalText, "Raw transcript")
        XCTAssertEqual(fixture.model.history.first?.processedText, "Cleaned transcript")
        XCTAssertEqual(fixture.copied, ["Cleaned transcript"], "Recovery must not redeliver an already-copied result")
    }

    @MainActor
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var recorders: [InterruptedRecorder] = []
        var copied: [String] = []
        var cleanups = 0
        var afterCopy: (() -> Void)?
        let monitorKeys: Bool
        lazy var controller = DictationController(makeRecorder: { [unowned self] in
            let recorder = InterruptedRecorder(); recorders.append(recorder); return recorder
        }, authorize: { true }, copy: { [unowned self] in copied.append($0); afterCopy?() }, monitorKeys: monitorKeys)
        lazy var model = AppModel(dataDirectory: directory, registerShortcuts: false, dictationController: controller)
        init(historyEnabled: Bool = true, monitorKeys: Bool = false) throws {
            self.monitorKeys = monitorKeys
            try setHistory(historyEnabled)
            controller.localCleanupModel = { _ in nil }
            controller.cleanup = { [unowned self] text, _ in cleanups += 1; return text }
        }
        func setHistory(_ enabled: Bool) throws {
            var preferences = model.configuration.preferences; preferences.historyEnabled = enabled
            try model.savePreferences(preferences)
        }
        func start(name: String = "Interrupted rule", cleanup: Bool = false) async {
            var rule = Rule.dictationPreset; rule.name = name
            rule.action?.audioModelID = "fixture-speech"; rule.action?.audioProviderID = UUID()
            rule.action?.cleanup = cleanup; rule.action?.output = .copy; rule.action?.showRecordingPopup = false
            model.startDictation(rule)
            await controller.waitForWork()
        }
        func cleanUp() { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
    }
}

@MainActor
private final class InterruptedRecorder: DictationRecording {
    private var receive: (@Sendable ([Float]) -> Void)?
    private(set) var stopped = false
    func start(device: UInt32?, samples: @escaping @Sendable ([Float]) -> Void) throws {
        receive = samples; samples(Array(repeating: 0.1, count: 1600))
    }
    func stop() { stopped = true; receive = nil }
    func finish() async { receive?(Array(repeating: 0.2, count: 1600)); stop() }
}

private actor TranscriptGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<String, Never>?
    init(started: XCTestExpectation) { self.started = started }
    func wait() async -> String { await withCheckedContinuation { continuation = $0; started.fulfill() } }
    func resume(_ text: String) { continuation?.resume(returning: text); continuation = nil }
}
