import Darwin
import XCTest
@testable import FrogCore

/// fzf-style scoring and frecency in the command bar's ranking.
final class FuzzyRankingTests: XCTestCase {
    private func score(_ pattern: String, _ text: String) -> Int32? {
        FuzzyMatch.score(FuzzyMatch.scalars(CommandSearch.searchKey(pattern)), in: FuzzyMatch.Text(folded: CommandSearch.searchKey(text), original: text))
    }

    func testLettersMustAppearInOrder() {
        XCTAssertNotNil(score("sfr", "Safari"))
        XCTAssertNil(score("rfs", "Safari"))
        XCTAssertNil(score("safarix", "Safari"))
        XCTAssertEqual(score("", "Safari"), 0)
    }

    func testWordStartsCamelCaseAndRunsScoreHigher() throws {
        // The initials of words beat the same letters inside them.
        XCTAssertGreaterThan(try XCTUnwrap(score("vsc", "Visual Studio Code")), try XCTUnwrap(score("vsc", "Advisory scan")))
        // A run beats the same letters spread out.
        XCTAssertGreaterThan(try XCTUnwrap(score("term", "Terminal")), try XCTUnwrap(score("term", "The rem")))
        // camelCase and digits are boundaries.
        XCTAssertGreaterThan(try XCTUnwrap(score("ss", "ScreenSaver")), try XCTUnwrap(score("ss", "Grasshopper")))
        // The start of the title wins a tie between word starts.
        let rows = [SearchRecord(id: "sticky", title: "Sticky Notes"), SearchRecord(id: "notes", title: "Notes")]
        XCTAssertEqual(CommandSearch.results(rows, query: "note").map(\.id), ["notes", "sticky"])
    }

    func testFuzzyTitlesRankBelowPrefixesAndScatteredNoiseIsDropped() {
        let safari = SearchRecord(id: "app:safari", title: "Safari", subtitle: "App", prominent: true)
        let fileSafari = SearchRecord(id: "file:safari", title: "Safari bookmarks.html")
        let studio = SearchRecord(id: "app:code", title: "Visual Studio Code", subtitle: "App", prominent: true)
        // Letters deep inside words, far apart, are noise.
        let noise = SearchRecord(id: "note:noise", title: "Pressed tangerine leaf")
        XCTAssertEqual(CommandSearch.results([noise, fileSafari, safari], query: "saf").map(\.id), ["app:safari", "file:safari"])
        // A good scattered match is listed, but an app with the same letters at word starts leads it.
        let close = SearchRecord(id: "note:close", title: "A very scattered note")
        XCTAssertEqual(CommandSearch.results([close, studio], query: "vsc").map(\.id), ["app:code", "note:close"])
        XCTAssertTrue(CommandSearch.results([noise], query: "vscd").isEmpty)
        // Every word must match, each its own way.
        XCTAssertEqual(CommandSearch.results([studio, safari], query: "vis code").map(\.id), ["app:code"])
    }

    func testFrecencyMovesAnEquallyGoodRowUpButNotPastABetterTierAndAWeekHalvesIt() {
        let calculator = SearchRecord(id: "app:calc", title: "Calculator", prominent: true)
        let calendar = SearchRecord(id: "app:cal", title: "Calendar", prominent: true)
        let exact = SearchRecord(id: "app:ca", title: "Ca", prominent: true)
        XCTAssertEqual(CommandSearch.results([calculator, calendar], query: "ca").map(\.id), ["app:calc", "app:cal"])
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000), day: TimeInterval = 86_400
        var choices = CommandChoices()
        choices.record(typed: "ca", id: "app:cal", now: start)
        let boosts = choices.index(now: start).frecency(for: "ca")
        XCTAssertEqual(boosts["app:cal"] ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(CommandSearch.results([calculator, calendar], query: "ca", boosts: boosts).map(\.id), ["app:cal", "app:calc"])
        // An exact title is a tier and more ahead; a pick does not pass it.
        XCTAssertEqual(CommandSearch.results([calculator, calendar, exact], query: "ca", boosts: boosts).first?.id, "app:ca")
        // Recent beats frequent: four picks three weeks ago weigh half of one today.
        var old = CommandChoices()
        for _ in 0..<4 { old.record(typed: "x", id: "app:calc", now: start) }
        old.record(typed: "x", id: "app:cal", now: start.addingTimeInterval(21 * day))
        let later = old.index(now: start.addingTimeInterval(21 * day)).frecency(for: "")
        XCTAssertEqual(later["app:calc"] ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(later["app:cal"] ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(CommandSearch.results([calculator, calendar], query: "ca", boosts: later).first?.id, "app:cal")
    }

    func testTypicalQueryOverALargeCatalogueIsFast() {
        let words = ["Project", "Budget", "Notes", "Safari", "Calendar", "Terminal", "Settings", "Display", "Sound", "Studio"]
        let records = (0..<3_000).map { index in
            SearchRecord(id: "row:\(index)", title: "\(words[index % 10]) \(words[(index / 10) % 10]) \(index)",
                         keywords: "fixture keyword \(index)", prominent: index % 7 == 0)
        }
        // CPU time of this thread, so other processes on a busy Mac do not count against the search.
        func cpuTime(_ work: () -> Void) -> Duration {
            let before = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            work()
            return .nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - before))
        }
        var slowest = Duration.zero
        for query in ["s", "sa", "saf", "safa", "safari", "proj bud", "cal term"] {
            slowest = max(slowest, cpuTime { _ = CommandSearch.results(records, query: query) })
        }
        print("CommandSearch: slowest keystroke over 3000 rows took \(slowest)")
        // A frame at 60 Hz, in a debug build.
        XCTAssertLessThan(slowest, .milliseconds(50))
    }
}
