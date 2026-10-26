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

    func testEveryFeatureOpensItsOwnPageWhileOnAndFeaturesWhileOff() {
        let toolkit = Toolkit(showsUsageStatusItem: false)
        defer { toolkit.stop() }
        for feature in FeatureID.allCases {
            var preferences = Preferences()
            preferences.setFeature(feature, enabled: true)
            toolkit.apply(preferences)
            toolkit.select(.feature(feature))
            XCTAssertEqual(toolkit.route, .feature(feature), feature.rawValue)
            XCTAssertTrue(toolkit.sidebar.contains(feature), feature.rawValue)
            preferences.setFeature(feature, enabled: false)
            toolkit.apply(preferences)
            toolkit.select(.feature(feature))
            XCTAssertEqual(toolkit.route, .features, feature.rawValue)
            XCTAssertFalse(toolkit.sidebar.contains(feature), feature.rawValue)
        }
        toolkit.select(.history)
        XCTAssertEqual(toolkit.route, .history)
    }
}
