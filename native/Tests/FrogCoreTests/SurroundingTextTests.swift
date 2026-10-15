import XCTest
@testable import FrogCore

final class SurroundingTextTests: XCTestCase {
    func testEnclosingParagraphBetweenBlankLines() {
        let window = "Intro line.\n\nWe had a picnic on the river bank\nbefore the storm.\n  \nOutro."
        XCTAssertEqual(around("river bank", in: window), "We had a picnic on the river bank\nbefore the storm.")
    }

    func testLongParagraphFallsBackToItsLine() {
        let window = "First line of the paragraph is here.\nWe sat on the river bank today.\nLast line of the paragraph is here."
        XCTAssertEqual(around("river bank", in: window, limit: 50), "We sat on the river bank today.")
    }

    func testLongLineFallsBackToSentencesWithEllipses() {
        let window = "One two three. Four five six. Seven eight nine. Ten eleven twelve. Thirteen fourteen."
        XCTAssertEqual(around("eight", in: window, limit: 50), "One two three. Four five six. Seven eight nine.…")
        XCTAssertEqual(around("eleven", in: window, limit: 40), "…Seven eight nine. Ten eleven twelve.…")
        let long = Array(repeating: "Here is a sentence about nothing much.", count: 60).joined(separator: " ")
            + " The river bank is wide. " + Array(repeating: "Another sentence about nothing.", count: 60).joined(separator: " ")
        let result = around("river bank", in: long)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("The river bank is wide.") ?? false)
        XCTAssertTrue(result?.hasPrefix("…") ?? false)
        XCTAssertTrue(result?.hasSuffix("…") ?? false)
        XCTAssertLessThanOrEqual(result?.count ?? .max, 1_002)

        let sentence = String(repeating: "word ", count: 400) + "river bank " + String(repeating: "word ", count: 400) + "end."
        let clipped = around("river bank", in: sentence, limit: 100)
        XCTAssertTrue(clipped?.contains("river bank") ?? false)
        XCTAssertTrue(clipped?.hasPrefix("…") ?? false)
        XCTAssertTrue(clipped?.hasSuffix("…") ?? false)
        XCTAssertLessThanOrEqual(clipped?.count ?? .max, 102)
    }

    func testSelectionAtTheStartAndEndOfTheWindow() {
        XCTAssertEqual(around("river", in: "river bank is wide.\n\nNext paragraph."), "river bank is wide.")
        XCTAssertEqual(around("bank", in: "First.\n\nThe river bank"), "The river bank")
    }

    func testOffsetsAreUTF16() {
        XCTAssertEqual(around("bank", in: "👋🏽 你好世界。\n\nThe river 🌊 bank is wide."), "The river 🌊 bank is wide.")
        XCTAssertEqual(around("bank", in: "😀😀 漢字 river bank"), "😀😀 漢字 river bank")
    }

    func testNilCases() {
        XCTAssertNil(SurroundingText.around(selection: NSRange(location: 500, length: 3), in: "Short text."))
        XCTAssertNil(SurroundingText.around(selection: NSRange(location: 0, length: 0), in: ""))
        let thousand = String(repeating: "a", count: 1_000)
        XCTAssertNil(SurroundingText.around(selection: NSRange(location: 0, length: 1_000), in: thousand + " tail."))
        XCTAssertNil(around("river bank", in: "river bank"))
        XCTAssertNil(around("river bank", in: "\n river bank \n\nOther paragraph."))
    }

    private func around(_ selected: String, in window: String, limit: Int = 1_000) -> String? {
        let range = (window as NSString).range(of: selected)
        XCTAssertNotEqual(range.location, NSNotFound)
        return SurroundingText.around(selection: range, in: window, limit: limit)
    }
}
