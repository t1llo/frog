import AppKit
import SwiftUI
import FrogCore
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

    func testARecordingEndsWhenItsWindowStopsTakingKeys() async {
        _ = NSApplication.shared
        // Neither window is shown; the notification stands for switching apps, closing or minimizing.
        func window() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            return window
        }
        let settings = window(), other = window()
        let capture = KeyCapture.CaptureView()
        settings.contentView = capture
        // As when SwiftUI takes the recorder away.
        defer { capture.onBlur = nil; settings.contentView = nil }
        XCTAssertTrue(settings.firstResponder === capture)
        var ends = 0
        let ended = expectation(description: "The recording ends")
        capture.onBlur = { ends += 1; ended.fulfill() }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: settings)
        await fulfillment(of: [ended], timeout: 1)
        XCTAssertEqual(ends, 1, "Another window losing the keyboard must not end this recording")
    }

    func testARefusalWrapsUnderTheRecorderInsteadOfWideningItsRow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        func row(_ hint: String?) -> NSSize {
            NSHostingView(rootView: CompactRow(title: "Shortcut") { HotkeyRecorder(hotkey: .constant(nil), hint: hint) }.environmentObject(model)).fittingSize
        }
        // Command-C, the longest refusal a recorder shows.
        let reserved = try XCTUnwrap(HotkeyManager.validationError(Hotkey(keyCode: 8, modifiers: 256)))
        let short = row("Reserved."), long = row(reserved)
        XCTAssertEqual(long.width, short.width, accuracy: 0.5, "A row must not grow with the length of the refusal")
        XCTAssertGreaterThan(long.height, short.height, "A long refusal must wrap onto further lines")
        XCTAssertGreaterThan(short.height, row(nil).height, "The refusal belongs under the recorder")
    }
}
