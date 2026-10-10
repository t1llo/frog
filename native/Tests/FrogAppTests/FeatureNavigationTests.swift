import XCTest
import FrogCore
@testable import FrogApp

@MainActor final class FeatureNavigationTests: XCTestCase {
    func testSwitcherShortcutValidationPreservesConfigurationOnRejectedSaveAndImport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try ConfigurationStore(directory: directory).save(Configuration())
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in nil })
        defer { model.shutdown() }
        var preferences = model.configuration.preferences
        preferences.setFeature(.windowSwitcher, enabled: true)
        preferences.toolkit?.windowSwitcherHotkey = Hotkey(keyCode: 49, modifiers: 4096)
        try model.savePreferences(preferences)
        let saved = try ConfigurationStore(directory: directory).load()
        preferences.toolkit?.windowSwitcherHotkey = Hotkey(keyCode: 49, modifiers: 4096 | 512)
        XCTAssertThrowsError(try model.savePreferences(preferences))
        var imported = saved; imported.preferences = preferences
        XCTAssertThrowsError(try model.importConfiguration(imported))
        XCTAssertEqual(model.configuration, saved)
        XCTAssertEqual(try ConfigurationStore(directory: directory).load(), saved)
    }

    func testLegacyToolLinksOpenTheirFeatureCardEvenWhenDisabled() {
        let toolkit = Toolkit(showsUsageStatusItem: false)
        defer { toolkit.stop() }
        var preferences = Preferences()
        for enabled in [true, false] {
            for feature in [FeatureID.windowSwitcher, .clipboard, .systemMonitor] {
                preferences.setFeature(feature, enabled: enabled)
                toolkit.apply(preferences)
                toolkit.select(.feature(feature))
                XCTAssertEqual(toolkit.route, .features)
                XCTAssertEqual(toolkit.featureSettingsSelection, feature)
                XCTAssertFalse(toolkit.sidebar.contains(feature))
            }
        }
        toolkit.select(.history)
        XCTAssertEqual(toolkit.route, .history)
        XCTAssertNil(toolkit.featureSettingsSelection)
        preferences.setFeature(.commandBar, enabled: true)
        toolkit.apply(preferences)
        toolkit.select(.feature(.commandBar))
        XCTAssertEqual(toolkit.route, .feature(.commandBar))
        XCTAssertTrue(toolkit.sidebar.contains(.commandBar))
    }

    func testClipboardCardNavigationSelectsClipboardHistoryAndReturnsToFeatures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = Configuration()
        configuration.preferences.setFeature(.clipboard, enabled: true)
        try ConfigurationStore(directory: directory).save(configuration)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in nil })
        defer { model.shutdown() }
        model.openClipboardHistoryPage()
        XCTAssertEqual(model.toolkit.route, .history)
        XCTAssertEqual(model.historyFilter, .clipboard)
        model.openFeature(.clipboard)
        XCTAssertEqual(model.toolkit.route, .features)
        XCTAssertEqual(model.toolkit.featureSettingsSelection, .clipboard)
    }
}
