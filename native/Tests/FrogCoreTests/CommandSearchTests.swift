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

    func testOneLatchedRecordLeadsEverythingAndEveryOtherRowKeepsItsPlace() {
        let exactApp = SearchRecord(id: "app:Budget", title: "Budget", prominent: true)
        let appPrefix = SearchRecord(id: "app:BudgetPro", title: "Budget Pro", prominent: true)
        let note = SearchRecord(id: "note:budget", title: "Budget")
        let family = SearchRecord(id: "note:family", title: "Family budget")
        let groceries = SearchRecord(id: "note:groceries", title: "Groceries", keywords: "budget")
        let file = SearchRecord(id: "file:budget", title: "Budget 2026.xlsx")
        let records = [groceries, family, note, appPrefix, exactApp]
        let today = CommandSearch.results(records, query: "budget", trailing: [file])
        XCTAssertEqual(today.map(\.id), ["app:Budget", "app:BudgetPro", "note:budget", "file:budget", "note:family", "note:groceries"])
        // The latched file passes the exact application, which comes second; nothing else moves.
        for preferred in [[], [file], [family, file]] {
            let learned = CommandSearch.results(records, query: "budget", preferred: preferred, trailing: [file], latched: "file:budget")
            let unlatched = CommandSearch.results(records, query: "budget", preferred: preferred, trailing: [file])
            XCTAssertEqual(learned.map(\.id), ["file:budget"] + unlatched.map(\.id).filter { $0 != "file:budget" })
            XCTAssertEqual(learned.dropFirst().first?.id, "app:Budget")
        }
        // A latched row the typed text does not find is not listed, and the empty query ignores it.
        let calendar = SearchRecord(id: "app:Calendar", title: "Calendar", prominent: true)
        XCTAssertEqual(CommandSearch.results(records + [calendar], query: "budget", trailing: [file], latched: "app:Calendar"), today)
        XCTAssertEqual(CommandSearch.results(records, query: "budget", trailing: [file], latched: "missing"), today)
        XCTAssertEqual(CommandSearch.results(records, query: "", latched: "note:budget"), CommandSearch.results(records, query: ""))
    }

    func testTheKindEveryApplicationSharesDoesNotListThemAllButOpenAndLaunchStillFindOne() {
        let apps = (0..<100).map { SearchRecord(id: "app:\($0)", title: "Fixture Tool \($0)", subtitle: "App", keywords: "FixtureWidget\($0)", prominent: true) }
        let note = SearchRecord(id: "note", title: "Groceries", subtitle: "Notes", keywords: "happy hour supplies")
        // A fragment of the word every application row shows must not put each one ahead of a real match.
        for query in ["pp", "ap", "app"] {
            XCTAssertFalse(CommandSearch.results(apps + [note], query: query).contains { $0.id.hasPrefix("app:") }, query)
        }
        XCTAssertEqual(CommandSearch.results(apps + [note], query: "pp").map(\.id), ["note"])
        // Asking to open or launch an application still finds it by its name, and its bundle name still finds it.
        for query in ["open fixture tool 7", "launch fixture tool 7", "fixture tool 7 app", "fixturewidget7"] {
            XCTAssertEqual(CommandSearch.results(apps + [note], query: query).first?.id, "app:7", query)
        }
        // Other records still need every word.
        XCTAssertTrue(CommandSearch.results([note], query: "open groceries").isEmpty)
    }

    func testTextShapedLikeADateIsNotACalculation() {
        // A file named after a date is what such text looks for. An answer above it would take Return.
        for text in ["2025-01-15", "2025-1-5", "15/01/2025", "1/5/2025", "2025-01", "09-17", " 2025-01-15 "] {
            XCTAssertNil(QuickCalculation.result(text), text)
        }
        // Spaces, or groups no date has, still ask for arithmetic.
        for (text, answer) in [("2025 - 1 - 15", "2009"), ("2000-500-300", "1200"), ("100-20", "80"), ("12/25/25", "0.0192"),
                               ("0.5*4", "2"), ("1.05+1", "2.05"), ("10-0", "10"), ("25% * 200", "50"), ("(3+4)*6", "42")] {
            XCTAssertEqual(QuickCalculation.result(text), answer, text)
        }
    }
}
