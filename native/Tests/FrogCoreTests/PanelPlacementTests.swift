import XCTest
import CoreGraphics
@testable import FrogCore

final class PanelPlacementTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let size = CGSize(width: 400, height: 200)

    func testBelowTheAnchorWhenItFits() {
        let anchor = CGRect(x: 300, y: 500, width: 120, height: 18)
        let result = PanelPlacement.place(size: size, anchor: anchor, pointer: .zero, screens: [main])
        XCTAssertEqual(result.frame, CGRect(x: 300, y: 500 - 8 - 200, width: 400, height: 200))
        XCTAssertFalse(result.above)
        XCTAssertEqual(result.screen, main)
    }

    func testAboveTheAnchorWhenBelowDoesNotFit() {
        let anchor = CGRect(x: 300, y: 100, width: 120, height: 18)
        let result = PanelPlacement.place(size: size, anchor: anchor, pointer: .zero, screens: [main])
        XCTAssertEqual(result.frame, CGRect(x: 300, y: 118 + 8, width: 400, height: 200))
        XCTAssertTrue(result.above)
    }

    func testTheSideWithMoreRoomClampedWhenNeitherFits() {
        let short = CGRect(x: 0, y: 0, width: 1440, height: 300)
        // 176 pt under the anchor, 108 over it: below wins and is pushed up to the margin.
        let low = PanelPlacement.place(size: size, anchor: CGRect(x: 100, y: 176, width: 50, height: 16), pointer: .zero, screens: [short])
        XCTAssertFalse(low.above)
        XCTAssertEqual(low.frame.minY, 8)
        // 90 pt under the anchor, 194 over it: above wins and is pushed down to the margin.
        let high = PanelPlacement.place(size: size, anchor: CGRect(x: 100, y: 90, width: 50, height: 16), pointer: .zero, screens: [short])
        XCTAssertTrue(high.above)
        XCTAssertEqual(high.frame.maxY, 292)
    }

    func testHorizontalPositionIsClampedAtBothEdges() {
        let right = PanelPlacement.place(size: size, anchor: CGRect(x: 1300, y: 500, width: 80, height: 18), pointer: .zero, screens: [main])
        XCTAssertEqual(right.frame.maxX, 1432)
        let left = PanelPlacement.place(size: size, anchor: CGRect(x: -40, y: 500, width: 80, height: 18), pointer: .zero, screens: [main])
        XCTAssertEqual(left.frame.minX, 8)
    }

    func testAnchorOnASecondDisplayLeftOfThePrimary() {
        let second = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let anchor = CGRect(x: -1000, y: 800, width: 100, height: 18)
        let result = PanelPlacement.place(size: size, anchor: anchor, pointer: CGPoint(x: 700, y: 400), screens: [main, second])
        XCTAssertEqual(result.screen, second)
        XCTAssertEqual(result.frame, CGRect(x: -1000, y: 592, width: 400, height: 200))
    }

    func testAnchorBetweenDisplaysUsesTheNearest() {
        let second = CGRect(x: 1600, y: 0, width: 1920, height: 1080)
        // In the 160 pt gap, 40 pt from the second display and 120 from the primary.
        let anchor = CGRect(x: 1550, y: 600, width: 20, height: 18)
        let result = PanelPlacement.place(size: size, anchor: anchor, pointer: CGPoint(x: 10, y: 10), screens: [main, second])
        XCTAssertEqual(result.screen, second)
        XCTAssertEqual(result.frame.minX, 1608)
    }

    func testWithoutAnAnchorThePanelOpensAtThePointer() {
        let result = PanelPlacement.place(size: size, anchor: nil, pointer: CGPoint(x: 500, y: 600), screens: [main])
        XCTAssertEqual(result.frame, CGRect(x: 512, y: 600 - 12 - 8 - 200, width: 400, height: 200))
        XCTAssertFalse(result.above)
    }

    func testResizingKeepsTheEdgeNextToTheAnchorAndClamps() {
        let below = PanelPlacement.place(size: size, anchor: CGRect(x: 300, y: 500, width: 120, height: 18), pointer: .zero, screens: [main])
        let taller = PanelPlacement.resized(below, height: 300)
        XCTAssertEqual(taller.frame.maxY, below.frame.maxY)
        XCTAssertEqual(taller.frame.height, 300)
        let above = PanelPlacement.place(size: size, anchor: CGRect(x: 300, y: 100, width: 120, height: 18), pointer: .zero, screens: [main])
        let shorter = PanelPlacement.resized(above, height: 120)
        XCTAssertEqual(shorter.frame.minY, above.frame.minY)
        XCTAssertTrue(shorter.above)
        // Growing past the bottom of the display is clamped to the margin.
        XCTAssertEqual(PanelPlacement.resized(below, height: 600).frame.minY, 8)
        // Growing past the top is clamped there too.
        XCTAssertEqual(PanelPlacement.resized(above, height: 800).frame.maxY, 867)
    }
}
