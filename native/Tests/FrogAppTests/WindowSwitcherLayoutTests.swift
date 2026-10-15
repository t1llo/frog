import XCTest
@testable import FrogApp

final class WindowSwitcherLayoutTests: XCTestCase {
    func testTheSearchLineAddsItsHeightOnlyWhileVisible() {
        let plain = WindowSwitcherLayout.size(windowCount: 4)
        let searching = WindowSwitcherLayout.size(windowCount: 4, queryVisible: true)
        XCTAssertEqual(plain, WindowSwitcherLayout.size(windowCount: 4, queryVisible: false))
        XCTAssertEqual(searching.height - plain.height, WindowSwitcherLayout.queryLineHeight)
        XCTAssertEqual(searching.width, plain.width)
    }

    func testAlwaysRoomForOneRowAndNeverMoreThanTheVisibleRows() {
        XCTAssertEqual(WindowSwitcherLayout.size(windowCount: 0).height, WindowSwitcherLayout.size(windowCount: 1).height)
        XCTAssertEqual(WindowSwitcherLayout.size(windowCount: 0, queryVisible: true).height,
                       12 + WindowSwitcherLayout.rowHeight + WindowSwitcherLayout.queryLineHeight)
        XCTAssertEqual(WindowSwitcherLayout.size(windowCount: 50).height,
                       WindowSwitcherLayout.size(windowCount: WindowSwitcherLayout.visibleRows).height)
    }
}
