import XCTest
@testable import FrogCore

final class WindowPreferencesTests: XCTestCase {
    func testWindowsIsOffByDefaultAndHasAPage() {
        XCTAssertFalse(Preferences().featureEnabled(.windows))
        XCTAssertTrue(FeatureID.windows.hasPage)
        var preferences = Preferences()
        preferences.setFeature(.windows, enabled: true)
        XCTAssertTrue(preferences.sidebarFeatures.contains(.windows))
    }

    func testWindowActionsRunWhileShortcutsOrWindowsIsOn() {
        let window = WindowAction.leftHalf.rule
        let system = SystemAction.allCases[0].rule
        for shortcuts in [false, true] {
            for windows in [false, true] {
                var preferences = Preferences()
                preferences.setFeature(.applicationShortcuts, enabled: shortcuts)
                preferences.setFeature(.windows, enabled: windows)
                XCTAssertEqual(preferences.ruleFeatureEnabled(window), shortcuts || windows, "shortcuts \(shortcuts), windows \(windows)")
                XCTAssertEqual(preferences.windowActionsEnabled, shortcuts || windows)
                XCTAssertEqual(preferences.ruleFeatureEnabled(system), shortcuts)
                XCTAssertEqual(WindowSwitches(preferences), WindowSwitches(preferences))
                XCTAssertEqual(WindowSwitches(preferences).feature, windows)
                XCTAssertEqual(WindowSwitches(preferences).actionsEnabled, shortcuts || windows)
            }
        }
    }

    func testWindowPreferencesRoundTripAndOlderJSONWithoutThem() throws {
        var toolkit = ToolkitPreferences()
        XCTAssertEqual(try JSONDecoder().decode(ToolkitPreferences.self, from: JSONEncoder().encode(toolkit)), toolkit)
        toolkit.windows = WindowPreferences()
        let restored = try JSONDecoder().decode(ToolkitPreferences.self, from: JSONEncoder().encode(toolkit))
        XCTAssertEqual(restored, toolkit)
        XCTAssertEqual(restored.windows, WindowPreferences())

        let older = try JSONDecoder().decode(ToolkitPreferences.self, from: Data(#"{"enabled":{"usage":true}}"#.utf8))
        XCTAssertNil(older.windows)
        for json in [#"{"windows":{}}"#, #"{"windows":{"unknown":1}}"#] {
            XCTAssertEqual(try JSONDecoder().decode(ToolkitPreferences.self, from: Data(json.utf8)).windows, WindowPreferences(), json)
        }
    }

    func testShortcutRowsListAssignedFirstAndKeepIDs() {
        var assigned = WindowAction.rightThird.rule
        assigned.hotkey = Hotkey(keyCode: 124, modifiers: 4096 | 2048); assigned.enabled = true
        var unassigned = WindowAction.center.rule
        unassigned.name = WindowAction.center.title
        let rows = WindowAction.shortcutRows(configured: [unassigned, assigned])
        XCTAssertEqual(rows.count, WindowAction.allCases.count)
        XCTAssertEqual(rows.count, 23)
        XCTAssertEqual(rows.first, assigned)
        XCTAssertEqual(Set(rows.map(\.id)).count, 23)
        for action in WindowAction.allCases where action != .rightThird && action != .center {
            XCTAssertTrue(rows.contains { $0.id == action.rule.id && $0.action?.windowAction == action }, action.rawValue)
        }
        XCTAssertEqual(rows.filter { $0.hotkey != nil }.count, 1)
    }
}
