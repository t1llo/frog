import XCTest
@testable import FrogCore

final class PermissionHelperPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let panel = CGSize(width: 300, height: 64)

    func testSitsCentredUnderTheWindowWhenThereIsRoom() {
        let window = CGRect(x: 400, y: 200, width: 600, height: 500)
        let frame = PermissionHelperPlacement.frame(panel: panel, settingsWindow: window, screen: screen)
        XCTAssertEqual(frame.midX, window.midX)
        XCTAssertEqual(frame.maxY, window.minY - PermissionHelperPlacement.gap)
    }

    func testSitsInsideTheWindowsBottomEdgeWhenNoRoomBelow() {
        let window = CGRect(x: 400, y: 10, width: 600, height: 500)
        let frame = PermissionHelperPlacement.frame(panel: panel, settingsWindow: window, screen: screen)
        XCTAssertEqual(frame.minY, window.minY + PermissionHelperPlacement.inset)
        XCTAssertEqual(frame.midX, window.midX)
    }

    func testFallsBackToTheScreensBottomCentre() {
        let frame = PermissionHelperPlacement.frame(panel: panel, settingsWindow: nil, screen: screen)
        XCTAssertEqual(frame.midX, screen.midX)
        XCTAssertEqual(frame.minY, screen.minY + PermissionHelperPlacement.inset + 4)
    }

    func testStaysOnTheScreen() {
        let window = CGRect(x: -200, y: 200, width: 400, height: 500)
        let frame = PermissionHelperPlacement.frame(panel: panel, settingsWindow: window, screen: screen)
        XCTAssertGreaterThanOrEqual(frame.minX, screen.minX)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
    }

    func testConvertsQuartzToAppKitCoordinates() {
        let quartz = CGRect(x: 100, y: 50, width: 600, height: 400)
        let rect = PermissionHelperPlacement.appKitRect(fromQuartz: quartz, mainDisplayHeight: 900)
        XCTAssertEqual(rect, CGRect(x: 100, y: 450, width: 600, height: 400))
    }

    func testDragsTheBundleOrTheExecutableWhenUnbundled() {
        let bundle = URL(fileURLWithPath: "/Applications/Frog.app")
        XCTAssertEqual(PermissionHelperPlacement.dragURL(bundleURL: bundle, executableURL: nil).url, bundle)
        XCTAssertTrue(PermissionHelperPlacement.dragURL(bundleURL: bundle, executableURL: nil).isBundle)
        let build = URL(fileURLWithPath: "/repo/.build/release", isDirectory: true)
        let executable = URL(fileURLWithPath: "/repo/.build/release/Frog")
        let result = PermissionHelperPlacement.dragURL(bundleURL: build, executableURL: executable)
        XCTAssertEqual(result.url, executable)
        XCTAssertFalse(result.isBundle)
    }
}
