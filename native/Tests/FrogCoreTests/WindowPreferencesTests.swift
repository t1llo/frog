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

    func testSizeDefaultsAndTheGapIsClamped() {
        let defaults = WindowPreferences()
        XCTAssertEqual(defaults.gap, 0)
        XCTAssertFalse(defaults.cycleSizes)
        XCTAssertTrue(defaults.portraitThirds)
        XCTAssertTrue(defaults.respectStageManager)
        var windows = WindowPreferences()
        windows.gap = 60
        XCTAssertEqual(windows.normalized.gap, 40)
        windows.gap = -4
        XCTAssertEqual(windows.normalized.gap, 0)
        windows.gap = 12
        XCTAssertEqual(windows.normalized, windows)
    }

    func testDecodingOlderWindowPreferencesFillsDefaults() throws {
        XCTAssertEqual(try JSONDecoder().decode(WindowPreferences.self, from: Data("{}".utf8)), WindowPreferences())
        var expected = WindowPreferences(); expected.gap = 8
        XCTAssertEqual(try JSONDecoder().decode(WindowPreferences.self, from: Data(#"{"gap": 8}"#.utf8)), expected)
        var changed = WindowPreferences()
        changed.gap = 14; changed.cycleSizes = true; changed.portraitThirds = false; changed.respectStageManager = false
        XCTAssertEqual(try JSONDecoder().decode(WindowPreferences.self, from: JSONEncoder().encode(changed)), changed)
    }

    func testDecoderClampsTheGap() throws {
        XCTAssertEqual(try JSONDecoder().decode(WindowPreferences.self, from: Data(#"{"gap": 60}"#.utf8)).gap, 40)
    }

    func testTheFourTextKeysParseAndRoundTrip() throws {
        var configuration = Configuration()
        configuration.preferences.ensureToolkit()
        var windows = WindowPreferences()
        windows.gap = 12; windows.cycleSizes = true; windows.portraitThirds = false; windows.respectStageManager = false
        configuration.preferences.toolkit?.windows = windows
        let text = try TextConfiguration.render(configuration)
        let lines = ["windows.gap = 12", "windows.cycle-sizes = true", "windows.portrait-thirds = false", "windows.respect-stage-manager = false"]
        for line in lines { XCTAssertTrue(text.contains(line + "\n"), line) }
        let companion = try TextConfiguration.companion(configuration)
        XCTAssertEqual(try TextConfiguration.decode(text, companion: companion).preferences.toolkitSettings.windows, windows)

        let edited = text.replacingOccurrences(of: "windows.gap = 12", with: "windows.gap = 40")
            .replacingOccurrences(of: "windows.portrait-thirds = false", with: "windows.portrait-thirds = true")
        let read = try TextConfiguration.decode(edited, companion: companion).preferences.toolkitSettings.windows
        XCTAssertEqual(read?.gap, 40)
        XCTAssertEqual(read?.portraitThirds, true)
        XCTAssertEqual(read?.cycleSizes, true)
        for invalid in ["windows.gap = 41", "windows.gap = -2", "windows.cycle-sizes = sometimes"] {
            let line = invalid.components(separatedBy: " = ")[0]
            let broken = text.components(separatedBy: "\n").map { $0.hasPrefix(line + " =") ? invalid : $0 }.joined(separator: "\n")
            XCTAssertThrowsError(try TextConfiguration.decode(broken, companion: companion), invalid)
        }
    }

    func testLayoutOptionsFollowTheFeatureAndStageManager() {
        var preferences = Preferences()
        preferences.ensureToolkit()
        var windows = WindowPreferences()
        windows.gap = 10; windows.cycleSizes = true
        preferences.toolkit?.windows = windows
        let stageManager = MacWindowManagerSettings(stageManager: true)
        XCTAssertEqual(WindowSwitches(preferences).layoutOptions(stageManager), .legacy)

        preferences.setFeature(.windows, enabled: true)
        XCTAssertEqual(WindowSwitches(preferences).layoutOptions(stageManager),
                       WindowLayoutOptions(gap: 10, portraitThirds: true, leadingInset: 190, cycleSizes: true))
        XCTAssertEqual(WindowSwitches(preferences).layoutOptions(MacWindowManagerSettings()).leadingInset, 0)
        preferences.toolkit?.windows?.respectStageManager = false
        XCTAssertEqual(WindowSwitches(preferences).layoutOptions(stageManager).leadingInset, 0)

        // Without saved settings, the defaults apply.
        preferences.toolkit?.windows = nil
        XCTAssertEqual(WindowSwitches(preferences).layoutOptions(stageManager), WindowLayoutOptions(portraitThirds: true, leadingInset: 190))
    }

    func testValidateRejectsAGapOutsideTheRangeEvenWhileWindowsIsOff() throws {
        var preferences = Preferences()
        preferences.ensureToolkit()
        var windows = WindowPreferences()
        windows.gap = 60
        preferences.toolkit?.windows = windows
        XCTAssertFalse(preferences.featureEnabled(.windows))
        var used: Set<Hotkey> = [Hotkey(keyCode: 0, modifiers: 4096)]
        XCTAssertThrowsError(try WindowPreferences.validate(preferences, usedShortcuts: &used)) {
            XCTAssertEqual($0.localizedDescription, "The window gap must be between 0 and 40 points.")
        }
        preferences.toolkit?.windows?.gap = 8
        try WindowPreferences.validate(preferences, usedShortcuts: &used)
        XCTAssertEqual(used, [Hotkey(keyCode: 0, modifiers: 4096)])

        var configuration = Configuration()
        configuration.preferences = preferences
        configuration.preferences.toolkit?.windows?.gap = 60
        XCTAssertNoThrow(try ConfigurationFile.validate(Configuration()))
        XCTAssertThrowsError(try ConfigurationFile.validate(configuration)) {
            XCTAssertEqual($0.localizedDescription, "The window gap must be between 0 and 40 points.")
        }
    }
}
