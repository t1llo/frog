import XCTest
import FrogCore
@testable import FrogApp

/// How `[writing]` and `[explain]` take over the settings Explain kept, on isolated data.
@MainActor
final class WritePluginSeedTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    /// A configuration from before the tables: the bubble on, one rule left out of it, notes in a folder.
    private func legacyConfiguration(explainOn: Bool) throws -> (Configuration, Rule) {
        var configuration = Configuration()
        let hidden = try XCTUnwrap(configuration.rules.first { $0.category == .text })
        var explain = ExplainSettings()
        explain.selectionBubble = true
        explain.bubbleHiddenRules = [hidden.id]
        explain.includeContext = false
        explain.notesFolder = "/tmp/frog-test-notes"
        var toolkit = configuration.preferences.toolkit ?? ToolkitPreferences()
        toolkit.explain = explain
        configuration.preferences.toolkit = toolkit
        configuration.preferences.setFeature(.explain, enabled: explainOn)
        try ConfigurationStore(directory: directory).save(configuration)
        return (configuration, hidden)
    }

    private func model() -> AppModel {
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in nil }, readAccessibility: { true },
                             systemStatusTick: { try await Task.sleep(for: .seconds(3_600)) })
        addTeardownBlock { model.shutdown() }
        return model
    }

    func testTheMoveHappensOnceAndARemovedTableStartsFromDefaults() async throws {
        let (_, hidden) = try legacyConfiguration(explainOn: true)
        let model = model()
        model.start()
        await model.pluginHost.syncAndWait()
        let writing = try model.settingsFile.section("writing", as: WritingConfig.self).value
        XCTAssertTrue(writing.bubble.on)
        XCTAssertFalse(try XCTUnwrap(model.configuration.rules.first { $0.id == hidden.id }).showsInBubble)
        XCTAssertFalse(model.explainConfig.context)
        XCTAssertEqual(model.configuration.preferences.workflowSettings.writingSettingsMoved, true)
        XCTAssertEqual(model.configuration.preferences.workflowSettings.explainSettingsMoved, true)

        // The person removes both tables; the old values do not come back.
        try model.settingsFile.edit { document in
            try document.removeValue(at: ["writing"]); try document.removeValue(at: ["explain"])
        }
        model.pluginHost.settingsChanged()
        model.seedWritingSettings(); model.seedExplainSettings()
        XCTAssertNil(model.settingsFile.document.value(at: ["writing"]))
        XCTAssertEqual(model.explainConfig, ExplainConfig())
    }

    func testTheBubbleStartsOnOnlyWhereItRanBefore() async throws {
        _ = try legacyConfiguration(explainOn: false)
        let model = model()
        model.seedWritingSettings()
        XCTAssertFalse(try model.settingsFile.section("writing", as: WritingConfig.self).value.bubble.on,
                       "with Explain off the old bubble never showed")
    }

    func testSettingsThatCouldNotBeReadAreNotReplacedByDefaults() throws {
        try Data("{ not a configuration".utf8).write(to: directory.appendingPathComponent("config.json"))
        let model = model()
        XCTAssertFalse(model.configurationLoaded)
        model.seedWritingSettings(); model.seedExplainSettings()
        XCTAssertNil(model.settingsFile.document.value(at: ["writing"]))
        XCTAssertNil(model.settingsFile.document.value(at: ["explain"]))
    }

    func testAnOutsideEditCannotSendNotesToARelativeFolder() async throws {
        _ = try legacyConfiguration(explainOn: true)
        let model = model()
        model.start()
        await model.pluginHost.syncAndWait()
        var edited = model.explainConfig
        edited.notes.folder = "Notes"
        try model.settingsFile.update("explain", edited)
        model.pluginHost.settingsChanged()
        let plugin = try XCTUnwrap(model.pluginHost.running["explain"] as? ExplainPlugin)
        XCTAssertNil(plugin.settings.notes.folder)
        XCTAssertNil(model.explainConfig.notes.folder)
    }
}
