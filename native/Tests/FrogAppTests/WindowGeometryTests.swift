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

    func testExistingWindowShortcutIdentitiesStayCompatible() {
        let legacy: [WindowAction] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf, .topLeft, .topRight, .bottomLeft, .bottomRight,
                                      .maximize, .minimize, .center, .restore, .nextDisplay, .previousDisplay, .toggleFullScreen]
        for (index, action) in legacy.enumerated() {
            XCTAssertEqual(action.rule.id.uuidString, String(format: "AC57F600-63D0-4E76-9900-%012d", index + 1))
        }
    }

    func testThirdsTileOffsetDisplayWithoutGapsAndTwoThirdsSpanTwoTiles() throws {
        let display = CGRect(x: -1511, y: -217, width: 1511, height: 983)
        let window = CGRect(x: -1400, y: -100, width: 500, height: 400)
        let left = try XCTUnwrap(WindowGeometry.target(.leftThird, window: window, displays: [display]))
        let center = try XCTUnwrap(WindowGeometry.target(.centerThird, window: window, displays: [display]))
        let right = try XCTUnwrap(WindowGeometry.target(.rightThird, window: window, displays: [display]))
        XCTAssertEqual(left.minX, display.minX)
        XCTAssertEqual(left.maxX, center.minX, accuracy: 0.0001)
        XCTAssertEqual(center.maxX, right.minX, accuracy: 0.0001)
        XCTAssertEqual(right.maxX, display.maxX, accuracy: 0.0001)
        for frame in [left, center, right] {
            XCTAssertEqual(frame.width, display.width / 3, accuracy: 0.0001)
            XCTAssertEqual(frame.minY, display.minY)
            XCTAssertEqual(frame.height, display.height)
        }
        let leftTwo = try XCTUnwrap(WindowGeometry.target(.leftTwoThirds, window: window, displays: [display]))
        let rightTwo = try XCTUnwrap(WindowGeometry.target(.rightTwoThirds, window: window, displays: [display]))
        XCTAssertEqual(leftTwo.minX, left.minX)
        XCTAssertEqual(leftTwo.maxX, center.maxX, accuracy: 0.0001)
        XCTAssertEqual(rightTwo.minX, center.minX)
        XCTAssertEqual(rightTwo.maxX, right.maxX, accuracy: 0.0001)
    }

    func testCenteredSizesFitChosenDisplayAndKeepItsCenter() throws {
        let displays = [CGRect(x: -1600, y: 24, width: 1600, height: 976), CGRect(x: 0, y: -700, width: 1200, height: 700)]
        let window = CGRect(x: 900, y: -600, width: 1800, height: 900)
        for (action, fraction) in [(WindowAction.centeredSmall, 0.5), (.centeredMedium, 0.7), (.centeredLarge, 0.9)] {
            let frame = try XCTUnwrap(WindowGeometry.target(action, window: window, displays: displays))
            XCTAssertTrue(displays[1].contains(frame))
            XCTAssertEqual(frame.midX, displays[1].midX, accuracy: 0.0001)
            XCTAssertEqual(frame.midY, displays[1].midY, accuracy: 0.0001)
            XCTAssertEqual(frame.width, displays[1].width * fraction, accuracy: 0.0001)
            XCTAssertEqual(frame.height, displays[1].height * fraction, accuracy: 0.0001)
            XCTAssertNil(WindowGeometry.target(action, window: window, displays: []))
        }
    }

    func testSystemActionRoutesRequireNoSyntheticHotkeysOrSystemExecution() throws {
        for action in SystemAction.allCases {
            let destination = SystemActionController.destination(for: action)
            let shortcut = SystemActionController.menuShortcut(for: action)
            XCTAssertNotEqual(destination == nil, shortcut == nil, "Each action has exactly one native route: \(action)")
            if let destination {
                XCTAssertTrue(["file", "x-apple.systempreferences"].contains(destination.scheme ?? ""))
            }
        }
        XCTAssertEqual(SystemActionController.menuShortcut(for: .lockScreen), .init(character: "q", modifiers: 4))
        XCTAssertEqual(SystemActionController.menuShortcut(for: .redo), .init(character: "z", modifiers: 1))
        XCTAssertEqual(SystemActionController.menuShortcut(for: .paste), .init(character: "v", modifiers: 0))
        let screenshot = try XCTUnwrap(SystemActionController.destination(for: .screenshot))
        XCTAssertEqual(screenshot.path, "/System/Applications/Utilities/Screenshot.app")
    }
}
