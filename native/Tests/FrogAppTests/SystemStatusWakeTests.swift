import XCTest
@testable import FrogApp

/// An idle Frog in the background waits for a wake instead of polling, with or without Accessibility.
@MainActor final class SystemStatusWakeTests: XCTestCase {
    func testOnlyFrogInFrontOrAFreshChangeIsReadEverySecond() {
        XCTAssertEqual(SystemStatusWake.pause(active: true, watchingTap: false, readAgain: false), .sleep(.seconds(1)))
        XCTAssertEqual(SystemStatusWake.pause(active: false, watchingTap: false, readAgain: true), .sleep(.seconds(1)))
        XCTAssertEqual(SystemStatusWake.pause(active: false, watchingTap: true, readAgain: false), .sleep(SystemStatusWake.tapCheck))
        XCTAssertEqual(SystemStatusWake.pause(active: false, watchingTap: false, readAgain: false), .untilWake)
    }
}
