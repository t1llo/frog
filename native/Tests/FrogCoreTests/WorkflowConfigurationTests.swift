import XCTest
@testable import FrogCore

final class WorkflowConfigurationTests: XCTestCase {
    func testTranslucencyBoundsAndAccessibilityDoNotChangePortablePreferences() throws {
        var settings = AppearancePreferences(); settings.transparency = 0.8; settings.popupTransparency = 0.3
        XCTAssertEqual(settings.effectiveTransparency(popup: false, reduceTransparency: false, increasedContrast: false), 0.8)
        XCTAssertEqual(settings.effectiveTransparency(popup: true, reduceTransparency: false, increasedContrast: false), 0.3)
        for popup in [false, true] {
            XCTAssertEqual(settings.effectiveTransparency(popup: popup, reduceTransparency: true, increasedContrast: false), 0)
            XCTAssertEqual(settings.effectiveTransparency(popup: popup, reduceTransparency: false, increasedContrast: true), 0)
        }
        XCTAssertEqual(try JSONDecoder().decode(AppearancePreferences.self, from: JSONEncoder().encode(settings)), settings)
        for value in [-1.0, 1.01, .infinity, .nan] {
            settings.transparency = value; XCTAssertFalse(settings.valid)
            let rendered = settings.effectiveTransparency(popup: false, reduceTransparency: false, increasedContrast: false)
            XCTAssertTrue(rendered.isFinite && (0...1).contains(rendered))
        }
    }
    func testSystemShortcutSurvivesConfigurationRoundTripWithoutATextModel() throws {
        var configuration = Configuration()
        var rule = SystemAction.lockScreen.rule
        rule.hotkey = Hotkey(keyCode: 37, modifiers: 4096 | 512); rule.enabled = true
        configuration.rules.append(rule)
        let restored = try ConfigurationFile.decode(ConfigurationFile.encode(configuration))
        XCTAssertEqual(restored.rules.last, rule)
        XCTAssertTrue(rule.category.isShortcut)
        XCTAssertEqual(SystemAction.lockScreen.rule.id, rule.id)
        XCTAssertEqual(rule.id.uuidString, "AC57F600-63D0-4E76-9901-000000000001")
        configuration.rules[configuration.rules.count - 1].action?.systemAction = nil
        XCTAssertThrowsError(try ConfigurationFile.validate(configuration))
    }
    func testAllSystemActionsStartUnassignedAndPreserveCustomizedConfiguration() throws {
        let defaults = SystemAction.allCases.map(\.rule)
        XCTAssertEqual(defaults.count, 28)
        XCTAssertEqual(Set(defaults.map(\.id)).count, defaults.count)
        XCTAssertTrue(defaults.allSatisfy { !$0.enabled && $0.hotkey == nil && $0.category == .system })
        XCTAssertTrue(SystemAction.allCases.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty && !$0.symbol.isEmpty })
        var configuration = Configuration()
        configuration.rules = defaults
        configuration.rules[1].name = "My home folder"
        configuration.rules[1].enabled = true
        configuration.rules[1].hotkey = Hotkey(keyCode: 4, modifiers: 4096 | 512)
        XCTAssertEqual(try ConfigurationFile.decode(ConfigurationFile.encode(configuration)), configuration)
    }
    func testFactoryCleanupMigrationRunsOnceAndKeepsCustomRulesAndShortcuts() throws {
        var config = Configuration()
        var factory = Rule.dictationPreset
        factory.action?.cleanup = true
        factory.hotkey = Hotkey(keyCode: 2, modifiers: 4096)
        var custom = Rule.dictationPreset; custom.id = UUID(); custom.preset = false; custom.action?.cleanup = true
        config.rules += [factory, custom]
        config.adoptClipboardDictationDefaults()
        XCTAssertEqual(config.rules.first { $0.id == factory.id }?.action?.cleanup, false)
        XCTAssertEqual(config.rules.first { $0.id == factory.id }?.hotkey, factory.hotkey)
        XCTAssertEqual(config.rules.first { $0.id == custom.id }?.action?.cleanup, true)
        let index = config.rules.firstIndex { $0.id == factory.id }!
        config.rules[index].action?.cleanup = true
        config = try ConfigurationFile.decode(ConfigurationFile.encode(config))
        config.adoptClipboardDictationDefaults()
        XCTAssertEqual(config.rules[index].action?.cleanup, true, "Explicit opt-in after migration survives restart")
    }
    func testNewDictationDoesNotRunLLMCleanupOrPasteByDefault() {
        XCTAssertEqual(Rule.dictationPreset.action?.cleanup, false)
        XCTAssertEqual(RuleAction(category: .audio).cleanup, false)
        XCTAssertEqual(WorkflowPreferences().output, .copy)
    }
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
                appearance.popupTransparency = 0.6
                config.preferences.appearance = appearance
                config.preferences.toolkit = ToolkitPreferences()
                config.preferences.toolkit?.usage = UsageDisplayPreferences(provider: "OpenAI", range: "30d", metric: "Input", allDevices: true)
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

    func testAnswerOutputIsOmittedUntilSetAndRoundTripsWhenSet() throws {
        let plain = String(decoding: try JSONEncoder().encode(RuleAction(category: .text)), as: UTF8.self)
        XCTAssertFalse(plain.contains("textOutput"), plain)
        var configuration = Configuration()
        var answer = Rule(name: "Define", instructions: "Define it.")
        answer.action = RuleAction(category: .text); answer.action?.textOutput = .panel
        configuration.rules.append(answer)
        let restored = try ConfigurationFile.decode(ConfigurationFile.encode(configuration))
        XCTAssertEqual(restored.rules.last, answer)
        XCTAssertTrue(restored.rules.last?.answersInPanel == true)
        let json = #"{"id":"6A1F2E3D-0000-4000-8000-000000000001","name":"Define","instructions":"Define it.","model":"","targetLanguage":"","enabled":true,"preset":false,"action":{"category":"text","cleanup":false,"textOutput":"panel"}}"#
        XCTAssertTrue(try JSONDecoder().decode(Rule.self, from: Data(json.utf8)).answersInPanel)
    }

    func testOnlyTextRulesAnswerInAPanel() {
        var audio = Rule.dictationPreset
        audio.action?.textOutput = .panel
        XCTAssertFalse(audio.answersInPanel)
        var replace = Rule(); replace.action = RuleAction(category: .text); replace.action?.textOutput = .replace
        XCTAssertFalse(replace.answersInPanel)
        XCTAssertFalse(Rule().answersInPanel)
        XCTAssertTrue(Rule.explainPreset.answersInPanel)
    }

    func testExplainRuleIsCreatedOnceWithTheMostRecentAvailableTextModel() {
        var config = Configuration()
        config.recentModels = [.init(modelID: "qwen-0.6b", category: .text), .init(modelID: "whisper-tiny", category: .audio), .init(modelID: "qwen-4b", category: .text)]
        let count = config.rules.count
        config.adoptExplainPreset(installed: ["qwen-0.6b", "whisper-tiny"])
        XCTAssertEqual(config.rules.count, count + 1)
        let explain = config.rules.last!
        XCTAssertEqual(explain.name, "Explain")
        XCTAssertEqual(explain.instructions, Rule.explainInstructions)
        XCTAssertTrue(explain.preset)
        XCTAssertNil(explain.hotkey)
        XCTAssertEqual(explain.action?.textOutput, .panel)
        XCTAssertEqual(explain.action?.localTextModelID, "qwen-0.6b", "The newest text model that is still installed")
        XCTAssertEqual(config.preferences.workflowSettings.explainPresetVersion, Rule.explainPresetVersion)
        let created = config
        config.adoptExplainPreset(installed: ["qwen-0.6b"])
        XCTAssertEqual(config, created)
        config.rules.removeAll { $0.id == explain.id }
        config.adoptExplainPreset(installed: ["qwen-0.6b"])
        XCTAssertFalse(config.rules.contains { $0.answersInPanel }, "A deleted Explain rule stays deleted")
    }

    func testExplainRuleWithoutATextModelReceivesTheFirstOneAdded() {
        var config = Configuration()
        config.rules = []
        config.adoptExplainPreset(installed: [])
        XCTAssertEqual(config.rules.count, 1)
        XCTAssertNil(config.rules[0].providerID)
        XCTAssertEqual(config.rules[0].model, "")
        XCTAssertNil(config.rules[0].action?.localTextModelID)
        config.modelAdded(.init(modelID: "qwen-1.7b", category: .text))
        XCTAssertEqual(config.rules[0].action?.localTextModelID, "qwen-1.7b")
        XCTAssertEqual(config.rules[0].action?.textOutput, .panel)
    }

    func testAnswerRulesNeverInheritTheLegacyDefaultModel() {
        var config = Configuration()
        XCTAssertNil(config.explicitRuleModels)
        var workflow = WorkflowPreferences()
        workflow.textSource = .frog; workflow.defaultLocalTextModelID = "qwen-1.7b"
        config.preferences.workflows = workflow
        var answer = Rule(name: "Define", instructions: "Define it.")
        answer.action = RuleAction(category: .text); answer.action?.textOutput = .panel
        config.rules = [Rule(name: "Proofread", instructions: "Proofread."), answer]
        config.adoptExplicitRuleSettings(installed: ["qwen-1.7b"])
        XCTAssertEqual(config.rules[0].action?.localTextModelID, "qwen-1.7b", "Writing rules keep the legacy migration")
        XCTAssertNil(config.rules[1].action?.localTextModelID)
        XCTAssertNil(config.rules[1].providerID)
        XCTAssertEqual(config.rules[1].model, "")
        config.recentModels = []
        config.adoptExplainPreset(installed: ["qwen-1.7b"])
        let explain = config.rules.last!
        XCTAssertEqual(explain.name, "Explain")
        XCTAssertNil(explain.action?.localTextModelID)
        XCTAssertNil(explain.providerID)
    }

    func testAnExistingExplainAnswerRulePreventsASecondOne() {
        var config = Configuration()
        var existing = Rule.explainPreset
        existing.instructions = "My own explanation."
        config.rules.append(existing)
        let count = config.rules.count
        config.adoptExplainPreset(installed: [])
        XCTAssertEqual(config.rules.count, count)
        XCTAssertEqual(config.rules.last?.instructions, "My own explanation.")
        XCTAssertEqual(config.preferences.workflowSettings.explainPresetVersion, Rule.explainPresetVersion)
    }

    func testAnswerRulesWithTheFirstBuiltInInstructionsGetTheShorterOnesOnce() throws {
        var config = Configuration()
        var untouched = Rule.explainPreset
        untouched.instructions = Rule.firstExplainInstructions
        var edited = Rule.explainPreset
        edited.id = UUID(); edited.name = "Define"; edited.instructions = "Define it."
        let writing = Rule(name: "Explain in place", instructions: Rule.firstExplainInstructions)
        config.rules = [untouched, edited, writing]
        var workflow = WorkflowPreferences()
        workflow.explainPresetVersion = 1
        config.preferences.workflows = workflow
        config = try ConfigurationFile.decode(ConfigurationFile.encode(config))

        config.adoptExplainPreset(installed: [])
        XCTAssertEqual(config.rules.map(\.instructions), [Rule.explainInstructions, "Define it.", Rule.firstExplainInstructions],
                       "Only answer rules with the old text word for word change; nothing is added")
        XCTAssertEqual(config.preferences.workflowSettings.explainPresetVersion, Rule.explainPresetVersion)
        XCTAssertTrue(Rule.explainInstructions.contains("at most about 50 words"))

        // Put back on purpose afterwards, the old text stays.
        config.rules[0].instructions = Rule.firstExplainInstructions
        config.adoptExplainPreset(installed: [])
        XCTAssertEqual(config.rules[0].instructions, Rule.firstExplainInstructions)
    }

    func testPagesListTextRulesByOutputAndOtherCategoriesIgnoreIt() {
        let writing = Rule()
        var answer = Rule.explainPreset
        answer.id = UUID()
        XCTAssertTrue(writing.listed(on: .text, output: .replace))
        XCTAssertFalse(writing.listed(on: .text, output: .panel))
        XCTAssertTrue(answer.listed(on: .text, output: .panel))
        XCTAssertFalse(answer.listed(on: .text, output: .replace))
        XCTAssertFalse(answer.listed(on: .audio, output: .panel))
        for output in TextOutput.allCases {
            XCTAssertTrue(Rule.dictationPreset.listed(on: .audio, output: output))
            XCTAssertTrue(WindowAction.allCases[0].rule.listed(on: .window, output: output))
            XCTAssertTrue(SystemAction.lockScreen.rule.listed(on: .system, output: output))
            XCTAssertFalse(Rule.dictationPreset.listed(on: .text, output: output))
        }
    }

    func testAnswerRuleShortcutWarnsAboutOlderVersions() {
        var answer = Rule.explainPreset
        XCTAssertNil(answer.answerHotkeyWarning)
        answer.hotkey = Hotkey(keyCode: 14, modifiers: 4096 | 512)
        XCTAssertEqual(answer.answerHotkeyWarning, "Frog versions before Explain treat this rule as a Writing rule and would replace the selection with the answer.")
        XCTAssertNil(Rule.presets[0].answerHotkeyWarning)
        XCTAssertNotNil(Rule.presets[0].hotkey)
    }
}
