import ServiceManagement
import XCTest
@testable import FrogApp

final class LoginServiceTests: XCTestCase {
    func testItemAwaitingApprovalStaysSwitchedOnAndAsksForAttention() {
        let waiting = LoginService.snapshot(for: .requiresApproval)
        XCTAssertTrue(waiting.enabled, "Switching the toggle off must still unregister the item")
        XCTAssertTrue(waiting.needsAttention, "Frog does not start at login until it is allowed in System Settings")
        XCTAssertEqual(waiting.text, "Allow Frog in System Settings → General → Login Items.")
    }

    func testOtherStatesDoNotAskForAttention() {
        XCTAssertEqual(LoginService.snapshot(for: .enabled), .init(enabled: true, text: "Frog starts at login."))
        XCTAssertEqual(LoginService.snapshot(for: .notRegistered), .init(enabled: false, text: "Start at login is off."))
        let missing = LoginService.snapshot(for: .notFound)
        XCTAssertFalse(missing.enabled)
        XCTAssertFalse(missing.needsAttention, "An item that is not installed has nothing to approve in Login Items")
    }
}
