import XCTest
@testable import FrogCore

final class CommandConfirmationTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    func testASecondPressWithinTheWindowRunsAndDisarms() {
        var confirmation = CommandConfirmation()
        XCTAssertFalse(confirmation.press("quit:1", now: start))
        XCTAssertEqual(confirmation.armed?.id, "quit:1")
        XCTAssertTrue(confirmation.press("quit:1", now: start.addingTimeInterval(2.9)))
        XCTAssertNil(confirmation.armed)
        // Disarmed, the next press asks again.
        XCTAssertFalse(confirmation.press("quit:1", now: start.addingTimeInterval(3)))
    }

    func testAPressAfterTheWindowArmsAgain() {
        var confirmation = CommandConfirmation()
        XCTAssertFalse(confirmation.press("quit:1", now: start))
        XCTAssertFalse(confirmation.press("quit:1", now: start.addingTimeInterval(3.01)))
        XCTAssertEqual(confirmation.armed, CommandConfirmation.Arm(id: "quit:1", at: start.addingTimeInterval(3.01)))
        XCTAssertTrue(confirmation.press("quit:1", now: start.addingTimeInterval(4)))
    }

    func testAPressOnAnotherCommandArmsThatOne() {
        var confirmation = CommandConfirmation()
        XCTAssertFalse(confirmation.press("quit:1", now: start))
        XCTAssertFalse(confirmation.press("quit:2", now: start.addingTimeInterval(1)))
        XCTAssertEqual(confirmation.armed?.id, "quit:2")
        XCTAssertFalse(confirmation.press("quit:1", now: start.addingTimeInterval(1.5)))
        confirmation.disarm()
        XCTAssertNil(confirmation.armed)
        XCTAssertFalse(confirmation.press("quit:1", now: start.addingTimeInterval(2)))
    }
}
