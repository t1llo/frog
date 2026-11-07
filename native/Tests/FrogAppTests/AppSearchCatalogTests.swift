import XCTest
import FrogCore
@testable import FrogApp

final class AppSearchCatalogTests: XCTestCase {
    /// Every section and row the search lists must still be drawn by a page, or opening it lands nowhere.
    func testEveryTitleIsStillOnAPage() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../FrogApp").standardizedFileURL
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "AppSearch.swift" }
        let text = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        for entry in AppSearchCatalog.entries {
            if let section = entry.section {
                XCTAssertTrue(text.contains("FrogSection(\"\(section)\""), "No page has a section named \(section)")
            }
            if let row = entry.row {
                XCTAssertTrue(text.contains("\"\(row)\""), "No page has a row named \(row)")
            }
        }
    }

    func testEntriesAreListedOnce() {
        XCTAssertEqual(Set(AppSearchCatalog.entries).count, AppSearchCatalog.entries.count)
    }

    func testFindsASettingDeepInAPage() {
        let results = AppSearchCatalog.search("login", translate: { $0 })
        XCTAssertEqual(results.first, AppSearchEntry(page: .settings, section: "General", row: "Start at login",
                                                     keywords: ["launch", "startup", "login items", "autostart"]))
    }

    func testTitleMatchesComeBeforeKeywordMatches() {
        let results = AppSearchCatalog.search("gap", translate: { $0 })
        XCTAssertEqual(results.first?.row, "Gap between windows")
        let dark = AppSearchCatalog.search("dark mode", translate: { $0 })
        XCTAssertEqual(dark.first?.section, "Appearance")
        XCTAssertNil(dark.first?.row)
    }

    func testAWordInsideATitleRanksAboveAMatchMidWord() {
        let results = AppSearchCatalog.search("menu", translate: { $0 })
        XCTAssertEqual(results.first?.title, "Menu bar", "A title starting with the query leads")
        XCTAssertTrue(results.contains { $0.title == "Show in the menu bar" })
    }

    func testEmptyQueryFindsNothing() {
        XCTAssertTrue(AppSearchCatalog.search("   ").isEmpty)
    }

    func testFocusMatchesOnlyItsOwnSection() {
        let focus = FrogSearchFocus(route: .settings, section: "Permissions", row: "Microphone")
        XCTAssertTrue(focus.matchesRow("Microphone", in: "Permissions"))
        XCTAssertFalse(focus.matchesRow("Microphone", in: "Recording"))
        XCTAssertFalse(focus.matchesSection("Permissions"), "A row result flashes the row, not its whole section")
        XCTAssertTrue(FrogSearchFocus(route: .settings, section: "Permissions", row: nil).matchesSection("Permissions"))
    }
}
