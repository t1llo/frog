import XCTest
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
        XCTAssertTrue(router.key(code: 53, down: true, command: true, shift: false, otherModifiers: false).consume)
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
        XCTAssertTrue(router.key(code: 36, down: true, command: true, shift: false, otherModifiers: false).consume)
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
        let repeatedReturn = router.key(code: 36, down: true, command: true, shift: false, otherModifiers: false)
        XCTAssertTrue(repeatedReturn.consume)
        XCTAssertFalse(repeatedReturn.cancelsPendingActivation)
        let typing = router.key(code: 0, down: true, command: false, shift: false, otherModifiers: false)
        XCTAssertTrue(typing.cancelsPendingActivation)
    }
}
