import AppKit
import SwiftUI
import FrogCore
import XCTest
@testable import FrogApp

@MainActor
final class HotkeyRecorderTests: XCTestCase {
    func testClipboardRecorderAcceptsShiftCommandV() async throws {
        try await record(chords: [(9, [.command, .shift])], expected: Hotkey(keyCode: 9, modifiers: 768))
    }

    func testValidShortcutCanBeRecordedAfterRejectedChord() async throws {
        try await record(chords: [(8, .command), (79, [.control, .option])], expected: Hotkey(keyCode: 79, modifiers: 6144))
    }

    func testRecorderKeepsRecordingWhenFocusReturnsBeforeDeferredBlur() async throws {
        try await record(chords: [(79, [.control, .option])], expected: Hotkey(keyCode: 79, modifiers: 6144), refocusAfterBlur: true)
    }

    private func record(chords: [(UInt16, NSEvent.ModifierFlags)], expected: Hotkey, refocusAfterBlur: Bool = false) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        defer { model.shutdown() }
        let host = NSHostingView(rootView: VStack {
            HotkeyRecorder(hotkey: Binding(get: { model.configuration.preferences.workflowSettings.effectiveClipboardHistoryHotkey }, set: { value in
                var workflow = model.configuration.preferences.workflowSettings
                workflow.clipboardHistoryHotkey = value
                do { try model.saveWorkflowPreferences(workflow) } catch { model.report(error) }
            }), showsClearButton: false, purpose: .clipboardHistory)
        }.frame(width: 400, height: 120).environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 400, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 200, y: 60), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(String(describing: type(of: window.firstResponder!)).contains("CaptureView"), "The native recorder must own keyboard focus")
        if refocusAfterBlur {
            let capture = try XCTUnwrap(window.firstResponder)
            window.makeFirstResponder(nil)
            window.makeFirstResponder(capture)
            try await Task.sleep(for: .milliseconds(50))
        }
        for (code, flags) in chords {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            window.sendEvent(event)
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.configuration.preferences.workflowSettings.clipboardHistoryHotkey, expected)
        XCTAssertNil(model.errorMessage)
    }
}
