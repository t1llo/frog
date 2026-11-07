import FrogCore
import SwiftUI
import XCTest
@testable import FrogApp

@MainActor
final class HistoryDiffTests: XCTestCase {
    func testAnAddedPeriodMarksThePeriodStronglyAndItsWordLightly() throws {
        let diff = try XCTUnwrap(HistoryDiff(original: "i saw it yesterday", result: "I saw it yesterday."))
        let letters = diff.result.runs.filter { $0.underlineStyle != nil }.map { String(diff.result[$0.range].characters) }
        XCTAssertEqual(letters, ["I", "."])
        let tinted = diff.result.runs.filter { $0.backgroundColor != nil }.map { String(diff.result[$0.range].characters) }
        XCTAssertEqual(tinted.joined(separator: "|"), "I|yesterday|.")
        XCTAssertEqual(diff.summary, "2 words changed")
    }

    func testMarksRemovedWordsInTheOriginalAndInsertedWordsInTheResult() throws {
        let diff = try XCTUnwrap(HistoryDiff(original: "the quick fox", result: "the slow fox"))
        XCTAssertEqual(String(diff.original.characters), "the quick fox")
        XCTAssertEqual(String(diff.result.characters), "the slow fox")
        let struck = diff.original.runs.filter { $0.strikethroughStyle != nil }.map { String(diff.original[$0.range].characters) }
        XCTAssertEqual(struck, ["quick"])
        let marked = diff.result.runs.filter { $0.backgroundColor != nil }.map { String(diff.result[$0.range].characters) }
        XCTAssertEqual(marked, ["slow"])
    }

    func testSummaryCountsChangedWordsThenWhatWasAddedOrRemoved() throws {
        XCTAssertEqual(try XCTUnwrap(HistoryDiff(original: "the quick fox", result: "the slow fox")).summary, "1 word changed")
        XCTAssertEqual(try XCTUnwrap(HistoryDiff(original: "a b", result: "c d e")).summary, "2 words changed · 1 added")
        XCTAssertEqual(try XCTUnwrap(HistoryDiff(original: "a b c", result: "a")).summary, "2 words removed")
    }

    func testNoDiffForEqualEmptyOrLongTexts() {
        XCTAssertNil(HistoryDiff(original: "same", result: "same"))
        XCTAssertNil(HistoryDiff(original: "", result: "text"))
        XCTAssertNil(HistoryDiff(original: String(repeating: "a", count: HistoryDiff.maxLength + 1), result: "b"))
    }

    func testMemoWorksOutTheDiffOncePerEntry() throws {
        let memo = HistoryDiffMemo()
        let entry = HistoryEntry(originalText: "a b", processedText: "a c", ruleName: "Proofread", providerName: "Local", model: "test")
        let first = try XCTUnwrap(memo.diff(for: entry))
        XCTAssertEqual(memo.diff(for: entry)?.result, first.result)
        let other = HistoryEntry(originalText: "x", processedText: "y", ruleName: "Proofread", providerName: "Local", model: "test")
        XCTAssertEqual(memo.diff(for: other).map { String($0.result.characters) }, "y")
    }
}
