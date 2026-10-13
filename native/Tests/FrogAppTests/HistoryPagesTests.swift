import XCTest
@testable import FrogApp

final class HistoryPagesTests: XCTestCase {
    func testLongTextIsShownInBoundedPagesThatLoseNothing() {
        let line = "A line of a long copied log with words and punctuation.\n"
        let text = String(repeating: line, count: 10_000)
        let first = HistoryPages.leading(text, count: 1)
        XCTAssertEqual(first.pages.count, 1)
        XCTAssertTrue(first.more, "Opening a long entry must not lay out all of it")
        XCTAssertLessThanOrEqual(first.pages[0].count, HistoryPages.length)
        XCTAssertGreaterThan(first.pages[0].count, HistoryPages.length - line.count)
        XCTAssertTrue(first.pages[0].hasSuffix("\n"), "A page ends at a line end when one is in reach")

        let two = HistoryPages.leading(text, count: 2)
        XCTAssertEqual(two.pages.count, 2)
        XCTAssertEqual(two.pages[0], first.pages[0], "Showing more keeps the pages already shown")
        XCTAssertTrue(two.more)

        let all = HistoryPages.leading(text, count: .max)
        XCTAssertFalse(all.more)
        XCTAssertEqual(all.pages.joined(), text, "Paging must not drop or repeat text")
        XCTAssertTrue(all.pages.allSatisfy { !$0.isEmpty && $0.count <= HistoryPages.length })

        // A line end near the start of a page is no reason for a page of a few characters.
        let uneven = "Heading\n" + String(repeating: "x", count: HistoryPages.length * 2)
        XCTAssertEqual(HistoryPages.leading(uneven, count: .max).pages.map(\.count), [HistoryPages.length, HistoryPages.length, 8])
    }

    func testOrdinaryTextStaysOnOnePage() {
        for text in ["", "Short text", String(repeating: "x", count: HistoryPages.length)] {
            let leading = HistoryPages.leading(text, count: 1)
            XCTAssertEqual(leading.pages.joined(), text)
            XCTAssertLessThanOrEqual(leading.pages.count, 1)
            XCTAssertFalse(leading.more)
        }
    }

    func testPageWithoutLineEndBreaksBetweenWordsAndNeverInsideACharacter() {
        let words = String(repeating: "transcribed words without any line end ", count: 1_500)
        let spoken = HistoryPages.leading(words, count: .max)
        XCTAssertEqual(spoken.pages.joined(), words)
        XCTAssertGreaterThan(spoken.pages.count, 1)
        XCTAssertTrue(spoken.pages.dropLast().allSatisfy { $0.hasSuffix(" ") }, "A long paragraph is cut between words")

        let family = "👨‍👩‍👧‍👦"
        let unbroken = String(repeating: family, count: HistoryPages.length + 10)
        let pages = HistoryPages.leading(unbroken, count: .max)
        XCTAssertEqual(pages.pages.map(\.count), [HistoryPages.length, 10])
        XCTAssertEqual(pages.pages.joined(), unbroken)
        XCTAssertTrue(pages.pages.allSatisfy { page in page.allSatisfy { String($0) == family } })
    }
}
