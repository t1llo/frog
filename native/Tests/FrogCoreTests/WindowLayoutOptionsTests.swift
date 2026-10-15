import XCTest
@testable import FrogCore

final class WindowLayoutOptionsTests: XCTestCase {
    /// A 1440×900 display with a 25 pt menu bar.
    private let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)

    func testLegacyOptionsChangeNothing() {
        let options = WindowLayoutOptions.legacy
        for frame in [visible, CGRect(x: -1511, y: -217, width: 1511, height: 983), CGRect(x: 0.5, y: 3, width: 853.33, height: 10)] {
            XCTAssertEqual(options.usableArea(frame), frame)
            XCTAssertEqual(options.spaced(CGRect(x: frame.minX + 3, y: frame.minY, width: frame.width / 3, height: 9), in: frame),
                           CGRect(x: frame.minX + 3, y: frame.minY, width: frame.width / 3, height: 9))
        }
        XCTAssertEqual(WindowLayoutOptions(), .legacy)
    }

    func testGapLeavesEqualSpaceAtEdgesAndBetweenTiles() {
        let options = WindowLayoutOptions(gap: 10)
        let area = options.usableArea(visible)
        XCTAssertEqual(area, CGRect(x: 10, y: 35, width: 1420, height: 855))
        let halfWidth = area.width / 2, halfHeight = area.height / 2

        let left = options.spaced(CGRect(x: area.minX, y: area.minY, width: halfWidth, height: area.height), in: area)
        let right = options.spaced(CGRect(x: area.midX, y: area.minY, width: halfWidth, height: area.height), in: area)
        XCTAssertEqual(left, CGRect(x: 10, y: 35, width: 705, height: 855))
        XCTAssertEqual(right, CGRect(x: 725, y: 35, width: 705, height: 855))
        XCTAssertEqual(left.minX - visible.minX, 10)
        XCTAssertEqual(right.minX - left.maxX, 10)
        XCTAssertEqual(visible.maxX - right.maxX, 10)
        XCTAssertEqual(left.minY - visible.minY, 10)
        XCTAssertEqual(visible.maxY - left.maxY, 10)

        let quarters = [(area.minX, area.minY), (area.midX, area.minY), (area.minX, area.midY), (area.midX, area.midY)].map {
            options.spaced(CGRect(x: $0.0, y: $0.1, width: halfWidth, height: halfHeight), in: area)
        }
        let (topLeft, topRight, bottomLeft, bottomRight) = (quarters[0], quarters[1], quarters[2], quarters[3])
        XCTAssertEqual(topLeft, CGRect(x: 10, y: 35, width: 705, height: 422.5))
        XCTAssertEqual(topRight.minX - topLeft.maxX, 10)
        XCTAssertEqual(bottomLeft.minY - topLeft.maxY, 10)
        XCTAssertEqual(bottomRight.minX - bottomLeft.maxX, 10)
        XCTAssertEqual(bottomRight.minY - topRight.maxY, 10)
        XCTAssertEqual(visible.maxX - bottomRight.maxX, 10)
        XCTAssertEqual(visible.maxY - bottomRight.maxY, 10)
        XCTAssertEqual(topLeft.size, bottomRight.size)

        // A tile that fills the area keeps every edge.
        XCTAssertEqual(options.spaced(area, in: area), area)
    }

    func testStageManagerInsetComesBeforeTheGap() {
        let options = WindowLayoutOptions(gap: 10, leadingInset: WindowLayoutOptions.stageManagerInset)
        XCTAssertEqual(options.usableArea(visible), CGRect(x: 200, y: 35, width: 1230, height: 855))
        XCTAssertEqual(WindowLayoutOptions(leadingInset: 190).usableArea(visible), CGRect(x: 190, y: 25, width: 1250, height: 875))
        // A display narrower than the strip still keeps half of its width.
        XCTAssertEqual(WindowLayoutOptions(leadingInset: 190).usableArea(CGRect(x: 0, y: 0, width: 300, height: 200)),
                       CGRect(x: 150, y: 0, width: 150, height: 200))
    }

    func testCycleOrderIsHalfTwoThirdsThird() {
        XCTAssertEqual(WindowSizeCycle.fractions, [0.5, 2.0 / 3.0, 1.0 / 3.0])
        XCTAssertEqual(WindowSizeCycle.next(after: 0), 1)
        XCTAssertEqual(WindowSizeCycle.next(after: 1), 2)
        XCTAssertEqual(WindowSizeCycle.next(after: 2), 0)
        XCTAssertEqual(WindowAction.allCases.filter(WindowSizeCycle.cycles), [.leftHalf, .rightHalf, .topHalf, .bottomHalf])
    }
}
