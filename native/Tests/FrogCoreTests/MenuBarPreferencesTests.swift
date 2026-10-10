import XCTest
@testable import FrogCore

final class MenuBarPreferencesTests: XCTestCase {
    func testEmptySettingsMigrateAndShortcutIsOptIn() throws {
        let value = try JSONDecoder().decode(MenuBarPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(value, MenuBarPreferences())
        XCTAssertNil(value.hotkey)
        XCTAssertFalse(value.permanentlyHiddenSection)
    }

    func testPortableRoundTripAndHostileDelayBounds() throws {
        var value = MenuBarPreferences()
        value.permanentlyHiddenSection = true
        value.hotkey = Hotkey(keyCode: 46, modifiers: 6144)
        value.autoHideSeconds = 23
        XCTAssertEqual(try JSONDecoder().decode(MenuBarPreferences.self, from: JSONEncoder().encode(value)), value)
        value.autoHideSeconds = .infinity
        XCTAssertEqual(value.normalized.autoHideSeconds, 10)
        let negative = try JSONDecoder().decode(MenuBarPreferences.self, from: Data(#"{"autoHideSeconds":-100}"#.utf8))
        XCTAssertEqual(negative.autoHideSeconds, 1)
        let huge = try JSONDecoder().decode(MenuBarPreferences.self, from: Data(#"{"autoHideSeconds":99999999}"#.utf8))
        XCTAssertEqual(huge.autoHideSeconds, 3600)
    }
}
