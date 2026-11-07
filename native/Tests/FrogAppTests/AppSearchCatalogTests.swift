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
        // Collected once: searching the joined sources once per entry took half a minute.
        var literals = Set<String>(), sections = Set<String>()
        let literal = try NSRegularExpression(pattern: #""((?:[^"\\\n]|\\.)*)""#)
        let section = try NSRegularExpression(pattern: #"FrogSection\("((?:[^"\\\n]|\\.)*)""#)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8) as NSString
            let range = NSRange(location: 0, length: text.length)
            for match in literal.matches(in: text as String, range: range) { literals.insert(text.substring(with: match.range(at: 1))) }
            for match in section.matches(in: text as String, range: range) { sections.insert(text.substring(with: match.range(at: 1))) }
        }
        for entry in AppSearchCatalog.entries {
            if let name = entry.section {
                XCTAssertTrue(sections.contains(name), "No page has a section named \(name)")
            }
            if let row = entry.row {
                XCTAssertTrue(literals.contains(row), "No page has a row named \(row)")
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
