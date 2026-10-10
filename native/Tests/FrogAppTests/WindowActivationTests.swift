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
    func testFinalRaiseWaitsForApplicationToBecomeFrontmost() async {
        var ticks = 0
        var finalRaiseTicks: [Int] = []
        let result = await WindowActivation.perform(raise: { finalRaiseTicks.append(ticks); return true }, request: { true }, bringForward: { true }, isFrontmost: { ticks >= 2 }, pause: { ticks += 1 })
        XCTAssertTrue(result)
        XCTAssertEqual(finalRaiseTicks, [0, 2])
    }
}
