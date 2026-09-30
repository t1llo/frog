import AppKit
import Carbon
import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class ClipboardShortcutTests: XCTestCase {
    func testOrdinaryClipboardCommandsCannotBecomeFrogShortcuts() throws {
        for code: UInt16 in [8, 9, 7] {
            let hotkey = Hotkey(keyCode: UInt32(code), modifiers: UInt32(cmdKey))
            XCTAssertNotNil(HotkeyManager.validationError(hotkey), "Ordinary Copy/Paste/Cut must stay with the focused app")
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            XCTAssertNil(HotkeyManager.hotkey(from: event))
        }
        XCTAssertNil(HotkeyManager.validationError(Hotkey(keyCode: 8, modifiers: UInt32(controlKey | shiftKey))))
    }

    func testSavedClipboardBindingLoadsButCannotBeRegistered() throws {
        var configuration = Configuration()
        let rule = Rule(hotkey: Hotkey(keyCode: 8, modifiers: UInt32(cmdKey)))
        configuration.rules = [rule]
        let restored = try ConfigurationFile.decode(ConfigurationFile.encode(configuration))
        XCTAssertEqual(restored.rules[0].hotkey, rule.hotkey)
        let manager = HotkeyManager()
        defer { manager.unregister() }
        let issues = manager.register(rules: restored.rules) { _ in XCTFail("An ordinary clipboard key must not invoke Frog") }
        XCTAssertTrue(try XCTUnwrap(issues[rule.id]).contains("reserved"))
        for modifiers in [UInt32(cmdKey | shiftKey), UInt32(cmdKey | optionKey | shiftKey)] {
            XCTAssertNotNil(HotkeyManager.validationError(Hotkey(keyCode: 9, modifiers: modifiers)))
        }
    }
}
