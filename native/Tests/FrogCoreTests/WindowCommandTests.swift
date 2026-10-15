import XCTest
@testable import FrogCore

final class WindowCommandTests: XCTestCase {
    func testCheatSheetHasItsFixedID() {
        XCTAssertEqual(WindowCommand.cheatSheet.id, UUID(uuidString: "AC57F601-63D0-4E76-9900-000000000002"))
        XCTAssertEqual(WindowCommand.cheatSheet.number, 2)
        XCTAssertEqual(WindowCommand.cheatSheet.group, .simple)
        XCTAssertTrue(WindowCommand.cheatSheet.isMomentary)
    }

    func testCommandForIDRoundTrips() {
        for command in WindowCommand.allCases { XCTAssertEqual(WindowCommand.command(for: command.id), command) }
        XCTAssertNil(WindowCommand.command(for: WindowAction.leftHalf.rule.id))
        XCTAssertNil(WindowCommand.command(for: UUID()))
    }

    func testIDsNumbersAndNamesAreUniqueAndApartFromLayouts() {
        let layoutIDs = Set(WindowAction.allCases.map(\.rule.id))
        for command in WindowCommand.allCases { XCTAssertFalse(layoutIDs.contains(command.id), command.rawValue) }
        XCTAssertEqual(Set(WindowCommand.allCases.map(\.rawValue)).count, WindowCommand.allCases.count)
        XCTAssertEqual(Set(WindowCommand.allCases.map(\.number)).count, WindowCommand.allCases.count)
        XCTAssertEqual(Set(WindowCommand.allCases.map(\.id)).count, WindowCommand.allCases.count)
    }

    func testRuleCarriesTheIDTitleAndShortcut() {
        let key = Hotkey(keyCode: 44, modifiers: 4096 | 2048)
        let rule = WindowCommand.cheatSheet.rule(hotkey: key)
        XCTAssertEqual(rule.id, WindowCommand.cheatSheet.id)
        XCTAssertEqual(rule.name, WindowCommand.cheatSheet.title)
        XCTAssertEqual(rule.hotkey, key)
        XCTAssertTrue(rule.enabled)
    }

    func testShortcutsRoundTripAndOnlyEffectiveCommandsRegister() throws {
        let key = Hotkey(keyCode: 44, modifiers: 4096 | 2048)
        var windows = WindowPreferences()
        windows.shortcuts = [WindowCommand.cheatSheet.rawValue: key, "notYetKnown": key]
        XCTAssertEqual(try JSONDecoder().decode(WindowPreferences.self, from: JSONEncoder().encode(windows)), windows)
        XCTAssertEqual(try JSONDecoder().decode(WindowPreferences.self, from: Data("{}".utf8)).shortcuts, [:])

        var preferences = Preferences()
        preferences.ensureToolkit()
        preferences.toolkit?.windows = windows
        XCTAssertFalse(WindowSwitches(preferences).commandEnabled(.cheatSheet))
        XCTAssertEqual(WindowSwitches(preferences).shortcutRules, [])
        preferences.setFeature(.windows, enabled: true)
        XCTAssertTrue(WindowSwitches(preferences).commandEnabled(.cheatSheet))
        XCTAssertEqual(WindowSwitches(preferences).shortcutRules, [WindowCommand.cheatSheet.rule(hotkey: key)])
    }
}
