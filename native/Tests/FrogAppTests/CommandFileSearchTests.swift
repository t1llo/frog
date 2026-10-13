import FrogCore
import XCTest
@testable import FrogApp

/// What the command bar asks Spotlight for and how much of the answer it takes, decided without a panel.
@MainActor final class CommandFileSearchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func item(_ name: String, _ types: [String] = ["public.content"], daysAgo: Double = 0) -> [String: Any] {
        ["kMDItemFSName": name, "kMDItemContentTypeTree": types, "kMDItemLastUsedDate": now.addingTimeInterval(-daysAgo * 86400)]
    }

    func testNamesThatBeginWithTheTextAreAskedForByThemselvesAndTwoLettersNowhereElse() {
        // Only the first rows of an answer are read, in no useful order. A name that begins with the text must not
        // depend on being among them when thousands of names merely contain it.
        let typed = MetadataCommandFileSearch.predicates(text: "rep", now: now)
        XCTAssertEqual(typed.count, 2)
        XCTAssertTrue(typed[0].evaluate(with: item("Report.txt")))
        XCTAssertTrue(typed[0].evaluate(with: item("Répertoire", ["public.folder"])))
        XCTAssertFalse(typed[0].evaluate(with: item("Old report.txt")))
        XCTAssertFalse(typed[0].evaluate(with: item("Reporter.app", ["public.folder", "com.apple.application-bundle"])))
        XCTAssertTrue(typed[1].evaluate(with: item("Old report.txt")))
        XCTAssertTrue(typed[1].evaluate(with: item("Report.txt")))

        // Two letters are part of a great share of all names on a disk.
        let short = MetadataCommandFileSearch.predicates(text: "re", now: now)
        XCTAssertEqual(short.count, 1)
        XCTAssertTrue(short[0].evaluate(with: item("Report.txt")))
        XCTAssertFalse(short[0].evaluate(with: item("More.txt")))
        // Two characters of a script that writes whole words with them are not.
        let word = MetadataCommandFileSearch.predicates(text: "日本", now: now)
        XCTAssertEqual(word.count, 2)
        XCTAssertFalse(word[0].evaluate(with: item("東日本.txt")))
        XCTAssertTrue(word[1].evaluate(with: item("東日本.txt")))

        // Several words begin a name as they were typed, and are found in any order otherwise.
        let words = MetadataCommandFileSearch.predicates(text: " old rep ", now: now)
        XCTAssertEqual(words.count, 2)
        XCTAssertTrue(words[0].evaluate(with: item("Old report.txt")))
        XCTAssertFalse(words[0].evaluate(with: item("Report old.txt")))
        XCTAssertTrue(words[1].evaluate(with: item("Report old.txt")))

        // Before anything is typed the recent files are asked for, as before.
        let recent = MetadataCommandFileSearch.predicates(text: "", now: now)
        XCTAssertEqual(recent.count, 1)
        XCTAssertTrue(recent[0].evaluate(with: item("Anything.txt")))
        XCTAssertFalse(recent[0].evaluate(with: item("Old.txt", daysAgo: 8)))
    }

    func testGatheringEndsOnceFarMoreIsFoundThanIsEverListed() {
        XCTAssertFalse(MetadataCommandFileSearch.stopsGathering(at: 200, text: "rep"))
        XCTAssertFalse(MetadataCommandFileSearch.stopsGathering(at: MetadataCommandFileSearch.gatherLimit - 1, text: "rep"))
        XCTAssertTrue(MetadataCommandFileSearch.stopsGathering(at: MetadataCommandFileSearch.gatherLimit, text: "rep"))
        XCTAssertTrue(MetadataCommandFileSearch.stopsGathering(at: 96_000, text: "re"))
        // The recent files are few and come sorted by use, so the newest must not be cut off.
        XCTAssertFalse(MetadataCommandFileSearch.stopsGathering(at: 96_000, text: ""))
    }

    func testRowsOfEveryQueryAreListedOnceWithTheLeadingQueryFirst() {
        let files = (0..<5).map { SearchRecord(id: "file:/fixture/Report \($0).txt", title: "Report \($0).txt") }
        XCTAssertEqual(MetadataCommandFileSearch.merged([[files[3], files[1]], [files[0], files[1], files[2], files[3], files[4]]]).map(\.id),
                       [3, 1, 0, 2, 4].map { files[$0].id })
        XCTAssertEqual(MetadataCommandFileSearch.merged([[], [files[2], files[0]]]), [files[2], files[0]])
        XCTAssertEqual(MetadataCommandFileSearch.merged([]), [])
    }

    func testSpotlightAcceptsEveryQueryOfEveryTypedShape() {
        // NSMetadataQuery raises on predicates it cannot translate, and nothing in the bar catches that.
        let scope = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for text in ["", "ac", "ac ", "abc", "project CAFE", "it's", "a\"b", "100%", "*", "a*b?", "\\", "a(b)", "🐸", "日本", String(repeating: "long ", count: 40)] {
            for predicate in MetadataCommandFileSearch.predicates(text: text) {
                let query = NSMetadataQuery()
                query.predicate = predicate
                XCTAssertNotNil(query.predicate, text)
            }
            // A search that could not start says so at once, with no rows.
            let search = MetadataCommandFileSearch()
            var refused = false
            search.start(text: text.trimmingCharacters(in: .whitespacesAndNewlines), scopes: [scope]) { _ in refused = true }
            search.stop()
            XCTAssertFalse(refused, text)
        }
    }
}
