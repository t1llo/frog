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

    func testARuleRunningElsewhereDropsThePendingReadAndTheShownSelection() {
        core.shown(fingerprint, now: start)
        _ = send(.shiftReleased)
        core.interrupted()
        XCTAssertNil(core.pendingToken)
        XCTAssertFalse(core.settleFired(token: 1), "the read scheduled before the rule ran never shows")
        XCTAssertNil(core.shownFingerprint)
        XCTAssertNil(core.dismissedFingerprint, "the same selection may bring the bubble back later")
        XCTAssertEqual(send(.scroll), [.dismiss(rememberShown: false)], "nothing pending to cancel")
    }

    func testTheOfferedSelectionOutlastsEveryWayTheBubbleGoes() {
        XCTAssertNil(core.offeredFingerprint)
        core.shown(fingerprint, now: start)
        _ = send(.mouseDown(.zero, clickCount: 1, right: false))
        XCTAssertNil(core.shownFingerprint)
        XCTAssertEqual(core.offeredFingerprint, fingerprint)
        core.hidden()
        core.interrupted()
        _ = send(.keyDown(keyCode: 53))
        // A drag, such as by a window's title bar.
        _ = send(.mouseDown(.zero, clickCount: 1, right: false))
        _ = send(.mouseUp(CGPoint(x: 200, y: 0), clickCount: 1, modifiers: []))
        _ = send(.scroll)
        _ = send(.applicationChanged)
        _ = send(.shiftReleased)
        XCTAssertEqual(core.offeredFingerprint, fingerprint, "Nothing here took the selection away")
        var other = fingerprint
        other.length = 9
        core.shown(other, now: start)
        XCTAssertEqual(core.offeredFingerprint, other, "Only the last one")
    }

    func testAPlainClickOrAKeyTakesTheOfferedSelectionAway() {
        func offeredAfter(_ inputs: [SelectionInput]) -> SelectionFingerprint? {
            core = SelectionWatcherCore()
            core.shown(fingerprint, now: start)
            for input in inputs { _ = send(input) }
            return core.offeredFingerprint
        }
        let down = SelectionInput.mouseDown(.zero, clickCount: 1, right: false)
        XCTAssertNil(offeredAfter([down, .mouseUp(.zero, clickCount: 1, modifiers: [])]), "A click collapses the selection")
        XCTAssertNil(offeredAfter([.keyDown(keyCode: 123)]), "An arrow key")
        XCTAssertNil(offeredAfter([.keyDown(keyCode: 124, modifiers: [.shift, .option])]))

        XCTAssertEqual(offeredAfter([down, .mouseUp(.zero, clickCount: 1, modifiers: .shift)]), fingerprint, "A Shift-click")
        XCTAssertEqual(offeredAfter([down, .mouseUp(.zero, clickCount: 1, modifiers: .command)]), fingerprint)
        XCTAssertEqual(offeredAfter([down, .mouseUp(.zero, clickCount: 2, modifiers: [])]), fingerprint)
        XCTAssertEqual(offeredAfter([.keyDown(keyCode: 17, modifiers: [.shift, .command])]), fingerprint, "⇧⌘T")
        XCTAssertEqual(offeredAfter([.keyDown(keyCode: 8, modifiers: .control)]), fingerprint)
        XCTAssertEqual(offeredAfter([.keyDown(keyCode: 53)]), fingerprint, "Escape keeps it, dismissed")
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
