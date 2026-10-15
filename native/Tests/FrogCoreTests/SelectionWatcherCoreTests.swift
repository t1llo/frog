import CoreGraphics
import XCTest
@testable import FrogCore

final class SelectionWatcherCoreTests: XCTestCase {
    private var core = SelectionWatcherCore()
    private let options = SelectionBubbleOptions()
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private let fingerprint = SelectionFingerprint(pid: 42, element: 7, location: 3, length: 5, textHash: 99)

    private func send(_ input: SelectionInput, at offset: TimeInterval = 0) -> [SelectionWatcherCore.Effect] {
        core.receive(input, now: start.addingTimeInterval(offset), options: options)
    }

    private func snapshot(_ fingerprint: SelectionFingerprint, text: String = "river bank") -> SelectionReadResult {
        .selection(SelectionSnapshot(text: text, bounds: nil, endBounds: nil, context: nil, source: nil, isEditable: false,
                                     pid: fingerprint.pid, bundleID: nil, applicationName: nil, fingerprint: fingerprint))
    }

    func testAGestureSchedulesAReadAfterTheSettle() {
        XCTAssertEqual(send(.mouseDown(.zero, clickCount: 2, right: false)), [.dismiss(rememberShown: false)])
        XCTAssertEqual(send(.mouseUp(.zero, clickCount: 2, modifiers: []), at: 1),
                       [.scheduleRead(token: 1, at: start.addingTimeInterval(1.3), gesture: .doubleClick)])
        XCTAssertTrue(core.settleFired(token: 1))
        XCTAssertFalse(core.settleFired(token: 1), "a settle reads once")
    }

    func testANewInputCancelsAndInvalidatesThePendingRead() {
        XCTAssertEqual(send(.shiftReleased), [.scheduleRead(token: 1, at: start.addingTimeInterval(0.3), gesture: .keyboard)])
        XCTAssertEqual(send(.shiftReleased, at: 0.1),
                       [.cancelPending, .scheduleRead(token: 2, at: start.addingTimeInterval(0.4), gesture: .keyboard)])
        XCTAssertFalse(core.settleFired(token: 1))
        XCTAssertEqual(send(.scroll, at: 0.2), [.cancelPending, .dismiss(rememberShown: false)])
        XCTAssertFalse(core.settleFired(token: 2))
        XCTAssertNil(core.pendingToken)
    }

    func testAnInputThatDecidesNothingStillCancels() {
        _ = send(.shiftReleased)
        XCTAssertEqual(send(.mouseUp(.zero, clickCount: 1, modifiers: [])), [.cancelPending])
        XCTAssertFalse(core.settleFired(token: 1))
    }

    func testEscapeRemembersTheShownSelection() {
        core.shown(fingerprint, now: start)
        XCTAssertEqual(send(.keyDown(keyCode: 53)), [.dismiss(rememberShown: true)])
        XCTAssertEqual(core.dismissedFingerprint, fingerprint)
        XCTAssertNil(core.shownFingerprint)
        XCTAssertEqual(SelectionBubblePolicy.mayShow(snapshot(fingerprint), dismissed: core.dismissedFingerprint,
                                                     shown: core.shownFingerprint, itemCount: 2), .dismissedBefore)
        var other = fingerprint
        other.location = 4
        XCTAssertNil(SelectionBubblePolicy.mayShow(snapshot(other), dismissed: core.dismissedFingerprint,
                                                   shown: core.shownFingerprint, itemCount: 2))
    }

    func testOtherDismissalsForgetTheShownSelectionWithoutRememberingIt() {
        core.shown(fingerprint, now: start)
        XCTAssertEqual(send(.keyDown(keyCode: 0)), [.dismiss(rememberShown: false)])
        XCTAssertNil(core.dismissedFingerprint)
        XCTAssertNil(core.shownFingerprint)
        XCTAssertEqual(send(.keyDown(keyCode: 53)), [.dismiss(rememberShown: false)], "nothing shown to remember")
        XCTAssertNil(core.dismissedFingerprint)
    }

    func testIdleDismissalAfterSixSecondsAndHoverResetsIt() {
        XCTAssertFalse(core.shouldIdleDismiss(now: start.addingTimeInterval(60)), "nothing shown")
        core.shown(fingerprint, now: start)
        XCTAssertFalse(core.shouldIdleDismiss(now: start.addingTimeInterval(5.9)))
        XCTAssertTrue(core.shouldIdleDismiss(now: start.addingTimeInterval(6)))
        core.hovered(now: start.addingTimeInterval(5))
        XCTAssertFalse(core.shouldIdleDismiss(now: start.addingTimeInterval(10.9)))
        XCTAssertTrue(core.shouldIdleDismiss(now: start.addingTimeInterval(11)))
        core.hidden()
        XCTAssertFalse(core.shouldIdleDismiss(now: start.addingTimeInterval(30)))
        XCTAssertNil(core.shownFingerprint)
    }
}
