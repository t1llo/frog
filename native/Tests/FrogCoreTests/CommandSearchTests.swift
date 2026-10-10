import XCTest
@testable import FrogCore

final class CommandSearchTests: XCTestCase {
    func testRecentChoicesOnlyBreakRelevanceTiesAndNeverDuplicateResults() {
        let app = SearchRecord(id: "app", title: "Project", keywords: "open app")
        let file = SearchRecord(id: "file", title: "Project plan.txt")
        let other = SearchRecord(id: "other", title: "Archive", keywords: "project")
        XCTAssertEqual(CommandSearch.results([app, file, other], query: "Project", preferred: [file, file, other]).map(\.id), ["app", "file", "other"])
        XCTAssertEqual(CommandSearch.results([app, file, other], query: "", limit: 2, preferred: [file]).map(\.id), ["file", "app"])
        XCTAssertEqual(CommandSearch.results([app, file], query: "Project plan", preferred: [other]).map(\.id), ["file"])
    }

    func testExactFileStillWinsAgainstLargeAppCatalogueAndRecentSuggestions() {
        let apps = (0..<2000).map { SearchRecord(id: "app:\($0)", title: "Project tool \($0)") }
        let file = SearchRecord(id: "file", title: "Project")
        let results = CommandSearch.results(apps, query: "project", limit: 80, preferred: [apps[1999], file])
        XCTAssertEqual(results.first?.id, "file")
        XCTAssertEqual(results.dropFirst().first?.id, "app:1999")
        XCTAssertEqual(results.count, 80)
        XCTAssertEqual(Set(results.map(\.id)).count, 80)
    }
}
