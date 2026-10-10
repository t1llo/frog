import XCTest
@testable import FrogUsage

final class UsagePaceTests: XCTestCase {
    func testWeeklyPaceUsesElapsedTimeAndRejectsUnknownWindows() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func window(_ used: Double, remaining: Double = 302400, duration: Double? = 604800) -> UsageWindow {
            UsageWindow(id: "week", title: "Week", percentage: used, resetsAt: now.addingTimeInterval(remaining), duration: duration)
        }
        XCTAssertEqual(window(50).pace(at: now), "On pace")
        XCTAssertEqual(window(68).pace(at: now), "Ahead of pace")
        XCTAssertEqual(window(12).pace(at: now), "Under pace")
        XCTAssertEqual(window(100).pace(at: now), "Limit reached")
        XCTAssertNil(window(.nan).pace(at: now))
        XCTAssertNil(window(50, duration: nil).pace(at: now))
        XCTAssertNil(window(50, remaining: -1).pace(at: now))
        XCTAssertNil(window(50, remaining: 700000).pace(at: now))
    }
}
