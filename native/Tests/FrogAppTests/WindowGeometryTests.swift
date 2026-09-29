import XCTest
import FrogCore
@testable import FrogApp

final class WindowGeometryTests: XCTestCase {
    func testHalvesAndQuartersUseVisibleDisplayInGlobalCoordinates() {
        let display = CGRect(x: -1440, y: -200, width: 1440, height: 880)
        let window = CGRect(x: -1000, y: 0, width: 500, height: 400)
        XCTAssertEqual(WindowGeometry.target(.leftHalf, window: window, displays: [display]), CGRect(x: -1440, y: -200, width: 720, height: 880))
        XCTAssertEqual(WindowGeometry.target(.rightHalf, window: window, displays: [display]), CGRect(x: -720, y: -200, width: 720, height: 880))
        XCTAssertEqual(WindowGeometry.target(.topHalf, window: window, displays: [display]), CGRect(x: -1440, y: -200, width: 1440, height: 440))
        XCTAssertEqual(WindowGeometry.target(.bottomRight, window: window, displays: [display]), CGRect(x: -720, y: 240, width: 720, height: 440))
        XCTAssertEqual(WindowGeometry.target(.maximize, window: window, displays: [display]), display)
    }

    func testDisplayMovementWrapsAndFitsSmallerDisplay() {
        let displays = [CGRect(x: -1600, y: 0, width: 1600, height: 1000), CGRect(x: 0, y: 24, width: 1200, height: 760)]
        let large = CGRect(x: -1500, y: 50, width: 1400, height: 900)
        XCTAssertEqual(WindowGeometry.target(.nextDisplay, window: large, displays: displays), displays[1])
        let right = CGRect(x: 100, y: 100, width: 500, height: 400)
        let wrapped = WindowGeometry.target(.nextDisplay, window: right, displays: displays)!
        XCTAssertTrue(displays[0].contains(wrapped))
        XCTAssertEqual(wrapped.size, right.size)
        XCTAssertEqual(WindowGeometry.target(.previousDisplay, window: right, displays: displays), wrapped)
        XCTAssertEqual(WindowGeometry.target(.nextDisplay, window: right, displays: [displays[1]]), right)
    }

    func testCenterKeepsWindowSizeAndUsesLargestOverlap() {
        let displays = [CGRect(x: 0, y: 24, width: 1000, height: 700), CGRect(x: 1000, y: 0, width: 1200, height: 900)]
        let window = CGRect(x: 900, y: 100, width: 400, height: 300)
        XCTAssertEqual(WindowGeometry.displayIndex(for: window, displays: displays), 1)
        XCTAssertEqual(WindowGeometry.target(.center, window: window, displays: displays), CGRect(x: 1400, y: 300, width: 400, height: 300))
        XCTAssertNil(WindowGeometry.target(.center, window: window, displays: []))
    }

    func testAllActionsStartDisabledWithoutShortcutsAndRoundTrip() throws {
        let rules = WindowAction.allCases.map(\.rule)
        XCTAssertEqual(Set(rules.map(\.id)).count, WindowAction.allCases.count)
        XCTAssertTrue(rules.allSatisfy { !$0.enabled && $0.hotkey == nil && $0.category == .window })
        var configuration = Configuration(); configuration.rules = rules
        let data = try ConfigurationFile.encode(configuration)
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: data), configuration)
    }
}
