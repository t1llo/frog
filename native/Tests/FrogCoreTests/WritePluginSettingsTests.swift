import XCTest
@testable import FrogCore

@MainActor
final class WritePluginSettingsTests: XCTestCase {
    private func store() throws -> (ConfigStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let store = ConfigStore(fileURL: folder.appendingPathComponent("config.toml"))
        try store.load()
        return (store, folder)
    }

    func testWritingSeedsOnceFromTheBubbleSettingsExplainKept() throws {
        let (store, _) = try store()
        var legacy = ExplainSettings()
        legacy.selectionBubble = true
        legacy.bubbleKeyboard = false
        legacy.bubbleMaxCharacters = 900
        legacy.bubbleExcludedApps = ["com.example.secret"]
        XCTAssertFalse(WritingConfig(legacy: legacy, explainOn: false).bubble.on, "the bubble ran only while Explain was on")
        XCTAssertTrue(try store.seedSection("writing") { WritingConfig(legacy: legacy, explainOn: true) })
        let seeded = try store.section("writing", as: WritingConfig.self).value
        XCTAssertTrue(seeded.bubble.on)
        XCTAssertFalse(seeded.bubble.keyboard)
        XCTAssertEqual(seeded.bubble.options.maxCharacters, 900)
        XCTAssertEqual(seeded.bubble.options.excludedApps, ["com.example.secret"])
        // Defaults are written too, so the table says it was seeded, with comments to read by.
        XCTAssertTrue(store.document.text.contains("double-click = true"))
        XCTAssertTrue(store.document.text.contains("# Also after a double- or triple-click"))

        // A table the person turned off is never seeded again.
        var off = seeded; off.bubble.on = false
        try store.update("writing", off)
        XCTAssertFalse(try store.seedSection("writing") { WritingConfig(legacy: legacy, explainOn: true) })
        XCTAssertFalse(try store.section("writing", as: WritingConfig.self).value.bubble.on)
    }

    func testExplainSeedsContextAndNotes() throws {
        let (store, _) = try store()
        var legacy = ExplainSettings()
        legacy.includeContext = false
        legacy.notes = true
        legacy.notesFolder = "~/Notes"
        legacy.notesMode = .append
        try store.seedSection("explain") { ExplainConfig(legacy: legacy) }
        let seeded = try store.section("explain", as: ExplainConfig.self).value
        XCTAssertFalse(seeded.context)
        XCTAssertTrue(seeded.notes.on)
        XCTAssertEqual(seeded.notes.folder, "~/Notes")
        XCTAssertEqual(seeded.notes.mode, .append)
        XCTAssertTrue(store.document.text.contains("mode = \"append\""))
        var broken = seeded; broken.notes.folder = "Notes"; broken.notes.file = "../outside.md"
        XCTAssertThrowsError(try broken.validate())
        // An edit made outside Frog keeps what is valid and drops the rest, with the reason.
        let (kept, issue) = broken.sanitized()
        XCTAssertNil(kept.notes.folder)
        XCTAssertEqual(kept.notes.file, ExplainConfig.Notes().file)
        XCTAssertNoThrow(try kept.validate())
        XCTAssertNotNil(issue)
        XCTAssertNil(seeded.sanitized().issue)
    }

    func testMaxCharactersStayInRange() {
        var bubble = WritingConfig.Bubble()
        bubble.maxCharacters = 5
        XCTAssertEqual(bubble.options.maxCharacters, SelectionBubbleOptions.characterRange.lowerBound)
    }
}
