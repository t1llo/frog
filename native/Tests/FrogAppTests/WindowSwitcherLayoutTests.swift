import XCTest
@testable import FrogApp
import FrogCore

final class WindowSwitcherLayoutTests: XCTestCase {
    func testTheSwitcherIsInThePanelFamilysFrame() {
        XCTAssertEqual(WindowSwitcherLayout.size(windowCount: 4).width, PanelFamilyPlacement.width)
        XCTAssertEqual(WindowSwitcherLayout.size(windowCount: 4).height,
                       FloatingPanelLayout.chromeHeight + 4 * WindowSwitcherLayout.rowHeight, "The search line is always there")
        XCTAssertLessThanOrEqual(WindowSwitcherLayout.size(windowCount: 50).height, PanelFamilyPlacement.height)
    }

    func testAlwaysRoomForOneRowAndNeverMoreThanTheVisibleRows() {
        XCTAssertEqual(WindowSwitcherLayout.size(windowCount: 0).height, WindowSwitcherLayout.size(windowCount: 1).height)
        XCTAssertEqual(WindowSwitcherLayout.size(windowCount: 50).height,
                       WindowSwitcherLayout.size(windowCount: WindowSwitcherLayout.visibleRows).height)
    }
}
