import XCTest
import FrogCore
@testable import FrogApp

/// Muting the Mac is a comfort of the recording, not a condition for it.
@MainActor
final class RecordingMuteFallbackTests: XCTestCase {
    func testOutputThatCannotBeMutedStillRecordsAndSaysWhyOnce() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.mute.failure = FrogError.message("This audio output does not support muting. Disable mute while recording or choose another output.")
        fixture.start()
        await fixture.controller.waitForWork()
        XCTAssertEqual(fixture.controller.phase, .recording, "Sound that keeps playing must not refuse the recording")
        XCTAssertEqual(fixture.recorder.starts, 1)
        XCTAssertEqual(fixture.issues, ["Recording without muting the Mac. This audio output does not support muting. Disable mute while recording or choose another output."])
        fixture.controller.cancel()

        fixture.start()
        await fixture.controller.waitForWork()
        XCTAssertEqual(fixture.controller.phase, .recording)
        XCTAssertEqual(fixture.mute.attempts, 2, "Every recording tries again; the output may have changed")
        XCTAssertEqual(fixture.issues.count, 1, "The same problem is not repeated before every recording")
        fixture.controller.cancel()

        // An output that works again and fails later is a new problem worth saying.
        fixture.mute.failure = nil
        fixture.start()
        await fixture.controller.waitForWork()
        XCTAssertTrue(fixture.mute.muted)
        fixture.controller.cancel()
        XCTAssertFalse(fixture.mute.muted)
        fixture.mute.failure = FrogError.message("The audio output could not be muted.")
        fixture.start()
        await fixture.controller.waitForWork()
        XCTAssertEqual(fixture.controller.phase, .recording)
        XCTAssertEqual(fixture.issues.last, "Recording without muting the Mac. The audio output could not be muted.")
        XCTAssertEqual(fixture.issues.count, 2)
    }

    func testMutedOutputIsRestoredWhenTheRecordingEndsAndLeftAloneWhenTheSettingIsOff() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.start(mute: false)
        await fixture.controller.waitForWork()
        XCTAssertEqual(fixture.controller.phase, .recording)
        XCTAssertEqual(fixture.mute.attempts, 0)
        fixture.controller.cancel()

        fixture.start()
        await fixture.controller.waitForWork()
        XCTAssertTrue(fixture.mute.muted)
        fixture.controller.stop(models: fixture.models)
        await fixture.controller.waitForWork()
        XCTAssertEqual(fixture.controller.phase, .idle)
        XCTAssertFalse(fixture.mute.muted)
        XCTAssertTrue(fixture.issues.isEmpty)
    }

    @MainActor
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        lazy var models = LocalModels(directory: directory)
        let mute = FixtureMute()
        let recorder = FixtureRecorder()
        var issues: [String] = []
        lazy var controller: DictationController = {
            let controller = DictationController(makeRecorder: { [recorder] in recorder }, authorize: { true }, copy: { _ in },
                                                 monitorKeys: false, previewInterval: .seconds(3600), inputDevices: { [] },
                                                 paste: {}, presentsPopup: false, outputMute: mute)
            controller.onError = { [unowned self] in issues.append($0.localizedDescription) }
            controller.externalTranscription = { _, _ in "Transcript" }
            return controller
        }()
        func start(mute: Bool = true) {
            var rule = Rule.dictationPreset
            rule.action?.audioModelID = "fixture"; rule.action?.audioProviderID = UUID()
            rule.action?.showRecordingPopup = false; rule.action?.output = .copy
            var preferences = WorkflowPreferences(); preferences.muteWhileRecording = mute
            controller.start(rule: rule, preferences: preferences, models: models)
        }
        func cleanUp() { controller.cancel(); try? FileManager.default.removeItem(at: directory) }
    }
}

private final class FixtureMute: OutputMuting {
    var failure: Error?
    var attempts = 0
    var muted = false
    func begin() throws {
        attempts += 1
        if let failure { throw failure }
        muted = true
    }
    func restore() { muted = false }
}

@MainActor
private final class FixtureRecorder: DictationRecording {
    var starts = 0
    func start(device: UInt32?, samples: @escaping @Sendable ([Float]) -> Void) throws {
        starts += 1
        samples(Array(repeating: 0.1, count: 16000))
    }
    func stop() {}
}
