import XCTest
import CoreGraphics
@testable import FrogCore

final class SelectionContextTests: XCTestCase {
    func testAnchorKeepsTheSelectionUnlessItIsTallerThanHalfTheScreen() {
        let union = CGRect(x: 100, y: 400, width: 300, height: 40)
        let last = CGRect(x: 380, y: 400, width: 8, height: 18)
        XCTAssertEqual(SelectionAnchor.choose(union: union, last: last, screenHeight: 900), union)
        XCTAssertEqual(SelectionAnchor.choose(union: CGRect(x: 0, y: 0, width: 300, height: 450), last: last, screenHeight: 900),
                       CGRect(x: 0, y: 0, width: 300, height: 450), "Exactly half is kept")
        let tall = CGRect(x: 100, y: 0, width: 600, height: 451)
        XCTAssertEqual(SelectionAnchor.choose(union: tall, last: last, screenHeight: 900), last)
        XCTAssertEqual(SelectionAnchor.choose(union: nil, last: last, screenHeight: 900), last)
        XCTAssertNil(SelectionAnchor.choose(union: nil, last: nil, screenHeight: 900))
        XCTAssertNil(SelectionAnchor.choose(union: tall, last: nil, screenHeight: 900))
    }

    func testTheBubbleOpensAtTheEndBesideEveryLine() {
        let last = CGRect(x: 380, y: 400, width: 8, height: 18)
        XCTAssertEqual(SelectionAnchor.end(last, selection: CGRect(x: 100, y: 400, width: 300, height: 90)),
                       CGRect(x: 388, y: 400, width: 0, height: 90))
        XCTAssertEqual(SelectionAnchor.end(last, selection: last), CGRect(x: 388, y: 400, width: 0, height: 18),
                       "A selection taller than half its screen keeps only its last character")
        XCTAssertEqual(SelectionAnchor.end(last, selection: nil), CGRect(x: 388, y: 400, width: 0, height: 18))
        XCTAssertEqual(SelectionAnchor.end(last, selection: CGRect(x: 100, y: 410, width: 300, height: 60)),
                       CGRect(x: 388, y: 400, width: 0, height: 70), "A last character below the reported rectangle still counts")
        XCTAssertNil(SelectionAnchor.end(nil, selection: CGRect(x: 100, y: 400, width: 300, height: 90)))
    }

    func testAnchorReadsTheLastCharacterOnlyWhenNeeded() {
        var reads = 0
        func last() -> CGRect? { reads += 1; return .zero }
        _ = SelectionAnchor.choose(union: CGRect(x: 0, y: 0, width: 10, height: 10), last: last(), screenHeight: 900)
        XCTAssertEqual(reads, 0)
        _ = SelectionAnchor.choose(union: nil, last: last(), screenHeight: 900)
        XCTAssertEqual(reads, 1)
    }

    func testContextWindowIsClampedToTheText() {
        func window(_ location: Int, _ length: Int, count: Int, margin: Int = 1_500) -> [Int] {
            let range = ContextWindow.range(selection: (location, length), count: count, margin: margin)
            return [range.location, range.length]
        }
        XCTAssertEqual(window(5_000, 10, count: 20_000), [3_500, 3_010], "Middle")
        XCTAssertEqual(window(100, 10, count: 20_000), [0, 1_610], "Near the start")
        XCTAssertEqual(window(19_990, 5, count: 20_000), [18_490, 1_510], "Near the end")
        XCTAssertEqual(window(10, 500, count: 100), [0, 100], "Selection longer than the text")
        XCTAssertEqual(window(200, 5, count: 100), [0, 100], "Selection past the end")
        XCTAssertEqual(window(5, 3, count: 10, margin: 0), [5, 3], "No margin")
        XCTAssertEqual(window(0, 0, count: 0), [0, 0], "Empty text")
    }

    func testSourceAddressDropsCredentialsQueryAndFragment() {
        XCTAssertEqual(SourceAddress.clean(URL(string: "https://user:pw@example.com/a?token=1#x")!), "https://example.com/a")
        XCTAssertEqual(SourceAddress.clean(URL(string: "http://example.com:8080/docs/")!), "http://example.com:8080/docs/")
        XCTAssertEqual(SourceAddress.clean(URL(string: "file:///Users/x/a.md")!), "file:///Users/x/a.md")
        XCTAssertEqual(SourceAddress.clean(URL(fileURLWithPath: "/tmp/notes with space.txt")),
                       "file:///tmp/notes%20with%20space.txt")
        for address in ["mailto:someone@example.com", "javascript:alert(1)", "data:text/plain,hello", "https:///a", "about:blank"] {
            XCTAssertNil(SourceAddress.clean(URL(string: address)!), address)
        }
    }
}
