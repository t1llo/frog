import AppKit
import XCTest
@testable import FrogApp

final class SwitcherApplicationTests: XCTestCase {
    func testOnlyLiveUserApplicationsEnterWindowInventory() {
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        XCTAssertTrue(SwitcherApplication.eligible(policy: .regular, terminated: false, bundleURL: safari))
        XCTAssertTrue(SwitcherApplication.eligible(policy: .regular, terminated: false, bundleURL: URL(fileURLWithPath: "/Applications/Docker.app")))
        XCTAssertFalse(SwitcherApplication.eligible(policy: .accessory, terminated: false, bundleURL: URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/Batteries.appex")))
        XCTAssertFalse(SwitcherApplication.eligible(policy: .prohibited, terminated: false, bundleURL: nil))
        XCTAssertFalse(SwitcherApplication.eligible(policy: .regular, terminated: true, bundleURL: safari))
        XCTAssertFalse(SwitcherApplication.eligible(policy: .regular, terminated: false, bundleURL: URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.docker.vmnetd")))
        XCTAssertEqual(WindowSwitcherLayout.size(windowCount: 3).height, 3 * WindowSwitcherLayout.rowHeight + 12)
    }
}
