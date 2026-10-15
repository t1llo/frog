import XCTest
import FrogCore
@testable import FrogApp

final class WindowFrameHistoryTests: XCTestCase {
    private func move(_ x: CGFloat) -> WindowGeometry.Move {
        let frame = CGRect(x: x, y: 0, width: 100, height: 100)
        return WindowGeometry.Move(target: frame, applied: frame)
    }

    func testRecordReplacesTheWindowsEntryAndMovesItToTheEnd() {
        var history = WindowFrameHistory()
        let first = WindowKey(pid: 1, number: 1), second = WindowKey(pid: 1, number: 2)
        history.record(first, before: CGRect(x: 1, y: 1, width: 10, height: 10), move: move(0))
        history.record(second, before: CGRect(x: 2, y: 2, width: 10, height: 10), move: move(0))
        history.record(first, before: CGRect(x: 3, y: 3, width: 10, height: 10), move: move(50))
        XCTAssertEqual(history.entries.map(\.key), [second, first])
        XCTAssertEqual(history.entry(for: first)?.frame, CGRect(x: 3, y: 3, width: 10, height: 10))
        XCTAssertEqual(history.entry(for: first)?.move, move(50))
    }

    func testKeepsTheMostRecentFifty() {
        var history = WindowFrameHistory()
        for number in 1...60 { history.record(WindowKey(pid: 1, number: UInt32(number)), before: .zero, move: move(0)) }
        XCTAssertEqual(history.entries.count, history.limit)
        XCTAssertEqual(history.limit, 50)
        XCTAssertNil(history.entry(for: WindowKey(pid: 1, number: 10)))
        XCTAssertNotNil(history.entry(for: WindowKey(pid: 1, number: 11)))
        XCTAssertEqual(history.entries.last?.key, WindowKey(pid: 1, number: 60))
    }

    func testRemoveForgetsOnlyThatWindow() {
        var history = WindowFrameHistory()
        let first = WindowKey(pid: 1, number: 1), other = WindowKey(pid: 2, number: 1)
        history.record(first, before: .zero, move: move(0))
        history.record(other, before: .zero, move: move(0))
        history.remove(first)
        XCTAssertNil(history.entry(for: first))
        XCTAssertNotNil(history.entry(for: other))
    }
}

final class WindowDisplaysConversionTests: XCTestCase {
    func testPrimaryDisplayKeepsItsOriginBelowTheMenuBar() {
        // Cocoa's visible frame of a 1440×900 primary display with a 25 pt menu bar and no Dock.
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        XCTAssertEqual(WindowDisplays.accessibilityRect(visible, primaryTop: 900), CGRect(x: 0, y: 25, width: 1440, height: 875))
        XCTAssertEqual(WindowDisplays.accessibilityRect(CGRect(x: 0, y: 0, width: 1440, height: 900), primaryTop: 900),
                       CGRect(x: 0, y: 0, width: 1440, height: 900))
    }

    func testDisplayAboveThePrimaryHasNegativeY() {
        let above = CGRect(x: -240, y: 900, width: 1920, height: 1080)
        XCTAssertEqual(WindowDisplays.accessibilityRect(above, primaryTop: 900), CGRect(x: -240, y: -1080, width: 1920, height: 1080))
    }
}
