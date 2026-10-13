import XCTest
@testable import FrogApp

@MainActor
final class ShortcutRecordingTests: XCTestCase {
    func testShortcutsStayOffUntilTheLastRecorderEnds() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        let first = UUID(), second = UUID()
        XCTAssertFalse(model.isRecordingShortcut)
        model.beginShortcutRecording(first)
        XCTAssertTrue(model.isRecordingShortcut)
        // Clicking a second recorder starts it before the first notices that it lost the keyboard.
        model.beginShortcutRecording(second)
        model.endShortcutRecording(first)
        XCTAssertTrue(model.isRecordingShortcut, "Shortcuts must stay off while another recorder is still recording")
        model.endShortcutRecording(second)
        XCTAssertFalse(model.isRecordingShortcut)
    }

    func testARecorderThatEndsTwiceDoesNotEndAnotherOnesRecording() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        let first = UUID(), second = UUID()
        model.beginShortcutRecording(first)
        // A recorder reports its end when it stops and again when it leaves the screen.
        model.endShortcutRecording(first); model.endShortcutRecording(first)
        XCTAssertFalse(model.isRecordingShortcut)
        model.beginShortcutRecording(second)
        model.endShortcutRecording(first)
        XCTAssertTrue(model.isRecordingShortcut)
        model.beginShortcutRecording(second)
        model.endShortcutRecording(second)
        XCTAssertFalse(model.isRecordingShortcut, "Starting the same recorder twice must not need two ends")
    }
}
