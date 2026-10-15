import CoreGraphics
import XCTest
@testable import FrogCore

final class SelectionGestureTrackerTests: XCTestCase {
    private var tracker = SelectionGestureTracker()
    private var options = SelectionBubbleOptions()

    private func send(_ input: SelectionInput) -> SelectionGestureTracker.Decision { tracker.receive(input, options: options) }

    private func click(at point: CGPoint = CGPoint(x: 100, y: 100), upAt end: CGPoint? = nil, count: Int = 1,
                       modifiers: BubbleModifiers = []) -> SelectionGestureTracker.Decision {
        XCTAssertEqual(send(.mouseDown(point, clickCount: count, right: false)), .dismiss(escape: false))
        return send(.mouseUp(end ?? point, clickCount: count, modifiers: modifiers))
    }

    func testMouseDownDismissesLeftAndRight() {
        XCTAssertEqual(send(.mouseDown(.zero, clickCount: 1, right: false)), .dismiss(escape: false))
        XCTAssertEqual(send(.mouseDown(.zero, clickCount: 1, right: true)), .dismiss(escape: false))
    }

    func testADragSchedulesFromFourPoints() {
        XCTAssertEqual(click(upAt: CGPoint(x: 103.9, y: 100)), .none)
        XCTAssertEqual(click(upAt: CGPoint(x: 104, y: 100)), .schedule(.drag))
        XCTAssertEqual(click(upAt: CGPoint(x: 100, y: 96)), .schedule(.drag))
    }

    func testAPlainClickNeverSchedules() {
        XCTAssertEqual(click(), .none)
        XCTAssertEqual(send(.mouseUp(CGPoint(x: 500, y: 500), clickCount: 1, modifiers: [])), .none,
                       "a mouse up without its mouse down is not a drag")
    }

    func testCommandIgnoresTheGesture() {
        XCTAssertEqual(click(upAt: CGPoint(x: 200, y: 100), modifiers: .command), .none)
        XCTAssertEqual(click(count: 2, modifiers: .command), .none)
    }

    func testDoubleAndTripleClicks() {
        XCTAssertEqual(click(count: 2), .schedule(.doubleClick))
        XCTAssertEqual(click(count: 3), .schedule(.tripleClick))
        XCTAssertEqual(click(count: 4), .schedule(.tripleClick))
        options.doubleClick = false
        XCTAssertEqual(click(count: 2), .none)
        XCTAssertEqual(click(count: 3), .none)
        XCTAssertEqual(click(upAt: CGPoint(x: 120, y: 100), count: 2), .schedule(.drag), "a drag still counts")
    }

    func testShiftClick() {
        XCTAssertEqual(click(modifiers: .shift), .schedule(.shiftClick))
        XCTAssertEqual(click(modifiers: [.shift, .option]), .schedule(.shiftClick))
    }

    func testShiftReleaseIsAKeyboardSelection() {
        XCTAssertEqual(send(.shiftReleased), .schedule(.keyboard))
        options.keyboard = false
        XCTAssertEqual(send(.shiftReleased), .none)
    }

    func testReleasingShiftAfterAMouseGestureKeepsThatGesture() {
        options.keyboard = false
        XCTAssertEqual(click(modifiers: .shift), .schedule(.shiftClick))
        XCTAssertEqual(send(.shiftReleased), .schedule(.shiftClick))
        options.keyboard = true
        XCTAssertEqual(click(modifiers: [.shift, .command]), .none)
        XCTAssertEqual(send(.shiftReleased), .none, "⌘⇧-click stays ignored")
        XCTAssertEqual(send(.shiftReleased), .schedule(.keyboard), "only the release right after the click")
    }

    func testKeysScrollsAndAppChangesDismiss() {
        XCTAssertEqual(send(.keyDown(keyCode: 53)), .dismiss(escape: true))
        XCTAssertEqual(send(.keyDown(keyCode: 0)), .dismiss(escape: false))
        XCTAssertEqual(send(.keyDown(keyCode: 124)), .dismiss(escape: false))
        XCTAssertEqual(send(.scroll), .dismiss(escape: false))
        XCTAssertEqual(send(.applicationChanged), .dismiss(escape: false))
    }
}
