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
        for configuration in [future, missingDefault, missingRuleProvider, duplicated, duplicateShortcut, badHistory, badLanguage, unsafeEndpoint] {
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
        let file = directory.appendingPathComponent("configuration.json")
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
}
