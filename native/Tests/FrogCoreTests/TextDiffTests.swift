import FrogCore
import XCTest

final class TextDiffTests: XCTestCase {
    private func marked(_ segments: [TextDiff.Segment]) -> [String] { segments.filter(\.changed).map(\.text) }
    private func text(_ segments: [TextDiff.Segment]) -> String { segments.map(\.text).joined() }

    func testTokensKeepWordsAndSpacesApart() {
        XCTAssertEqual(TextDiff.tokens("one  two\nthree"), ["one", "  ", "two", "\n", "three"])
        XCTAssertEqual(TextDiff.tokens(""), [])
    }

    func testAnAddedPeriodMarksOnlyThePeriod() {
        let diff = TextDiff(original: "see you yesterday", result: "see you yesterday.")
        XCTAssertEqual(marked(diff.original), [])
        XCTAssertEqual(marked(diff.result), ["."])
        XCTAssertEqual(diff.changedWords, 1)
        XCTAssertEqual(text(diff.result), "see you yesterday.")
    }

    func testCountMatchesTheMarkedWords() {
        let diff = TextDiff(original: "i think of it yesterday", result: "I think have it yesterday.")
        XCTAssertEqual(marked(diff.original), ["i", "of"])
        XCTAssertEqual(marked(diff.result), ["I", "have", "."])
        XCTAssertEqual(diff.changedWords, 3)
        XCTAssertEqual(diff.addedWords, 0)
        XCTAssertEqual(diff.removedWords, 0)
    }

    func testDifferentWordsAreMarkedWhole() {
        let diff = TextDiff(original: "the quick fox", result: "the slow fox")
        XCTAssertEqual(marked(diff.original), ["quick"])
        XCTAssertEqual(marked(diff.result), ["slow"])
        XCTAssertEqual(diff.changedWords, 1)
    }

    func testSimilarWordsAreMarkedLetterByLetter() {
        let diff = TextDiff(original: "recieve it", result: "receive it")
        XCTAssertFalse(marked(diff.original).isEmpty)
        XCTAssertTrue(marked(diff.result).allSatisfy { $0.count == 1 })
        XCTAssertEqual(diff.changedWords, 1)
    }

    func testExtraWordsCountAsAddedOrRemoved() {
        let added = TextDiff(original: "a b", result: "c d e")
        XCTAssertEqual([added.changedWords, added.addedWords, added.removedWords], [2, 1, 0])
        let removed = TextDiff(original: "a b c", result: "a")
        XCTAssertEqual([removed.changedWords, removed.addedWords, removed.removedWords], [0, 0, 2])
        XCTAssertEqual(marked(removed.original), ["b", "c"])
    }

    func testSpacesAreNeverMarked() {
        let diff = TextDiff(original: "one two", result: "one  two")
        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(marked(diff.original) + marked(diff.result), [])
        XCTAssertEqual(text(diff.result), "one  two")
    }
}
