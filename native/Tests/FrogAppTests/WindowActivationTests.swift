import AppKit
import XCTest
@testable import FrogApp

@MainActor
final class WindowActivationTests: XCTestCase {
    func testInvalidatedSelectionNeverRequestsFocus() async {
        let result = await WindowActivation.perform(raise: { XCTFail("Stale raise"); return true },
            request: { XCTFail("Stale activation"); return true }, bringForward: { XCTFail("Stale fallback"); return true },
            isFrontmost: { false }, isCurrent: { false }, pause: {})
        XCTAssertFalse(result)
    }

    func testInvalidationWhileRaisingCannotTriggerFallbackOrSecondRaise() async {
        var current = true
        var raises = 0
        let result = await WindowActivation.perform(raise: { raises += 1; current = false; return true },
            request: { true }, bringForward: { XCTFail("Stale fallback"); return true },
            isFrontmost: { false }, isCurrent: { current }, pause: {})
        XCTAssertFalse(result)
        XCTAssertEqual(raises, 1)
    }

    func testCancellationWhileWaitingDoesNotRaiseAgain() async {
        var raises = 0
        let result = await WindowActivation.perform(raise: { raises += 1; return true }, request: { true }, bringForward: { true }, isFrontmost: { false }, pause: { throw CancellationError() })
        XCTAssertFalse(result)
        XCTAssertEqual(raises, 1)
    }
    func testExplicitChoiceCanReplaceAnotherForegroundApplication() async {
        var selectedIsFrontmost = false
        var raises = 0
        let result = await WindowActivation.perform(raise: { raises += 1; return true }, request: { true }, bringForward: {
            selectedIsFrontmost = true; return true
        }, isFrontmost: { selectedIsFrontmost }, pause: {})
        XCTAssertTrue(result)
        XCTAssertTrue(selectedIsFrontmost, "Raising inside a background app must not leave Terminal in front")
        XCTAssertEqual(raises, 2)
    }
    func testAcceptedActivationRequestIsNotProofOfForegroundOwnership() async {
        let result = await WindowActivation.perform(raise: { true }, request: { true }, bringForward: { false }, isFrontmost: { false }, pause: {})
        XCTAssertFalse(result)
    }
    func testAppStillReportedInFrontIsAskedForAgainWhileAnotherIsOnItsWay() async {
        var requests = 0
        var raises = 0
        // The app chosen a moment ago has not arrived; the one returned to must follow it.
        let result = await WindowActivation.perform(raise: { raises += 1; return true }, request: { requests += 1; return true },
            bringForward: { XCTFail("Unexpected fallback"); return false }, isFrontmost: { true },
            expectsAnother: { requests == 0 }, pause: {})
        XCTAssertTrue(result)
        XCTAssertEqual(requests, 1, "Without a request the app on its way would end up in front")
        XCTAssertEqual(raises, 1)
    }
    func testFinalRaiseWaitsForApplicationToBecomeFrontmost() async {
        var ticks = 0
        var finalRaiseTicks: [Int] = []
        let result = await WindowActivation.perform(raise: { finalRaiseTicks.append(ticks); return true }, request: { true }, bringForward: { true }, isFrontmost: { ticks >= 2 }, pause: { ticks += 1 })
        XCTAssertTrue(result)
        XCTAssertEqual(finalRaiseTicks, [0, 2])
    }
}
