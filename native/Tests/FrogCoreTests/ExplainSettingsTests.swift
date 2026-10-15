import XCTest
@testable import FrogCore

final class ExplainSettingsTests: XCTestCase {
    func testAnEmptyObjectDecodesToTheDefaults() throws {
        let settings = try JSONDecoder().decode(ExplainSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, ExplainSettings())
        XCTAssertTrue(settings.includeContext)
        XCTAssertTrue(Preferences().explainSettings.includeContext)
        XCTAssertFalse(Preferences().featureEnabled(.explain))
    }

    func testIncludeContextRoundTripsThroughTheTextFile() throws {
        let companion = try TextConfiguration.companion(Configuration())
        let loaded = try TextConfiguration.decode("explain.context = false\n", companion: companion)
        XCTAssertEqual(loaded.preferences.toolkit?.explain?.includeContext, false)
        XCTAssertFalse(loaded.preferences.explainSettings.includeContext)
        let text = try TextConfiguration.render(loaded)
        XCTAssertTrue(text.contains("\nexplain.context = false\n"), text)
        XCTAssertEqual(try TextConfiguration.decode(text, companion: TextConfiguration.companion(loaded)), loaded)
        try ConfigurationFile.validate(loaded)
    }

    func testMissingSettingsRenderNothingAndAreFilledWhenEdited() throws {
        let plain = try TextConfiguration.render(Configuration())
        XCTAssertFalse(plain.contains("explain."), plain)

        // A file that sets another toolkit value reads Explain's defaults.
        var configuration = Configuration()
        configuration.preferences.setFeature(.explain, enabled: true)
        let edited = try TextConfiguration.decode(TextConfiguration.render(configuration), companion: TextConfiguration.companion(configuration))
        XCTAssertTrue(edited.preferences.featureEnabled(.explain))
        XCTAssertTrue(edited.preferences.explainSettings.includeContext)

        // Settings that hold their default stay out of an existing file that does not name them.
        var withSettings = configuration
        withSettings.preferences.toolkit?.explain = ExplainSettings()
        let existing = try TextConfiguration.render(configuration)
        XCTAssertFalse(try TextConfiguration.render(withSettings, preserving: existing).contains("explain.context"))
        XCTAssertTrue(try TextConfiguration.render(withSettings).contains("\nexplain.context = true\n"))
    }

    func testNoteSettingsRoundTripThroughTheTextFile() throws {
        let companion = try TextConfiguration.companion(Configuration())
        let text = """
        explain.notes = true
        explain.notes-folder = ~/Notes/Vault
        explain.notes-mode = append
        explain.notes-file = Journal/YYYY/MM-DD.md
        explain.notes-open = true

        """
        let loaded = try TextConfiguration.decode(text, companion: companion)
        let settings = loaded.preferences.explainSettings
        XCTAssertTrue(settings.notes)
        XCTAssertEqual(settings.notesFolder, "~/Notes/Vault")
        XCTAssertEqual(settings.notesMode, .append)
        XCTAssertEqual(settings.notesFile, "Journal/YYYY/MM-DD.md")
        XCTAssertTrue(settings.notesOpen)
        XCTAssertEqual(settings.notesFolderURL?.path, NSHomeDirectory() + "/Notes/Vault")
        let rendered = try TextConfiguration.render(loaded)
        for line in text.split(separator: "\n") { XCTAssertTrue(rendered.contains("\n\(line)\n"), "\(line)\n\(rendered)") }
        XCTAssertEqual(try TextConfiguration.decode(rendered, companion: TextConfiguration.companion(loaded)), loaded)
        try ConfigurationFile.validate(loaded)

        let defaults = try JSONDecoder().decode(ExplainSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(defaults.notes)
        XCTAssertNil(defaults.notesFolder)
        XCTAssertEqual(defaults.notesMode, .perAnswer)
        XCTAssertEqual(defaults.notesFile, "Daily/YYYY-MM-DD.md")
        XCTAssertFalse(defaults.notesOpen)
    }

    func testAFolderPathTooLongForTheTextFileStaysInConfigJSON() throws {
        var configuration = Configuration()
        var settings = ExplainSettings()
        settings.notesFolder = "/" + Array(repeating: "folder", count: 50).joined(separator: "/")
        configuration.preferences.ensureToolkit()
        configuration.preferences.toolkit?.explain = settings
        let rendered = try TextConfiguration.render(configuration)
        XCTAssertFalse(rendered.contains("explain.notes-folder"), rendered)
        let companion = try TextConfiguration.companion(configuration)
        XCTAssertTrue(String(decoding: companion, as: UTF8.self).contains("folder/folder"))
        XCTAssertEqual(try TextConfiguration.decode(rendered, companion: companion).preferences.explainSettings.notesFolder,
                       settings.notesFolder)
    }

    func testAFolderWithoutAFullPathOrABadFilePatternIsRefused() {
        var settings = ExplainSettings()
        settings.notesFolder = "Notes"
        XCTAssertThrowsError(try settings.validate()) { XCTAssertEqual($0.localizedDescription, "Choose a notes folder with a full path.") }
        settings.notesFolder = "/Notes\u{7}"
        XCTAssertThrowsError(try settings.validate())
        settings.notesFolder = "~/Notes"
        XCTAssertNoThrow(try settings.validate())
        settings.notesFile = "../Daily.md"
        XCTAssertThrowsError(try settings.validate()) {
            XCTAssertEqual($0.localizedDescription, "Enter a file path inside the notes folder, such as Daily/YYYY-MM-DD.md.")
        }
        settings.notesFile = "Daily.txt"
        XCTAssertThrowsError(try settings.validate()) { XCTAssertEqual($0.localizedDescription, "Choose a Markdown file (.md).") }
    }
}
