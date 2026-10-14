import XCTest
@testable import FrogCore

final class ConfigurationFileTests: XCTestCase {
    func testLegacyPreferencesDefaultIndicatorOnAndPersistOptOut() throws {
        let legacy = Data(#"{"historyEnabled":false,"historyLimit":200,"historyRetentionDays":30}"#.utf8)
        var preferences = try JSONDecoder().decode(Preferences.self, from: legacy)
        XCTAssertTrue(preferences.showProcessingIndicator)
        XCTAssertTrue(preferences.windowSwitcherEnabled)
        preferences.showProcessingIndicator = false
        preferences.windowSwitcherEnabled = false
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences)), preferences)
    }
    private func configured() -> Configuration {
        var configuration = Configuration()
        var provider = ProviderConfiguration(name: "My local model", kind: .ollama)
        provider.models.append(ProviderModel(id: "another-model", name: "My second model"))
        configuration.providers = [provider]
        configuration.defaultProviderID = provider.id
        configuration.rules[3].providerID = provider.id
        configuration.rules[3].model = "another-model"
        configuration.rules[3].instructions = "Translate into {{language}}."
        configuration.rules[3].targetLanguage = "日本語"
        configuration.preferences.historyLimit = 50
        return configuration
    }

    func testPortableRoundTripIncludesAllSettingsAndOnlyConfigurationFields() throws {
        let configuration = configured()
        let data = try ConfigurationFile.encode(configuration)
        XCTAssertEqual(try ConfigurationFile.decode(data), configuration)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "providers", "defaultProviderID", "rules", "preferences"])
        let provider = try XCTUnwrap((object["providers"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(provider.keys), ["id", "name", "kind", "endpoint", "model", "models"])
        XCTAssertEqual(data.last, 0x0A)
    }

    func testInvalidReferencesVersionsBoundsAndDuplicateShortcutsAreRejected() throws {
        let valid = configured()
        var future = valid; future.version = 2
        var missingDefault = valid; missingDefault.defaultProviderID = UUID()
        var missingRuleProvider = valid; missingRuleProvider.rules[0].providerID = UUID()
        var duplicated = valid; duplicated.providers.append(valid.providers[0])
        var duplicateShortcut = valid; duplicateShortcut.rules[1].hotkey = valid.rules[0].hotkey
        var badHistory = valid; badHistory.preferences.historyLimit = 0
        var badLanguage = valid; badLanguage.rules[3].targetLanguage = ""
        var unsafeEndpoint = valid; unsafeEndpoint.providers[0].endpoint = "https://secret@example.com/v1"
        var menuConflict = valid
        menuConflict.preferences.setFeature(.menuBar, enabled: true)
        menuConflict.preferences.setFeature(.commandBar, enabled: true)
        var menuBar = MenuBarPreferences(); menuBar.hotkey = menuConflict.preferences.toolkitSettings.effectiveCommandBarHotkey
        menuConflict.preferences.toolkit?.menuBar = menuBar
        for configuration in [future, missingDefault, missingRuleProvider, duplicated, duplicateShortcut, badHistory, badLanguage, unsafeEndpoint, menuConflict] {
            XCTAssertThrowsError(try ConfigurationFile.decode(JSONEncoder().encode(configuration)))
        }
        XCTAssertThrowsError(try ConfigurationFile.decode(Data("{ broken".utf8)))
        XCTAssertThrowsError(try ConfigurationFile.decode(Data(repeating: 32, count: ConfigurationFile.maximumBytes + 1)))
    }

    func testFileRoundTripWritesPrivateHumanReadableJSON() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Frog-configuration.json")
        let configuration = configured()
        try ConfigurationFile.write(configuration, to: file)
        XCTAssertEqual(try ConfigurationFile.read(from: file), configuration)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try ConfigurationFile.read(from: directory))
    }

    func testExplicitImportBacksUpCorruptSettingsBeforeReplacingThem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        let broken = Data("{broken configuration".utf8)
        try broken.write(to: file)
        let store = ConfigurationStore(directory: directory)
        XCTAssertThrowsError(try store.save(configured()))
        let replacement = configured()
        let backup = try XCTUnwrap(store.replaceFromImport(replacement))
        XCTAssertEqual(try Data(contentsOf: backup), broken)
        XCTAssertEqual(try store.load(), replacement)
    }

    func testLegacyConfigurationKeepsModelIDsAndAddsExistingOverrides() throws {
        let original = configured()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var providers = try XCTUnwrap(object["providers"] as? [[String: Any]])
        providers[0].removeValue(forKey: "models")
        providers[0]["model"] = "legacy-default"
        object["providers"] = providers
        let migrated = try ConfigurationFile.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(migrated.providers[0].model, "legacy-default")
        XCTAssertEqual(migrated.providers[0].models.map(\.id), ["legacy-default", "another-model"])
        XCTAssertEqual(migrated.rules, original.rules)
        XCTAssertEqual(migrated.providers[0].id, original.providers[0].id)
        XCTAssertEqual(try ConfigurationFile.decode(ConfigurationFile.encode(migrated)), migrated)
    }

    func testConfiguredModelValidationRejectsDuplicatesMissingDefaultAndUnknownOverride() throws {
        let valid = configured()
        var duplicate = valid; duplicate.providers[0].models.append(duplicate.providers[0].models[0])
        var missingDefault = valid; missingDefault.providers[0].model = "not-configured"
        var unknownOverride = valid; unknownOverride.rules[3].model = "not-configured"
        var empty = valid; empty.providers[0].models = []
        var invalid = valid; invalid.providers[0].models.append(ProviderModel(id: "bad\nmodel"))
        for configuration in [duplicate, missingDefault, unknownOverride, empty, invalid] {
            XCTAssertThrowsError(try ConfigurationFile.decode(JSONEncoder().encode(configuration)))
        }
    }

    func testTextMigrationPreservesSettingsBackupAndPortableExtensionFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = configured()
        var appearance = AppearancePreferences(); appearance.theme = .nord; appearance.mode = .dark
        appearance.darkPalette = ["background": "112233", "accent": "AABBCC", "on-accent": "001122"]
        appearance.lightPalette = ["text": "223344"]
        configuration.preferences.appearance = appearance
        var toolkit = ToolkitPreferences(); toolkit.enabled["usage"] = true
        toolkit.usage = UsageDisplayPreferences(provider: "OpenAI", range: "30d", metric: "Cache read", allDevices: true, loginSource: "Pi")
        var menuBar = MenuBarPreferences(); menuBar.autoHide = false; menuBar.autoHideSeconds = 12.5
        menuBar.startCollapsed = true; menuBar.permanentlyHiddenSection = true; menuBar.hoverToReveal = true
        menuBar.hotkey = Hotkey(keyCode: 46, modifiers: 4096 | 2048)
        toolkit.menuBar = menuBar; toolkit.enabled["menuBar"] = true
        configuration.preferences.toolkit = toolkit
        var workflow = WorkflowPreferences(); workflow.shortcutPanelHotkey = Hotkey(keyCode: 40, modifiers: 4096 | 2048)
        let source = try HuggingFaceSource("owner/custom-config-test")
        let metadata = try JSONSerialization.data(withJSONObject: ["siblings": ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"].map { ["rfilename": $0] }])
        let textConfig = try JSONSerialization.data(withJSONObject: ["model_type": "qwen3", "quantization": ["bits": 4, "group_size": 64]])
        let custom = try XCTUnwrap(HuggingFaceModels.descriptors(source: source, metadata: metadata, textConfig: textConfig).first)
        configuration.localModels = [custom]
        workflow.defaultLocalTextModelID = custom.id; workflow.cleanupModelID = custom.id
        configuration.preferences.workflows = workflow
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ConfigurationFile.encode(configuration)) as? [String: Any])
        object["futureExtension"] = ["keep": [1, 2, 3]]
        var providers = try XCTUnwrap(object["providers"] as? [[String: Any]])
        providers[0]["futureConnectionField"] = "keep me"
        object["providers"] = providers
        let original = try JSONSerialization.data(withJSONObject: object)
        let store = ConfigurationStore(directory: directory)
        try original.write(to: store.file)
        var migrated = try store.load()
        XCTAssertEqual(migrated, configuration)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("config-legacy-backup-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
        XCTAssertTrue(try String(contentsOf: store.textFile).contains("shortcut.rules = ctrl+alt+k"))
        migrated.preferences.historyLimit = 43
        try store.save(migrated)
        let reloaded = try ConfigurationStore(directory: directory).load()
        XCTAssertEqual(reloaded, migrated)
        XCTAssertEqual(reloaded.localModels, [custom])
        XCTAssertEqual(reloaded.preferences.toolkit?.menuBar, menuBar)
        let exported = try ConfigurationFile.encode(reloaded)
        XCTAssertEqual(try ConfigurationFile.decode(exported), migrated)
        let exportObject = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        XCTAssertNotNil(exportObject["futureExtension"])
        XCTAssertEqual((exportObject["providers"] as? [[String: Any]])?.first?["futureConnectionField"] as? String, "keep me")
        let second = ConfigurationStore(directory: directory.appendingPathComponent("imported"))
        try second.replaceFromImport(ConfigurationFile.decode(exported))
        XCTAssertEqual(try second.load(), migrated)
    }

    func testExternalTextEditsReloadAtomicallyAndUIChangesPreserveComments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory)
        var original = configured(); try store.save(original)
        let text = try String(contentsOf: store.textFile)
        let edited = "# chezmoi-owned notes\n" + text.replacingOccurrences(of: "history-limit = 50", with: "  history-limit  =  31  # keep this note") + "palette.dark.surface = #123456 # card color\n"
        try Data(edited.utf8).write(to: store.textFile)
        original.preferences.historyLimit = 20
        XCTAssertThrowsError(try store.save(original)) { XCTAssertTrue($0.localizedDescription.contains("Reload")) }
        XCTAssertEqual(try String(contentsOf: store.textFile), edited)
        var reloaded = try store.load()
        XCTAssertEqual(reloaded.preferences.historyLimit, 31)
        XCTAssertEqual(reloaded.preferences.appearance?.darkPalette?["surface"], "123456")
        reloaded.preferences.historyLimit = 32
        try store.save(reloaded)
        let saved = try String(contentsOf: store.textFile)
        XCTAssertTrue(saved.hasPrefix("# chezmoi-owned notes\n"))
        XCTAssertTrue(saved.contains("  history-limit  =  32  # keep this note"))
        XCTAssertTrue(saved.contains("palette.dark.surface = #123456 # card color"))
        // A removed key resets its default rather than resurrecting its former JSON value.
        let reset = saved.replacingOccurrences(of: "  history-limit  =  32  # keep this note\n", with: "")
        try Data(reset.utf8).write(to: store.textFile)
        XCTAssertEqual(try store.load().preferences.historyLimit, 200)
    }

    func testAFieldThatCannotBeReadIsNamedByItsPlaceInTheDocument() throws {
        let data = try ConfigurationFile.encode(configured())
        func refusal(_ edit: (inout [String: Any]) throws -> Void) throws -> String {
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            try edit(&root)
            var message = ""
            XCTAssertThrowsError(try ConfigurationFile.decode(JSONSerialization.data(withJSONObject: root))) { message = $0.localizedDescription }
            return message
        }
        // A value another version of Frog wrote, for example a kind of connection this one does not have.
        let unsupported = try refusal { root in
            var providers = try XCTUnwrap(root["providers"] as? [[String: Any]])
            providers[0]["kind"] = "laterService"; root["providers"] = providers
        }
        XCTAssertTrue(unsupported.contains("'providers[0].kind' has a value this version of Frog does not support"), unsupported)
        let nested = try refusal { root in
            var rules = try XCTUnwrap(root["rules"] as? [[String: Any]])
            rules[1]["action"] = ["category": "system", "systemAction": "laterAction", "cleanup": false]; root["rules"] = rules
        }
        XCTAssertTrue(nested.contains("'rules[1].action.systemAction' has a value"), nested)
        let missing = try refusal { root in
            var rules = try XCTUnwrap(root["rules"] as? [[String: Any]])
            rules[2].removeValue(forKey: "name"); root["rules"] = rules
        }
        XCTAssertTrue(missing.contains("'rules[2].name' is missing"), missing)
        XCTAssertTrue(try refusal { $0["version"] = "one" }.contains("'version' has a value"))
        XCTAssertTrue(try refusal { $0.removeValue(forKey: "preferences") }.contains("'preferences' is missing"))
        // Something that is no configuration at all is still called that.
        for bytes in ["{ broken", "[]", "7"] {
            XCTAssertThrowsError(try ConfigurationFile.decode(Data(bytes.utf8))) {
                XCTAssertEqual($0.localizedDescription, "This is not a valid Frog configuration file. Check its JSON fields and values.")
            }
        }
        // The same place is named when the document is the companion of the text file.
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: TextConfiguration.companion(configured())) as? [String: Any])
        var providers = try XCTUnwrap(root["providers"] as? [[String: Any]])
        providers[0]["kind"] = "laterService"; root["providers"] = providers
        XCTAssertThrowsError(try TextConfiguration.decode("", companion: JSONSerialization.data(withJSONObject: root))) {
            XCTAssertTrue($0.localizedDescription.contains("'providers[0].kind'"), $0.localizedDescription)
        }
    }

    func testAProblemInConfigJSONIsReportedThereAndOnlyAssignmentProblemsListTheAssignments() throws {
        let configuration = configured()
        let text = try TextConfiguration.render(configuration), json = try TextConfiguration.companion(configuration)
        // A connection was removed from config.json while a rule still uses it.
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        root["providers"] = []; root.removeValue(forKey: "defaultProviderID")
        XCTAssertThrowsError(try TextConfiguration.decode(text, companion: JSONSerialization.data(withJSONObject: root))) {
            XCTAssertEqual($0.localizedDescription, "config.json: A rule refers to a provider that is missing from this configuration. \(TextConfiguration.keptRemark)")
        }
        // Two assignments that are valid one by one but conflict with each other are still listed.
        let conflicting = text + "shortcut.rules = ctrl+alt+j\nshortcut.cancel-recording = ctrl+alt+j\n"
        XCTAssertThrowsError(try TextConfiguration.decode(conflicting, companion: json)) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("config: The cancel shortcut conflicts with another global shortcut. Check assignments: "), $0.localizedDescription)
            XCTAssertTrue($0.localizedDescription.contains("shortcut.cancel-recording (line "), $0.localizedDescription)
        }
    }

    func testCheckingAPairSkipsUnknownFieldBookkeepingButNoValidation() throws {
        let configuration = configured()
        let json = try TextConfiguration.companion(configuration), text = try TextConfiguration.render(configuration)
        let full = try TextConfiguration.decode(text, companion: json)
        let checked = try TextConfiguration.decode(text, companion: json, retainingUnknownFields: false)
        XCTAssertEqual(checked, full)
        XCTAssertNotNil(full.originalJSON); XCTAssertNotNil(full.knownJSON)
        XCTAssertNil(checked.originalJSON); XCTAssertNil(checked.knownJSON)
        // What a save is about to write is refused for the same reasons, with the same words.
        var conflicting = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        conflicting["defaultProviderID"] = UUID().uuidString
        let pairs = [("text-model = missing\n", json), ("history-limit = 0\n", json), ("shortcut.rules = cmd+c\n", json),
                     (text, Data("{}".utf8)), (text, try JSONSerialization.data(withJSONObject: conflicting))]
        for (text, json) in pairs {
            var expected = ""
            XCTAssertThrowsError(try TextConfiguration.decode(text, companion: json)) { expected = $0.localizedDescription }
            XCTAssertThrowsError(try TextConfiguration.decode(text, companion: json, retainingUnknownFields: false)) {
                XCTAssertEqual($0.localizedDescription, expected)
            }
            XCTAssertTrue(expected.hasPrefix("config"), expected)
        }
    }

    func testInvalidTextAndExternalJSONKeepLastWorkingStateAndExactFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory)
        let configuration = configured(); try store.save(configuration)
        let text = try Data(contentsOf: store.textFile), json = try Data(contentsOf: store.file)
        for invalid in ["unknown-key = true", "history-limit = 0", "history-enabled = maybe", "palette.dark.text = #xyz", "theme = missing", "shortcut.rules = ctrl+unknown", "shortcut.rules = cmd+c", "shortcut.rules = cmd+shift+v", "audio-model = missing", "menubar.auto-hide-seconds = 0", "history-limit = 2\nhistory-limit = 3", "transparency = nan"] {
            let bytes = Data(("# error fixture\n" + invalid).utf8)
            try bytes.write(to: store.textFile)
            XCTAssertThrowsError(try store.load()) { XCTAssertTrue($0.localizedDescription.contains("config:2:") || $0.localizedDescription.contains("config:3:")) }
            XCTAssertThrowsError(try store.save(configuration))
            XCTAssertEqual(try Data(contentsOf: store.textFile), bytes)
            XCTAssertEqual(try Data(contentsOf: store.file), json)
        }
        try text.write(to: store.textFile)
        XCTAssertEqual(try store.load(), configuration)
        let editedJSON = Data("{broken external JSON".utf8)
        try editedJSON.write(to: store.file)
        XCTAssertThrowsError(try store.save(configuration))
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.file), editedJSON)
        XCTAssertEqual(try Data(contentsOf: store.textFile), text)
        try FileManager.default.removeItem(at: store.file)
        XCTAssertThrowsError(try store.load()) { XCTAssertTrue($0.localizedDescription.contains("config.json is missing")) }
        try json.write(to: store.file)
        XCTAssertEqual(try store.load(), configuration)
    }

    func testASavedMicrophoneIsReadAsAnEarlierDeviceNumberAndAsAPersistentIdentifier() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory)
        try store.save(Configuration())
        // Earlier versions saved the number of a connection. The key must stay readable: a file that
        // still holds one would otherwise be refused as a whole.
        try Data((try String(contentsOf: store.textFile) + "microphone = 42\n").utf8).write(to: store.textFile)
        var configuration = try store.load()
        XCTAssertEqual(configuration.preferences.workflows?.microphoneID, "42")
        // The identifiers macOS gives built-in, USB and Bluetooth inputs are saved and read unchanged.
        for identifier in ["BuiltInMicrophoneDevice", "AppleUSBAudioEngine:Example Audio:USB Microphone #2:14100000:1", "00-11-22-33-44-55:input"] {
            var workflows = configuration.preferences.workflowSettings
            workflows.microphoneID = identifier
            configuration.preferences.workflows = workflows
            try store.save(configuration)
            XCTAssertEqual(try ConfigurationStore(directory: directory).load().preferences.workflows?.microphoneID, identifier)
        }
    }
}
