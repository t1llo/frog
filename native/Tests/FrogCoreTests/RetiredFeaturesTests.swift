import XCTest
@testable import FrogCore

/// Snippets and the shelf became part of Notes, and Quick actions became command bar rows.
final class RetiredFeaturesTests: XCTestCase {
    private func configuration(enabled: [String: Bool], hidden: Set<String> = [], pinned: Set<String> = [], order: [String] = []) throws -> Data {
        var configuration = Configuration()
        configuration.preferences.ensureToolkit()
        configuration.preferences.toolkit?.enabled = enabled
        configuration.preferences.toolkit?.hiddenSidebarItems = hidden
        configuration.preferences.toolkit?.pinnedSidebarItems = pinned
        configuration.preferences.toolkit?.sidebarOrder = order
        return try JSONEncoder().encode(configuration)
    }

    func testSomeoneWhoUsedSnippetsOrTheShelfFindsNotesTurnedOn() throws {
        for retired in ["snippets", "shelf"] {
            let loaded = try ConfigurationFile.decode(configuration(enabled: [retired: true, "scratchpad": false]))
            XCTAssertTrue(loaded.preferences.featureEnabled(.scratchpad), retired)
        }
        let quick = try ConfigurationFile.decode(configuration(enabled: ["quickActions": true, "snippets": false]))
        XCTAssertFalse(quick.preferences.featureEnabled(.scratchpad), "Quick actions had nothing in Notes")
    }

    func testRetiredIDsAreDroppedAndStayDroppedAfterASave() throws {
        var loaded = try ConfigurationFile.decode(configuration(
            enabled: ["snippets": true, "shelf": true, "quickActions": true, "usage": true],
            hidden: ["shelf", "usage"], pinned: ["quickActions", "scripts"], order: ["snippets", "scripts", "shelf"]))
        let toolkit = try XCTUnwrap(loaded.preferences.toolkit)
        XCTAssertEqual(toolkit.enabled, ["scratchpad": true, "usage": true])
        XCTAssertEqual(toolkit.hiddenSidebarItems, ["usage"])
        XCTAssertEqual(toolkit.pinnedSidebarItems, ["scripts"])
        XCTAssertEqual(toolkit.sidebarOrder, ["scripts"])

        // Turned off again, Notes stays off: the save must not keep the old switches as unknown fields.
        loaded.preferences.setFeature(.scratchpad, enabled: false)
        let saved = try ConfigurationFile.encode(loaded)
        let text = String(decoding: saved, as: UTF8.self)
        for id in ["snippets", "shelf", "quickActions"] { XCTAssertFalse(text.contains("\"\(id)\""), id) }
        XCTAssertFalse(try ConfigurationFile.decode(saved).preferences.featureEnabled(.scratchpad))
    }

    func testATextFileWithRetiredKeysLoadsAndTheNextSaveLeavesThemOut() throws {
        let companion = try TextConfiguration.companion(Configuration())
        let text = """
        feature.snippets = true
        feature.shelf = false
        feature.quick-actions = true
        hidden-sidebar-items = ["shelf", "usage"]
        sidebar-order = ["snippets", "scripts"]

        """
        let loaded = try TextConfiguration.decode(text, companion: companion)
        XCTAssertTrue(loaded.preferences.featureEnabled(.scratchpad))
        XCTAssertEqual(loaded.preferences.toolkit?.hiddenSidebarItems, ["usage"])
        XCTAssertEqual(loaded.preferences.toolkit?.sidebarOrder, ["scripts"])

        let rendered = try TextConfiguration.render(loaded, preserving: text)
        for gone in ["feature.snippets", "feature.shelf", "feature.quick-actions", "\"shelf\"", "\"snippets\""] {
            XCTAssertFalse(rendered.contains(gone), "\(gone) in\n\(rendered)")
        }
        XCTAssertTrue(rendered.contains("feature.scratchpad = true"), rendered)
        let reloaded = try TextConfiguration.decode(rendered, companion: TextConfiguration.companion(loaded))
        XCTAssertTrue(reloaded.preferences.featureEnabled(.scratchpad))

        // A key that never existed is still an error.
        XCTAssertThrowsError(try TextConfiguration.decode("feature.shelves = true\n", companion: companion))
    }
}
