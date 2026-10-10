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

    func testTrailingRecordsLoseRelevanceTiesButKeepBetterMatches() {
        let feature = SearchRecord(id: "feature:stayAwake", title: "Stay awake", subtitle: "Frog")
        let app = SearchRecord(id: "app:stay", title: "Stay Focused")
        let files = (0..<120).map { SearchRecord(id: "file:\($0)", title: "Stay awake notes \($0).md") }
        let exact = SearchRecord(id: "file:exact", title: "Stay")
        // While typing, late file matches of the same quality follow the catalogue instead of burying it.
        XCTAssertEqual(CommandSearch.results([app, feature], query: "stay", trailing: files).prefix(3).map(\.id), ["app:stay", "feature:stayAwake", "file:0"])
        XCTAssertEqual(CommandSearch.results([app, feature], query: "stay awake", trailing: files).first?.id, "feature:stayAwake")
        // A better match still wins, and a recent choice still leads its bucket.
        XCTAssertEqual(CommandSearch.results([app, feature], query: "stay", trailing: files + [exact]).first?.id, "file:exact")
        XCTAssertEqual(CommandSearch.results([app, feature], query: "stay", preferred: [files[7]], trailing: files).prefix(2).map(\.id), ["file:7", "app:stay"])
        XCTAssertEqual(Set(CommandSearch.results([app, feature], query: "stay", preferred: [files[7]], trailing: files).map(\.id)).count, 80)
    }
}
