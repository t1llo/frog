import XCTest
@testable import FrogCore

final class ConfigShortcutValueTests: XCTestCase {
    private struct Keys: ConfigSection {
        var open = try! Shortcut("ctrl+alt+space")
        var paste: Shortcut?
    }

    func testShortcutsRoundTripThroughTextAndHotkeys() throws {
        for text in ["ctrl+alt+space", "shift+cmd+v", "ctrl+escape", "alt+cmd+f12", "ctrl+keycode-10", "cmd+left-bracket"] {
            let shortcut = try Shortcut(text)
            XCTAssertEqual(shortcut.description, text)
            XCTAssertEqual(try Shortcut(shortcut.hotkey), shortcut)
        }
        XCTAssertEqual(try Shortcut("CMD+Shift+V").hotkey, Hotkey(keyCode: 9, modifiers: 256 | 512))
        XCTAssertEqual(try Shortcut(Hotkey(keyCode: 49, modifiers: 4096 | 2048)).description, "ctrl+alt+space")
        XCTAssertEqual(try Shortcut("cmd+shift+v").description, "shift+cmd+v", "written in the canonical order")
    }

    func testInvalidShortcutsAreRefused() {
        for text in ["space", "shift+a", "ctrl+ctrl+a", "ctrl+nope", "cmd+c", ""] {
            XCTAssertThrowsError(try Shortcut(text), text)
        }
        XCTAssertThrowsError(try Shortcut(Hotkey(keyCode: 49, modifiers: 4096 | 1)), "a modifier bit the text cannot name")
    }

    func testShortcutsAreStringsInConfigFiles() throws {
        var document = ConfigDocument()
        var keys = Keys()
        keys.paste = try Shortcut("cmd+shift+v")
        try document.update("keys", keys, all: true)
        XCTAssertEqual(document.text, "[keys]\nopen = \"ctrl+alt+space\"\npaste = \"shift+cmd+v\"\n")
        XCTAssertEqual(try ConfigDocument(parsing: document.text).section("keys", as: Keys.self).value, keys)
    }

    func testTheSharedKeyNamesStillServeTheVersionOneFile() throws {
        // The v1 text file reads the same names through the shared parser.
        let companion = try TextConfiguration.companion(Configuration())
        let configuration = try TextConfiguration.decode("feature.command-bar = true\nshortcut.command-bar = ctrl+alt+k\n", companion: companion)
        XCTAssertEqual(configuration.preferences.toolkit?.commandBarHotkey, try Shortcut("ctrl+alt+k").hotkey)
    }
}
