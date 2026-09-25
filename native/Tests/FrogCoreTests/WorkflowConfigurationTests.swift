import XCTest
@testable import FrogCore

final class WorkflowConfigurationTests: XCTestCase {
    func testAppearanceThemesRoundTripAndLegacySettingsKeepTheirAccent() throws {
        let old = try JSONDecoder().decode(AppearancePreferences.self, from: Data(#"{"accentHex":"AABBCC","transparency":0.4}"#.utf8))
        XCTAssertNil(old.theme)
        XCTAssertNil(old.mode)
        XCTAssertNil(old.useThemeAccent)
        XCTAssertEqual(old.accentHex, "AABBCC")
        for theme in AppearancePreferences.Theme.allCases {
            for mode in AppearancePreferences.Mode.allCases {
                var config = Configuration()
                var appearance = old
                appearance.theme = theme; appearance.mode = mode; appearance.useThemeAccent = true
                config.preferences.appearance = appearance
                XCTAssertEqual(try ConfigurationFile.decode(ConfigurationFile.encode(config)), config)
            }
        }
    }
    func testLegacyLocalDefaultMigratesWithoutLosingSeparateProviderChoice() throws {
        let original = WorkflowPreferences()
        let legacy = try JSONDecoder().decode(WorkflowPreferences.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(legacy.effectiveTextSource, .provider)
        var updated = legacy
        updated.defaultLocalTextModelID = "qwen-1.7b"
        XCTAssertEqual(updated.effectiveTextSource, .frog)
        updated.textSource = .provider
        updated.transcriptionLanguage = "de"
        updated.applicationLanguage = "de"
        updated.muteWhileRecording = true
        let restored = try JSONDecoder().decode(WorkflowPreferences.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(restored, updated)
        XCTAssertEqual(restored.effectiveTextSource, .provider)
        XCTAssertEqual(restored.defaultLocalTextModelID, "qwen-1.7b")
    }
    func testApplicationRuleWithoutInstructionsAndCancelConflictValidation() throws {
        var config = Configuration()
        var app = Rule(name: "Safari", instructions: "")
        app.action = RuleAction(category: .application)
        app.action?.applicationPath = "/Applications/Safari.app"
        app.action?.applicationBundleID = "com.apple.Safari"
        config.rules.append(app)
        XCTAssertNoThrow(try ConfigurationFile.validate(config))
        var prefs = WorkflowPreferences()
        prefs.cancelRecordingHotkey = config.rules[0].hotkey
        config.preferences.workflows = prefs
        XCTAssertThrowsError(try ConfigurationFile.validate(config))
        prefs.cancelRecordingHotkey = nil
        prefs.applicationLanguage = "invalid"
        config.preferences.workflows = prefs
        XCTAssertThrowsError(try ConfigurationFile.validate(config))
    }
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
