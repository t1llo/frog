import XCTest
@testable import FrogCore

final class WorkflowConfigurationTests: XCTestCase {
    func testLegacyRulesRemainTextAndPreferencesGetLocalDefaults() throws {
        let data = try ConfigurationFile.encode(Configuration())
        let result = try ConfigurationFile.decode(data)
        XCTAssertTrue(result.rules.allSatisfy { $0.category == .text })
        XCTAssertEqual(result.preferences.workflowSettings.recordingMode, .toggle)
        XCTAssertEqual(result.preferences.workflowSettings.output, .copy)
        XCTAssertTrue(result.preferences.workflowSettings.showDictationPopup)
    }
    func testTypedRulesAppearanceAndDefaultsRoundTrip() throws {
        var configuration = Configuration()
        var audio = Rule.dictationPreset
        audio.action?.recordingMode = .hold; audio.action?.output = .paste
        var app = Rule(name: "Safari")
        app.action = RuleAction(category: .application)
        app.action?.applicationPath = "/Applications/Safari.app"; app.action?.applicationBundleID = "com.apple.Safari"
        configuration.rules += [audio, app]
        var prefs = WorkflowPreferences(); prefs.defaultLocalTextModelID = "qwen-0.6b"; prefs.showDictationPopup = false
        configuration.preferences.workflows = prefs
        var appearance = AppearancePreferences(); appearance.accentHex = "8EBCFF"; appearance.transparency = 0.7
        configuration.preferences.appearance = appearance
        XCTAssertEqual(try ConfigurationFile.decode(ConfigurationFile.encode(configuration)), configuration)
    }
    func testInvalidModelsAppearanceAndReferenceShortcutConflictRejected() throws {
        var configuration = Configuration()
        var prefs = WorkflowPreferences(); prefs.audioModelID = "qwen-0.6b"
        configuration.preferences.workflows = prefs
        XCTAssertThrowsError(try ConfigurationFile.validate(configuration))
        prefs.audioModelID = "whisper-small"; prefs.shortcutPanelHotkey = configuration.rules[0].hotkey
        configuration.preferences.workflows = prefs
        XCTAssertThrowsError(try ConfigurationFile.validate(configuration))
        configuration.preferences.workflows = nil
        var appearance = AppearancePreferences(); appearance.transparency = 2
        configuration.preferences.appearance = appearance
        XCTAssertThrowsError(try ConfigurationFile.validate(configuration))
        appearance.transparency = 0; appearance.accentHex = "nothex"
        configuration.preferences.appearance = appearance
        XCTAssertThrowsError(try ConfigurationFile.validate(configuration))
    }
}
