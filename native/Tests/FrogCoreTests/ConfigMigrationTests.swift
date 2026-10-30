import XCTest
@testable import FrogCore

private struct ExplainSection: ConfigSection {
    var context = true
    var notes = false
    var notesFolder: String?
}

final class ConfigMigrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigMigrationTests-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let legacyText = """
    theme = nord
    transparency = 0.15
    history-limit = 50
    feature.command-bar = true
    feature.writing = false
    feature.scratchpad = true
    feature.menu-bar = true
    explain.notes = true
    explain.notes-folder = ~/Notes
    hidden-sidebar-items = ["usage", "applicationShortcuts"]
    palette.dark.background = #1A1B26

    """

    func testItWritesTheCoreAndPluginsTablesOnceAndKeepsTheOldFiles() throws {
        let text = directory.appendingPathComponent("config")
        try Data(legacyText.utf8).write(to: text)
        var migration = ConfigMigration()
        migration.register(section: "explain") { legacy in
            let explain = legacy.preferences.toolkitSettings.explain ?? ExplainSettings()
            return ["context": .bool(explain.includeContext), "notes": .bool(explain.notes)]
        }
        migration.register(section: "explain-typed", as: ExplainSection.self) { legacy in
            let explain = legacy.preferences.toolkitSettings.explain ?? ExplainSettings()
            return ExplainSection(context: explain.includeContext, notes: explain.notes, notesFolder: explain.notesFolder)
        }
        let written = try XCTUnwrap(migration.run(in: directory))
        let toml = directory.appendingPathComponent("config.toml")
        XCTAssertEqual(try Data(contentsOf: toml), written.data)
        XCTAssertEqual(try (FileManager.default.attributesOfItem(atPath: toml.path)[.posixPermissions] as! NSNumber).intValue, 0o600)
        XCTAssertEqual(try String(contentsOf: text, encoding: .utf8), legacyText, "the old file is left as it was")

        let document = try ConfigDocument(data: Data(contentsOf: toml))
        XCTAssertEqual(try document.pluginSwitches(), [
            "writing": false, "explain": false, "dictation": true, "command-bar": true, "shortcuts": true, "windows": false,
            "window-switcher": true, "clipboard": false, "notes": true, "scripts": false, "llm-usage": false,
            "system-monitor": false, "stay-awake": true, "hidden-bar": true, "app-cleaner": false, "phone": false, "plugins": false,
        ])
        XCTAssertEqual(document.value(at: ["theme"]), "nord")
        XCTAssertEqual(document.value(at: ["appearance"]), "system")
        XCTAssertEqual(document.value(at: ["transparency"]), .float(0.15))
        XCTAssertEqual(document.value(at: ["history-limit"]), 50)
        XCTAssertEqual(document.value(at: ["history-retention-days"]), 30, "absent keys take the old defaults")
        XCTAssertEqual(document.value(at: ["model-idle-seconds"]), 120)
        XCTAssertEqual(document.value(at: ["hidden-sidebar-items"]), ["llm-usage", "shortcuts"])
        XCTAssertEqual(document.value(at: ["palette", "dark", "background"]), "#1A1B26")
        XCTAssertEqual(document.value(at: ["explain"]), ["context": true, "notes": true])
        XCTAssertEqual(try document.section("explain-typed", as: ExplainSection.self).value, ExplainSection(context: true, notes: true, notesFolder: "~/Notes"))
        XCTAssertTrue(document.text.hasPrefix(ConfigMigration.heading + "\nappearance = \"system\"\ntheme = \"nord\"\n"), document.text)
        XCTAssertTrue(document.text.contains("\n\n[plugins]\nwriting = false\n"), document.text)
        XCTAssertFalse(document.text.contains("[explain-typed]\ncontext"), "typed sections leave defaults out")

        // Once config.toml exists, nothing is migrated again.
        try Data("theme = \"dracula\"\n".utf8).write(to: toml)
        XCTAssertNil(try migration.run(in: directory))
        XCTAssertEqual(try String(contentsOf: toml, encoding: .utf8), "theme = \"dracula\"\n")
    }

    func testWithoutOldFilesNothingIsWritten() throws {
        XCTAssertNil(try ConfigMigration().run(in: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.toml").path))
    }

    func testAnOnlyJSONConfigurationMigratesWithOldDefaults() throws {
        var configuration = Configuration()
        configuration.preferences.setFeature(.phone, enabled: true)
        configuration.preferences.setFeature(.stayAwake, enabled: false)
        try ConfigurationFile.write(configuration, to: directory.appendingPathComponent("config.json"))
        let document = try XCTUnwrap(ConfigMigration().run(in: directory))
        let plugins = try document.pluginSwitches()
        XCTAssertEqual(plugins["phone"], true)
        XCTAssertEqual(plugins["stay-awake"], false)
        XCTAssertEqual(plugins["writing"], true)
        XCTAssertEqual(document.value(at: ["theme"]), "minimal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path))
    }

    func testAnUnreadableOldFileWritesNothing() throws {
        try Data("feature.nonsense = 1\n".utf8).write(to: directory.appendingPathComponent("config"))
        XCTAssertThrowsError(try ConfigMigration().run(in: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.toml").path))
    }

    func testPluginIDs() {
        XCTAssertEqual(FeatureID.allCases.map(ConfigMigration.pluginID(for:)), [
            "writing", "explain", "dictation", "command-bar", "shortcuts", "windows", "window-switcher", "clipboard", "notes",
            "scripts", "llm-usage", "system-monitor", "stay-awake", "hidden-bar", "app-cleaner", "phone", "plugins",
        ])
    }
}
