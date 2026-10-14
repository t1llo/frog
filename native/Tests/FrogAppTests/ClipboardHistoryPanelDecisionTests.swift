import AppKit
import XCTest
@testable import FrogApp

/// What the clipboard panel decides, on events built in the test. No panel is shown.
@MainActor
final class ClipboardHistoryPanelDecisionTests: XCTestCase {
    func testCopyShortcutFollowsTheKeyboardLayout() throws {
        func key(_ code: UInt16, _ characters: String, ignoringModifiers: String? = nil,
                 flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: ignoringModifiers ?? characters, isARepeat: false, keyCode: code))
        }
        XCTAssertTrue(ClipboardHistoryController.isCopyShortcut(try key(8, "c")), "QWERTY")
        XCTAssertTrue(ClipboardHistoryController.isCopyShortcut(try key(34, "c")), "Dvorak types C with the key QWERTY has as I")
        XCTAssertFalse(ClipboardHistoryController.isCopyShortcut(try key(8, "j")), "On Dvorak the QWERTY C key is J")
        XCTAssertTrue(ClipboardHistoryController.isCopyShortcut(try key(8, "c", ignoringModifiers: "с")),
            "A Cyrillic layout types C while Command is held")
        XCTAssertTrue(ClipboardHistoryController.isCopyShortcut(try key(8, "")), "An event without characters keeps the QWERTY position")
        XCTAssertFalse(ClipboardHistoryController.isCopyShortcut(try key(8, "c", flags: [.command, .shift])))
        XCTAssertFalse(ClipboardHistoryController.isCopyShortcut(try key(8, "c", flags: [])))
    }
}
