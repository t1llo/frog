import XCTest
@testable import FrogApp

@MainActor final class WindowTargetTrackerTests: XCTestCase {
    private let own: pid_t = 1

    func testTheFrontmostOtherAppWins() {
        XCTAssertEqual(WindowTargetTracker.target(frontmost: 10, remembered: 20, own: own), 10)
        XCTAssertEqual(WindowTargetTracker.target(frontmost: 10, remembered: nil, own: own), 10)
    }

    func testWithFrogInFrontTheRememberedAppIsTheTarget() {
        XCTAssertEqual(WindowTargetTracker.target(frontmost: own, remembered: 20, own: own), 20)
        XCTAssertEqual(WindowTargetTracker.target(frontmost: nil, remembered: 20, own: own), 20)
    }

    func testWithoutAnotherAppThereIsNoTarget() {
        XCTAssertNil(WindowTargetTracker.target(frontmost: own, remembered: nil, own: own))
        XCTAssertNil(WindowTargetTracker.target(frontmost: nil, remembered: nil, own: own))
        XCTAssertNil(WindowTargetTracker.target(frontmost: own, remembered: own, own: own))
    }

    func testItWatchesOnlyWhileStarted() {
        let tracker = WindowTargetTracker()
        XCTAssertFalse(tracker.running)
        tracker.start()
        XCTAssertTrue(tracker.running)
        tracker.stop()
        XCTAssertFalse(tracker.running)
        XCTAssertNil(tracker.remembered)
    }
}
