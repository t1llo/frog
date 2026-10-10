import XCTest
@testable import FrogCore

final class FeatureOrganizationTests: XCTestCase {
    func testInlineToolsStayAvailableWithoutCreatingSidebarPages() {
        var preferences = Preferences()
        for feature in [FeatureID.windowSwitcher, .clipboard, .commandBar] {
            preferences.setFeature(feature, enabled: true)
        }
        XCTAssertTrue(preferences.featureEnabled(.windowSwitcher))
        XCTAssertTrue(preferences.featureEnabled(.clipboard))
        XCTAssertFalse(preferences.sidebarFeatures.contains(.windowSwitcher))
        XCTAssertFalse(preferences.sidebarFeatures.contains(.clipboard))
        XCTAssertTrue(preferences.sidebarFeatures.contains(.commandBar))
        XCTAssertFalse(ToolkitRoute.feature(.windowSwitcher).available(in: preferences))
        XCTAssertFalse(ToolkitRoute.feature(.clipboard).available(in: preferences))
        XCTAssertTrue(ToolkitRoute.feature(.commandBar).available(in: preferences))
        XCTAssertTrue(ToolkitRoute.history.available(in: preferences))
    }

    func testSystemMonitorIsOptInAndHasNoSidebarPage() throws {
        var preferences = Preferences()
        XCTAssertFalse(preferences.featureEnabled(.systemMonitor))
        preferences.setFeature(.systemMonitor, enabled: true)
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertTrue(restored.featureEnabled(.systemMonitor))
        XCTAssertFalse(restored.sidebarFeatures.contains(.systemMonitor))
        XCTAssertFalse(ToolkitRoute.feature(.systemMonitor).available(in: restored))
    }

    func testWindowActionsFollowShortcutsIndependentlyOfSwitcher() {
        var preferences = Preferences()
        let rule = WindowAction.allCases[0].rule
        preferences.setFeature(.windowSwitcher, enabled: false)
        XCTAssertTrue(preferences.ruleFeatureEnabled(rule))
        preferences.setFeature(.applicationShortcuts, enabled: false)
        preferences.setFeature(.windowSwitcher, enabled: true)
        XCTAssertFalse(preferences.ruleFeatureEnabled(rule))
        XCTAssertTrue(preferences.featureEnabled(.windowSwitcher))
        preferences.setFeature(.applicationShortcuts, enabled: true)
        XCTAssertTrue(preferences.ruleFeatureEnabled(rule))
    }

    func testLegacyDisabledShortcutsDoNotStartSwitcherDuringMigration() throws {
        let legacy = #"{"historyEnabled":false,"historyLimit":200,"historyRetentionDays":30,"applicationShortcutsEnabled":false,"windowSwitcherEnabled":true}"#
        var preferences = try JSONDecoder().decode(Preferences.self, from: Data(legacy.utf8))
        XCTAssertEqual(preferences.toolkitSettings.effectiveWindowSwitcherHotkey, Hotkey(keyCode: 48, modifiers: 256))
        XCTAssertFalse(preferences.featureEnabled(.windowSwitcher))
        XCTAssertFalse(preferences.ruleFeatureEnabled(WindowAction.allCases[0].rule))
        preferences.setFeature(.clipboard, enabled: true)
        XCTAssertFalse(preferences.featureEnabled(.windowSwitcher))
        preferences.setFeature(.applicationShortcuts, enabled: true)
        XCTAssertTrue(preferences.ruleFeatureEnabled(WindowAction.allCases[0].rule))
        XCTAssertFalse(preferences.featureEnabled(.windowSwitcher))
    }

    func testDisabledInlineFeaturesKeepBindingsAndRulesThroughStoreAndExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory)
        var configuration = Configuration()
        configuration.rules = [WindowAction.allCases[0].rule]
        configuration.rules[0].hotkey = Hotkey(keyCode: 18, modifiers: 4096 | 2048)
        configuration.preferences.setFeature(.windowSwitcher, enabled: false)
        configuration.preferences.toolkit?.windowSwitcherHotkey = Hotkey(keyCode: 48, modifiers: 2048)
        configuration.preferences.setFeature(.clipboard, enabled: false)
        configuration.preferences.workflows?.clipboardHistoryHotkey = Hotkey(keyCode: 9, modifiers: 4096 | 2048)
        try store.save(configuration)
        let text = try String(contentsOf: store.textFile, encoding: .utf8)
        XCTAssertTrue(text.contains("shortcut.window-switcher ="))
        let loaded = try store.load()
        let restored = try ConfigurationFile.decode(ConfigurationFile.encode(loaded))
        XCTAssertEqual(restored.preferences.toolkitSettings.windowSwitcherHotkey, configuration.preferences.toolkitSettings.windowSwitcherHotkey)
        XCTAssertEqual(restored.preferences.workflowSettings.clipboardHistoryHotkey, configuration.preferences.workflowSettings.clipboardHistoryHotkey)
        XCTAssertEqual(restored.rules, configuration.rules)
        XCTAssertFalse(restored.preferences.featureEnabled(.windowSwitcher))
        XCTAssertFalse(restored.preferences.featureEnabled(.clipboard))
        XCTAssertTrue(restored.preferences.ruleFeatureEnabled(restored.rules[0]))
    }

    func testImportRejectsInvalidSwitcherShortcut() {
        var configuration = Configuration()
        configuration.preferences.toolkit = ToolkitPreferences()
        configuration.preferences.toolkit?.windowSwitcherHotkey = Hotkey(keyCode: 48, modifiers: 0)
        XCTAssertThrowsError(try ConfigurationFile.validate(configuration))
    }
}
