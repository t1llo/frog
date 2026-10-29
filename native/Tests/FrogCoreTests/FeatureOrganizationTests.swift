import XCTest
@testable import FrogCore

final class FeatureOrganizationTests: XCTestCase {
    func testEveryEnabledFeatureHasASidebarPage() {
        var preferences = Preferences()
        for feature in FeatureID.allCases {
            preferences.setFeature(feature, enabled: true)
            XCTAssertTrue(preferences.sidebarFeatures.contains(feature), feature.rawValue)
            XCTAssertTrue(ToolkitRoute.feature(feature).available(in: preferences), feature.rawValue)
            preferences.setFeature(feature, enabled: false)
            XCTAssertFalse(preferences.sidebarFeatures.contains(feature), feature.rawValue)
            XCTAssertFalse(ToolkitRoute.feature(feature).available(in: preferences), feature.rawValue)
        }
        XCTAssertTrue(ToolkitRoute.history.available(in: preferences))
    }

    func testSystemMonitorIsOptInAndGetsASidebarPage() throws {
        var preferences = Preferences()
        XCTAssertFalse(preferences.featureEnabled(.systemMonitor))
        preferences.setFeature(.systemMonitor, enabled: true)
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertTrue(restored.featureEnabled(.systemMonitor))
        XCTAssertTrue(restored.sidebarFeatures.contains(.systemMonitor))
        XCTAssertTrue(ToolkitRoute.feature(.systemMonitor).available(in: restored))
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

    func testAnswerRulesStayInertWhileWritingIsOn() {
        var preferences = Preferences()
        preferences.setFeature(.writing, enabled: true)
        XCTAssertTrue(preferences.ruleFeatureEnabled(Rule()))
        XCTAssertFalse(preferences.ruleFeatureEnabled(Rule.explainPreset))
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

    func testATurnedOnToolInConfigDoesNotStartTheSwitcherOfAnEarlierConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Written before the switcher became a feature of its own: it ran only while Shortcuts was on,
        // and config.json has no toolkit.
        var earlier = Configuration()
        earlier.preferences.applicationShortcutsEnabled = false
        try ConfigurationStore(directory: directory).save(earlier)
        let store = ConfigurationStore(directory: directory)
        XCTAssertFalse(try store.load().preferences.featureEnabled(.windowSwitcher))
        XCTAssertFalse(try ConfigurationFile.decode(ConfigurationFile.encode(earlier)).preferences.featureEnabled(.windowSwitcher))

        // The example the file's own header offers turns on the command bar and nothing else.
        let text = try String(contentsOf: store.textFile, encoding: .utf8)
        XCTAssertTrue(text.contains("feature.window-switcher = true"), text)
        try Data((text + "feature.command-bar = true\n").utf8).write(to: store.textFile)
        let reloaded = ConfigurationStore(directory: directory)
        let configuration = try reloaded.load()
        XCTAssertTrue(configuration.preferences.featureEnabled(.commandBar))
        XCTAssertFalse(configuration.preferences.featureEnabled(.windowSwitcher))

        // The next save writes what is in effect; from then on the two are separate features.
        try reloaded.save(configuration)
        let saved = try String(contentsOf: store.textFile, encoding: .utf8)
        XCTAssertTrue(saved.contains("feature.window-switcher = false"), saved)
        try Data(saved.replacingOccurrences(of: "feature.window-switcher = false", with: "feature.window-switcher = true").utf8).write(to: store.textFile)
        let separate = try ConfigurationStore(directory: directory).load().preferences
        XCTAssertTrue(separate.featureEnabled(.windowSwitcher))
        XCTAssertFalse(separate.featureEnabled(.applicationShortcuts))
    }

    func testAConfigurationFrogStartedKeepsTheSwitcherAndShortcutsSeparateWhenConfigIsEdited() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let edits = ["feature.application-shortcuts = false", "feature.window-switcher = true", "feature.command-bar = true"]
        func expectSeparate(_ preferences: Preferences, _ context: String) {
            XCTAssertTrue(preferences.featureEnabled(.windowSwitcher), context)
            XCTAssertFalse(preferences.featureEnabled(.applicationShortcuts), context)
            XCTAssertTrue(preferences.featureEnabled(.commandBar), context)
        }

        // Saved as on the first launch, before anyone has opened Features.
        let fresh = directory.appendingPathComponent("fresh")
        let store = ConfigurationStore(directory: fresh)
        try store.save(try store.load())
        let text = try String(contentsOf: store.textFile, encoding: .utf8).components(separatedBy: "\n")
            .filter { line in !edits.contains { line.hasPrefix($0.components(separatedBy: " = ")[0] + " ") } }
        try Data((text.joined(separator: "\n") + edits.joined(separator: "\n") + "\n").utf8).write(to: store.textFile)
        let reloaded = ConfigurationStore(directory: fresh)
        let configuration = try reloaded.load()
        expectSeparate(configuration.preferences, "edited after the first save")
        try reloaded.save(configuration)
        XCTAssertTrue(try String(contentsOf: store.textFile, encoding: .utf8).contains("\nfeature.window-switcher = true\n"))

        // A config written by hand starts a first configuration as well.
        let handWritten = ConfigurationStore(directory: directory.appendingPathComponent("hand-written"))
        try FileManager.default.createDirectory(at: handWritten.directory, withIntermediateDirectories: true)
        try Data((edits.joined(separator: "\n") + "\n").utf8).write(to: handWritten.textFile)
        expectSeparate(try handWritten.load().preferences, "written by hand")
    }

    func testOnlyTheOriginalFiveFeaturesStartOn() {
        let preferences = Preferences()
        let on: Set<FeatureID> = [.writing, .dictation, .applicationShortcuts, .windowSwitcher, .stayAwake]
        for feature in FeatureID.allCases {
            XCTAssertEqual(preferences.featureEnabled(feature), on.contains(feature), feature.rawValue)
        }
    }

    func testTitlesSymbolsAndDetailsAreNonEmptyAndUnique() {
        for property in [\FeatureID.title, \.symbol, \.detail] {
            let values = FeatureID.allCases.map { $0[keyPath: property] }
            XCTAssertFalse(values.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            XCTAssertEqual(Set(values).count, values.count, "\(values)")
        }
    }

    func testEveryFeatureHasATextKey() {
        let keys = Set(TextConfiguration.keys)
        for feature in FeatureID.allCases where ![.windowSwitcher, .applicationShortcuts, .clipboard].contains(feature) {
            let kebab = feature.rawValue.reduce("") { $0 + ($1.isUppercase ? "-" + $1.lowercased() : String($1)) }
            XCTAssertTrue(keys.contains("feature.\(kebab)"), feature.rawValue)
        }
    }

    /// The default sidebar order, grouped by kind. A user's own arrangement is stored and kept.
    func testTheCatalogIsGroupedByKind() {
        XCTAssertEqual(FeatureID.allCases, [.writing, .explain, .dictation, .commandBar, .applicationShortcuts, .windows,
                                            .windowSwitcher, .clipboard, .scratchpad, .scripts,
                                            .usage, .systemMonitor, .stayAwake, .menuBar, .cleaner, .phone, .plugins])
    }

    func testEnsureToolkitRunsTheSwitcherMigration() {
        var preferences = Preferences()
        preferences.applicationShortcutsEnabled = false
        preferences.windowSwitcherEnabled = true
        XCTAssertNil(preferences.toolkit)
        preferences.ensureToolkit()
        XCTAssertNotNil(preferences.toolkit)
        XCTAssertFalse(preferences.windowSwitcherEnabled)
        let once = preferences
        preferences.ensureToolkit()
        XCTAssertEqual(preferences, once)

        var existing = Preferences()
        existing.toolkit = ToolkitPreferences()
        existing.toolkit?.commandBarHotkey = Hotkey(keyCode: 49, modifiers: 4096)
        existing.applicationShortcutsEnabled = false
        let before = existing
        existing.ensureToolkit()
        XCTAssertEqual(existing, before)
        XCTAssertTrue(existing.windowSwitcherEnabled)
    }

    func testImportRejectsInvalidSwitcherShortcut() {
        var configuration = Configuration()
        configuration.preferences.toolkit = ToolkitPreferences()
        configuration.preferences.toolkit?.windowSwitcherHotkey = Hotkey(keyCode: 48, modifiers: 0)
        XCTAssertThrowsError(try ConfigurationFile.validate(configuration))
    }
}
