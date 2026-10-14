import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class DictationHintTests: XCTestCase {
    func testHoldRecordingStartedWithoutItsShortcutIsNotStoppedByReleasingIt() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        // The command bar and the Record button start a hold-to-record rule without the key down.
        fixture.controller.start(rule: fixture.rule, preferences: WorkflowPreferences(), models: fixture.models)
        await fixture.controller.waitForWork()
        XCTAssertEqual(fixture.controller.phase, .recording)
        XCTAssertEqual(fixture.controller.hint, "⌥Space to stop · Esc to cancel")
    }

    func testHoldRecordingStartedByItsShortcutStopsWhenTheKeyIsReleased() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.start(rule: fixture.rule, preferences: WorkflowPreferences(), models: fixture.models, shortcutHeld: true)
        await fixture.controller.waitForWork()
        XCTAssertEqual(fixture.controller.phase, .recording)
        XCTAssertEqual(fixture.controller.hint, "Release ⌥Space to stop · Esc to cancel")
    }

    func testToggleRecordingNamesItsShortcutHoweverItStarted() async {
        for held in [false, true] {
            let fixture = Fixture()
            var rule = fixture.rule; rule.action?.recordingMode = .toggle
            fixture.controller.start(rule: rule, preferences: WorkflowPreferences(), models: fixture.models, shortcutHeld: held)
            await fixture.controller.waitForWork()
            XCTAssertEqual(fixture.controller.hint, "⌥Space to stop · Esc to cancel")
            fixture.cleanUp()
        }
    }

    @MainActor
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        lazy var models = LocalModels(directory: directory)
        let controller = DictationController(makeRecorder: { SilentRecorder() }, authorize: { true }, copy: { _ in },
                                             monitorKeys: false, inputDevices: { [] }, presentsPopup: false)
        var rule: Rule {
            var rule = Rule.dictationPreset
            rule.action?.audioModelID = "fixture"; rule.action?.audioProviderID = UUID()
            rule.action?.showRecordingPopup = false; rule.action?.recordingMode = .hold
            return rule
        }
        func cleanUp() { controller.cancel(); try? FileManager.default.removeItem(at: directory) }
    }
}

@MainActor
private final class SilentRecorder: DictationRecording {
    func start(deviceUID: String?, samples: @escaping @Sendable ([Float]) -> Void) throws {}
    func stop() {}
}
