import XCTest
@testable import FrogCore

final class WindowSetupChoiceTests: XCTestCase {
    private func preferences() -> Preferences {
        var preferences = Preferences()
        preferences.setFeature(.commandBar, enabled: true)
        var windows = WindowPreferences()
        windows.gap = 8
        windows.restoreOnDrag = false
        windows.zoneGrid = ZoneGrid.quarters.rawValue
        preferences.toolkit?.windows = windows
        return preferences
    }

    func testSnapTurnsOnWindowsAndItsSwitchesAndKeepsTheRest() {
        let before = preferences()
        let after = WindowSetupChoice.apply(.snap, to: before)
        XCTAssertTrue(after.featureEnabled(.windows))
        let windows = after.toolkitSettings.windows
        XCTAssertEqual(windows?.dragToSnap, true)
        XCTAssertEqual(windows?.restoreOnDrag, true)
        XCTAssertEqual(windows?.zoneOverlay, true)
        XCTAssertEqual(windows?.layoutPicker, true)
        XCTAssertEqual(windows?.setupChoice, "snap")
        XCTAssertEqual(windows?.gap, 8)
        XCTAssertEqual(windows?.zoneGrid, "quarters")
        XCTAssertTrue(after.featureEnabled(.commandBar))
        let switches = WindowSwitches(after)
        XCTAssertTrue(switches.dragToSnap && switches.restoreOnDrag && switches.zoneOverlay && switches.watchesDrags)

        // From preferences that have no toolkit yet.
        let fresh = WindowSetupChoice.apply(.snap, to: Preferences())
        XCTAssertTrue(fresh.featureEnabled(.windows))
        XCTAssertEqual(fresh.toolkitSettings.windows?.zoneOverlay, true)
    }

    func testManualOnlyRecords() {
        let before = preferences()
        let after = WindowSetupChoice.apply(.manual, to: before)
        XCTAssertFalse(after.featureEnabled(.windows))
        var expected = before.toolkitSettings.windows
        expected?.setupChoice = "manual"
        XCTAssertEqual(after.toolkitSettings.windows, expected)
        XCTAssertEqual(WindowSetupChoice.options, [.snap])
    }

    func testAnUnknownChoiceDecodesAndKeepsTheCardHidden() throws {
        let json = #"{"windows":{"setupChoice":"tile","zoneGrid":"spiral","zoneOverlay":true}}"#
        let toolkit = try JSONDecoder().decode(ToolkitPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(toolkit.windows?.setupChoice, "tile", "Set, so the card stays hidden")
        XCTAssertNil(toolkit.windows?.setupChoice.flatMap(WindowSetupChoice.init(rawValue:)))
        XCTAssertEqual(toolkit.windows?.zoneGrid, "thirds", "An unknown grid falls back to thirds")
        XCTAssertEqual(toolkit.windows?.zoneOverlay, true)
        let fresh = try JSONDecoder().decode(ToolkitPreferences.self, from: Data(#"{"windows":{}}"#.utf8))
        XCTAssertNil(fresh.windows?.setupChoice)
        XCTAssertEqual(fresh.windows?.zoneOverlay, false)
        var round = WindowPreferences()
        round.setupChoice = "snap"; round.zoneOverlay = true; round.zoneGrid = "main-side"
        XCTAssertEqual(try JSONDecoder().decode(WindowPreferences.self, from: JSONEncoder().encode(round)), round)
    }

    func testUndoRestoresTheSettingsAndKeepsAddedShortcuts() {
        let before = preferences()
        var after = WindowSetupChoice.apply(.snap, to: before)
        let picker = Hotkey(keyCode: 13, modifiers: 4096 | 2048)
        after.toolkit?.windows?.shortcuts[WindowCommand.layoutPicker.rawValue] = picker
        let undone = WindowSetupChoice.undo(to: before, from: after)
        XCTAssertFalse(undone.featureEnabled(.windows))
        var expected = before.toolkitSettings.windows
        expected?.shortcuts = [WindowCommand.layoutPicker.rawValue: picker]
        XCTAssertEqual(undone.toolkitSettings.windows, expected)
        XCTAssertNil(undone.toolkitSettings.windows?.setupChoice, "The card can show again")
        XCTAssertTrue(undone.featureEnabled(.commandBar))
    }
}
