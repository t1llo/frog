import XCTest
import CoreGraphics
@testable import FrogApp

final class WindowSwitcherTests: XCTestCase {
    func testCyclesIndividualWindowsIncludingSameAppAndWraps() {
        var session = WindowSwitchSession<Int>()
        session.begin(windows: [10, 11, 12], current: 10, backwards: false)
        XCTAssertEqual(session.selected, 11)
        session.step(backwards: false)
        XCTAssertEqual(session.selected, 12)
        session.step(backwards: false)
        XCTAssertEqual(session.selected, 10)
        session.step(backwards: true)
        XCTAssertEqual(session.selected, 12)
    }

    func testEmptySingleAndMissingCurrentWindow() {
        var session = WindowSwitchSession<Int>()
        session.begin(windows: [], current: nil, backwards: false)
        XCTAssertNil(session.selected)
        session.begin(windows: [10, 10], current: 10, backwards: true)
        XCTAssertEqual(session.windows, [10])
        XCTAssertEqual(session.selected, 10)
        session.begin(windows: [10, 11], current: 99, backwards: false)
        XCTAssertEqual(session.selected, 10)
        session.select(99)
        XCTAssertEqual(session.selected, 10)
        session.reset()
        XCTAssertNil(session.selected)
    }

    func testCommandReleaseCommitsOnceAndTabKeyUpIsConsumed() {
        var router = WindowSwitchKeyRouter()
        XCTAssertEqual(router.key(code: 48, down: true, command: true, shift: false, otherModifiers: false).action, .begin(backwards: false))
        XCTAssertEqual(router.key(code: 48, down: true, command: true, shift: true, otherModifiers: false).action, .step(backwards: true))
        XCTAssertEqual(router.modifiers(command: false).action, .commit)
        XCTAssertNil(router.modifiers(command: false).action)
        XCTAssertTrue(router.key(code: 48, down: false, command: false, shift: false, otherModifiers: false).consume)
    }

    func testEscapeCancelsAndDoesNotCommitOnRelease() {
        var router = WindowSwitchKeyRouter()
        _ = router.key(code: 48, down: true, command: true, shift: false, otherModifiers: false)
        let escape = router.key(code: 53, down: true, command: true, shift: false, otherModifiers: false)
        XCTAssertTrue(escape.consume)
        XCTAssertEqual(escape.action, .cancel)
        XCTAssertTrue(router.key(code: 53, down: true, command: true, shift: false, otherModifiers: false, repeating: true).consume)
        XCTAssertNil(router.modifiers(command: false).action)
    }

    func testUnrelatedShortcutsPassThroughAndCancelOverlay() {
        var router = WindowSwitchKeyRouter()
        XCTAssertFalse(router.key(code: 48, down: true, command: false, shift: false, otherModifiers: false).consume)
        XCTAssertFalse(router.key(code: 48, down: true, command: true, shift: false, otherModifiers: true).consume)
        _ = router.key(code: 48, down: true, command: true, shift: false, otherModifiers: false)
        let typing = router.key(code: 12, down: true, command: true, shift: false, otherModifiers: false)
        XCTAssertFalse(typing.consume)
        XCTAssertEqual(typing.action, .cancel)
        XCTAssertNil(router.modifiers(command: false).action)
    }

    func testEnterCommitsAndArrowKeysNavigateWithoutLeakingToSourceApp() {
        var router = WindowSwitchKeyRouter()
        _ = router.key(code: 48, down: true, command: true, shift: true, otherModifiers: false)
        let previous = router.key(code: 126, down: true, command: true, shift: false, otherModifiers: false)
        XCTAssertTrue(previous.consume)
        XCTAssertEqual(previous.action, .step(backwards: true))
        XCTAssertTrue(router.key(code: 126, down: false, command: true, shift: false, otherModifiers: false).consume)
        XCTAssertEqual(router.key(code: 125, down: true, command: true, shift: false, otherModifiers: false).action, .step(backwards: false))
        XCTAssertEqual(router.key(code: 36, down: true, command: true, shift: false, otherModifiers: false).action, .commit)
        XCTAssertTrue(router.key(code: 36, down: true, command: true, shift: false, otherModifiers: false, repeating: true).consume)
        XCTAssertNil(router.modifiers(command: false).action)
    }

    func testStoppingRouterRestoresAllKeys() {
        var router = WindowSwitchKeyRouter()
        _ = router.key(code: 48, down: true, command: true, shift: false, otherModifiers: false)
        router.reset()
        XCTAssertFalse(router.active)
        XCTAssertFalse(router.key(code: 48, down: false, command: false, shift: false, otherModifiers: false).consume)
        XCTAssertNil(router.modifiers(command: false).action)
    }

    func testEscapeAndTypingCancelPendingDiscoveryAfterCommandRelease() {
        for key in [UInt16(53), 0, 125] {
            var router = WindowSwitchKeyRouter()
            let start = router.key(code: 48, down: true, command: true, shift: false, otherModifiers: false)
            XCTAssertEqual(router.modifiers(command: false).action, .commit)
            let cancel = router.key(code: key, down: true, command: false, shift: false, otherModifiers: false)
            XCTAssertEqual(cancel.action, .cancel)
            XCTAssertEqual(cancel.sessionID, start.sessionID)
            XCTAssertEqual(cancel.consume, key == 53)
            XCTAssertNil(router.sessionID)
        }
    }

    func testDeferredCleanupCannotResetNewerInvocation() throws {
        var router = WindowSwitchKeyRouter()
        let first = router.key(code: 48, down: true, command: true, shift: false, otherModifiers: false)
        _ = router.modifiers(command: false)
        _ = router.key(code: 48, down: false, command: false, shift: false, otherModifiers: false)
        let second = router.key(code: 48, down: true, command: true, shift: false, otherModifiers: false)
        XCTAssertNotEqual(first.sessionID, second.sessionID)
        router.finish(session: try XCTUnwrap(first.sessionID))
        XCTAssertTrue(router.active)
        XCTAssertEqual(router.sessionID, second.sessionID)
        let commit = router.modifiers(command: false)
        XCTAssertEqual(commit.action, .commit)
        XCTAssertEqual(commit.sessionID, second.sessionID)
    }

    func testPointerRestingUnderTheListDoesNotChooseARow() {
        let shown = ContinuousClock.now
        var pointer = WindowSwitchPointer()
        XCTAssertFalse(pointer.selects(at: CGPoint(x: 400, y: 300), now: shown), "Nothing is selected before the list is up")
        pointer.rest(at: CGPoint(x: 400, y: 300), now: shown)
        // A hand on the mouse while Command-Tab is tapped: one point, then a real bump.
        XCTAssertFalse(pointer.selects(at: CGPoint(x: 401, y: 300), now: shown.advanced(by: .milliseconds(30))))
        XCTAssertFalse(pointer.selects(at: CGPoint(x: 440, y: 330), now: shown.advanced(by: .milliseconds(200))))
        // Still holding Command: what the bump covered does not count, nor does a small drift.
        XCTAssertFalse(pointer.selects(at: CGPoint(x: 446, y: 334), now: shown.advanced(by: .milliseconds(500))))
        XCTAssertFalse(pointer.selects(at: CGPoint(x: 446, y: 334), now: shown.advanced(by: .seconds(3))))
    }

    func testDeliberatePointerMovementSelectsAndThenFollows() {
        let shown = ContinuousClock.now
        var pointer = WindowSwitchPointer()
        pointer.rest(at: CGPoint(x: 400, y: 300), now: shown)
        XCTAssertFalse(pointer.selects(at: CGPoint(x: 400, y: 310), now: shown.advanced(by: .milliseconds(500))))
        XCTAssertTrue(pointer.selects(at: CGPoint(x: 400, y: 320), now: shown.advanced(by: .milliseconds(520))))
        XCTAssertTrue(pointer.selects(at: CGPoint(x: 400, y: 321), now: shown.advanced(by: .milliseconds(530))),
                      "Once the pointer is in use every row it reaches is selected")
        XCTAssertFalse(pointer.selects(at: CGPoint(x: 400, y: 321), now: shown.advanced(by: .milliseconds(540))),
                       "Rows scrolling under a pointer that stays put select nothing")
        // The list grew under the pointer while it was moved off the rows.
        pointer.relaid(at: CGPoint(x: 400, y: 380))
        XCTAssertFalse(pointer.selects(at: CGPoint(x: 400, y: 380), now: shown.advanced(by: .milliseconds(600))))
        XCTAssertTrue(pointer.selects(at: CGPoint(x: 400, y: 381), now: shown.advanced(by: .milliseconds(610))))
    }

    func testKeyTakesTheSelectionBackFromThePointer() {
        let shown = ContinuousClock.now
        var pointer = WindowSwitchPointer()
        pointer.rest(at: CGPoint(x: 400, y: 300), now: shown)
        XCTAssertTrue(pointer.selects(at: CGPoint(x: 400, y: 360), now: shown.advanced(by: .seconds(1))))
        // Tab moved the selection on; the hand still on the mouse must not pull it back.
        let stepped = shown.advanced(by: .seconds(2))
        pointer.rest(at: CGPoint(x: 400, y: 360), now: stepped)
        XCTAssertFalse(pointer.selects(at: CGPoint(x: 400, y: 362), now: stepped.advanced(by: .milliseconds(50))))
        XCTAssertFalse(pointer.selects(at: CGPoint(x: 400, y: 366), now: stepped.advanced(by: WindowSwitchPointer.settle)))
        XCTAssertTrue(pointer.selects(at: CGPoint(x: 400, y: 362 + WindowSwitchPointer.travel),
                                      now: stepped.advanced(by: .milliseconds(600))))
    }

    func testLargeWindowListsAreNotTruncatedByCyclingState() {
        var session = WindowSwitchSession<Int>()
        session.begin(windows: Array(0..<300), current: 0, backwards: true)
        XCTAssertEqual(session.selected, 299)
        XCTAssertEqual(session.windows.count, 300)
    }

    func testHeldReturnKeepsPendingActivationButNewTypingCancelsIt() throws {
        var router = WindowSwitchKeyRouter()
        let start = router.key(code: 48, down: true, command: true, shift: false, otherModifiers: false)
        _ = router.key(code: 36, down: true, command: true, shift: false, otherModifiers: false)
        router.finish(session: try XCTUnwrap(start.sessionID))
        let repeatedReturn = router.key(code: 36, down: true, command: true, shift: false, otherModifiers: false, repeating: true)
        XCTAssertTrue(repeatedReturn.consume)
        XCTAssertFalse(repeatedReturn.cancelsPendingActivation)
        let typing = router.key(code: 0, down: true, command: false, shift: false, otherModifiers: false)
        XCTAssertTrue(typing.cancelsPendingActivation)
    }
}

// Keep the original Command–Tab regression cases readable while routing them
// through the same full modifier-mask entry point as configurable shortcuts.
extension WindowSwitchKeyRouter {
    mutating func key(code: UInt16, down: Bool, command: Bool, shift: Bool, otherModifiers: Bool, text: String = "",
                      repeating: Bool = false) -> Result {
        var flags: CGEventFlags = []
        if command { flags.insert(.maskCommand) }
        if shift { flags.insert(.maskShift) }
        if otherModifiers { flags.insert(.maskAlternate) }
        return key(code: code, down: down, flags: flags, text: text, repeating: repeating)
    }
    mutating func modifiers(command: Bool) -> Result { modifiers(flags: command ? .maskCommand : []) }
}
