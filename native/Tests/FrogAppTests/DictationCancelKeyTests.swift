import Carbon
import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class DictationCancelKeyTests: XCTestCase {
    func testEscapeIsARegisteredKeyWhileRecordingAndCancelsIt() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        var reasons: [HistoryEntry.Interruption] = []
        fixture.controller.onInterruption = { reasons.append($0.reason); return false }
        XCTAssertNil(fixture.key.heldModifiers, "Escape belongs to the focused app while nothing is recorded")
        fixture.controller.start(rule: fixture.rule(), preferences: WorkflowPreferences(), models: fixture.models)
        await fixture.controller.waitForWork()
        XCTAssertEqual(fixture.controller.phase, .recording)
        XCTAssertEqual(fixture.key.heldModifiers, 0)
        fixture.key.press()
        XCTAssertEqual(fixture.controller.phase, .idle)
        XCTAssertEqual(reasons, [.escape])
        XCTAssertNil(fixture.key.heldModifiers, "Escape must go back to the focused app once the recording is cancelled")
    }

    func testHoldShortcutRegistersEscapeWithItsModifiersToo() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let held = UInt32(controlKey | optionKey)
        fixture.controller.start(rule: fixture.rule(hotkey: Hotkey(keyCode: 49, modifiers: held), mode: .hold),
                                 preferences: WorkflowPreferences(), models: fixture.models)
        await fixture.controller.waitForWork()
        XCTAssertEqual(fixture.key.heldModifiers, held)
        XCTAssertEqual(EscapeHotkey.combinations(heldModifiers: held),
                       [Hotkey(keyCode: 53, modifiers: 0), Hotkey(keyCode: 53, modifiers: held)])
        fixture.controller.cancel()

        // A toggle shortcut is released before Escape is pressed.
        fixture.controller.start(rule: fixture.rule(hotkey: Hotkey(keyCode: 49, modifiers: held), mode: .toggle),
                                 preferences: WorkflowPreferences(), models: fixture.models)
        await fixture.controller.waitForWork()
        XCTAssertEqual(fixture.key.heldModifiers, 0)
        XCTAssertEqual(EscapeHotkey.combinations(heldModifiers: 0), [Hotkey(keyCode: 53, modifiers: 0)])
    }

    func testEscapeGoesBackToTheFocusedAppWhenTheRecordingIsDelivered() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.externalTranscription = { _, _ in "Delivered transcript" }
        fixture.controller.start(rule: fixture.rule(), preferences: WorkflowPreferences(), models: fixture.models)
        await fixture.controller.waitForWork()
        XCTAssertEqual(fixture.key.heldModifiers, 0)
        fixture.controller.stop(models: fixture.models)
        await fixture.controller.waitForWork()
        XCTAssertEqual(fixture.copied, ["Delivered transcript"])
        XCTAssertEqual(fixture.controller.phase, .idle)
        XCTAssertNil(fixture.key.heldModifiers)
        // A press that was already on its way belongs to no recording.
        fixture.key.pressLate()
        XCTAssertEqual(fixture.controller.phase, .idle)
    }

    func testEscapeAloneIsAcceptedOnlyForCancellingARecording() {
        let escape = Hotkey(keyCode: 53, modifiers: 0)
        XCTAssertNil(HotkeyManager.validationError(escape, purpose: .recordingCancel))
        XCTAssertNotNil(HotkeyManager.validationError(escape))
        XCTAssertNotNil(HotkeyManager.validationError(Hotkey(keyCode: 49, modifiers: 0), purpose: .recordingCancel))
        XCTAssertNil(HotkeyManager.validationError(Hotkey(keyCode: 53, modifiers: UInt32(controlKey)), purpose: .recordingCancel))
    }

    @MainActor
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        lazy var models = LocalModels(directory: directory)
        let key = RecordedCancelKey()
        var copied: [String] = []
        lazy var controller = DictationController(makeRecorder: { SpeakingRecorder() }, authorize: { true },
                                                  copy: { [unowned self] in copied.append($0) }, monitorKeys: false,
                                                  previewInterval: .seconds(3600), inputDevices: { [] }, presentsPopup: false,
                                                  cancelKey: key)
        func rule(hotkey: Hotkey? = nil, mode: RecordingMode? = nil) -> Rule {
            var rule = Rule.dictationPreset
            rule.action?.audioModelID = "fixture"; rule.action?.audioProviderID = UUID()
            rule.action?.showRecordingPopup = false; rule.action?.output = .copy
            rule.hotkey = hotkey; rule.action?.recordingMode = mode
            return rule
        }
        func cleanUp() { controller.cancel(); try? FileManager.default.removeItem(at: directory) }
    }
}

@MainActor
private final class RecordedCancelKey: DictationCancelKey {
    /// Nil while nothing is registered.
    private(set) var heldModifiers: UInt32?
    private var onPress: (() -> Void)?
    private var last: (() -> Void)?
    func register(heldModifiers: UInt32, onPress: @escaping () -> Void) {
        self.heldModifiers = heldModifiers; self.onPress = onPress; last = onPress
    }
    func unregister() { heldModifiers = nil; onPress = nil }
    func press() { onPress?() }
    func pressLate() { last?() }
}

@MainActor
private final class SpeakingRecorder: DictationRecording {
    func start(deviceUID: String?, samples: @escaping @Sendable ([Float]) -> Void) throws {
        samples(Array(repeating: 0.1, count: 16000))
    }
    func stop() {}
}
