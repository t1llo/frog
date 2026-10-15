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

    func testShortcutPressedAgainOnAWindowThatMissedItsFrameIsNotANewMove() throws {
        // A third of 2560 points is 853.33; the window reports whole points.
        let display = CGRect(x: 0, y: 25, width: 2560, height: 1415)
        let original = CGRect(x: 300, y: 200, width: 900, height: 600)
        let target = try XCTUnwrap(WindowGeometry.target(.leftThird, window: original, displays: [display]))
        let landed = CGRect(x: 0, y: 25, width: 853, height: 1415)
        XCTAssertNotEqual(target, landed)
        let move = WindowGeometry.Move(target: target, applied: landed)
        let again = try XCTUnwrap(WindowGeometry.target(.leftThird, window: landed, displays: [display]))
        XCTAssertTrue(move.isRepeated(by: again, from: landed), "Restore has to keep the frame from before the first press")

        // A minimum width wider than the tile leaves the window further off than rounding does.
        let wide = CGRect(x: 0, y: 25, width: 1100, height: 1415)
        let limited = WindowGeometry.Move(target: target, applied: wide)
        XCTAssertTrue(limited.isRepeated(by: try XCTUnwrap(WindowGeometry.target(.leftThird, window: wide, displays: [display])), from: wide))

        // Another action, or the same one on a window the user has moved since, is a new move.
        let right = try XCTUnwrap(WindowGeometry.target(.rightThird, window: landed, displays: [display]))
        XCTAssertFalse(move.isRepeated(by: right, from: landed))
        XCTAssertFalse(move.isRepeated(by: again, from: landed.offsetBy(dx: 40, dy: 0)))
        XCTAssertFalse(move.isRepeated(by: again, from: CGRect(x: 0, y: 25, width: 700, height: 1415)))
        XCTAssertFalse(limited.isRepeated(by: again, from: landed))
    }

    func testCenteringAgainAfterTheAppRoundedThePositionIsNotANewMove() throws {
        let display = CGRect(x: 0, y: 25, width: 1512, height: 957)
        let original = CGRect(x: 40, y: 60, width: 901, height: 601)
        let target = try XCTUnwrap(WindowGeometry.target(.center, window: original, displays: [display]))
        XCTAssertEqual(target.minX, 305.5)
        let landed = CGRect(x: 305, y: 203, width: 901, height: 601)
        let move = WindowGeometry.Move(target: target, applied: landed)
        let again = try XCTUnwrap(WindowGeometry.target(.center, window: landed, displays: [display]))
        XCTAssertNotEqual(again, landed)
        XCTAssertTrue(move.isRepeated(by: again, from: landed))
        // Centering a window that has been resized since moves it.
        let resized = CGRect(x: 305, y: 203, width: 600, height: 400)
        XCTAssertFalse(move.isRepeated(by: try XCTUnwrap(WindowGeometry.target(.center, window: resized, displays: [display])), from: resized))
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

    func testDefaultOptionsGiveTodaysFrameForEveryAction() {
        let layouts: [[CGRect]] = [
            [CGRect(x: 0, y: 25, width: 1511, height: 957)],
            [CGRect(x: 0, y: 25, width: 1511, height: 957), CGRect(x: 1511, y: -217, width: 2560, height: 1415)],
            [CGRect(x: 0, y: 25, width: 1440, height: 875), CGRect(x: -240, y: -1080, width: 1920, height: 1055)],
        ]
        let windows = [CGRect(x: 101, y: 133, width: 701, height: 503), CGRect(x: 1300, y: 90, width: 801, height: 611),
                       CGRect(x: 1700, y: -900, width: 1201, height: 2000)]
        for displays in layouts {
            for window in windows {
                for action in WindowAction.allCases {
                    let today = Self.todaysTarget(action, window: window, displays: displays)
                    XCTAssertEqual(WindowGeometry.target(action, window: window, displays: displays), today, "\(action) \(window) \(displays)")
                    XCTAssertEqual(WindowGeometry.target(action, window: window, displays: displays, options: .legacy), today, "\(action)")
                    XCTAssertEqual(WindowGeometry.target(action, window: window, displays: displays, options: .legacy, step: 0), today, "\(action)")
                }
            }
        }
    }

    func testPortraitThirdsRunTopToBottom() throws {
        let tall = CGRect(x: 1440, y: -500, width: 1080, height: 1895)
        let window = CGRect(x: 1500, y: 0, width: 600, height: 400)
        let options = WindowLayoutOptions(portraitThirds: true)
        let third = tall.height / 3
        let expected: [(WindowAction, CGFloat, CGFloat)] = [(.leftThird, 0, 1), (.centerThird, 1, 1), (.rightThird, 2, 1),
                                                            (.leftTwoThirds, 0, 2), (.rightTwoThirds, 1, 2)]
        for (action, offset, span) in expected {
            let frame = try XCTUnwrap(WindowGeometry.target(action, window: window, displays: [tall], options: options))
            XCTAssertEqual(frame.minX, tall.minX, "\(action)")
            XCTAssertEqual(frame.width, tall.width, "\(action)")
            XCTAssertEqual(frame.minY, tall.minY + offset * third, accuracy: 0.0001, "\(action)")
            XCTAssertEqual(frame.height, span * third, accuracy: 0.0001, "\(action)")
            // Switched off, or on a wide display, thirds stay side by side.
            XCTAssertEqual(WindowGeometry.target(action, window: window, displays: [tall]), Self.todaysTarget(action, window: window, displays: [tall]))
            let wide = CGRect(x: 0, y: 25, width: 1440, height: 875)
            XCTAssertEqual(WindowGeometry.target(action, window: CGRect(x: 10, y: 40, width: 300, height: 200), displays: [wide], options: options),
                           Self.todaysTarget(action, window: CGRect(x: 10, y: 40, width: 300, height: 200), displays: [wide]))
        }
    }

    func testCycledHalvesUseTwoThirdsThenOneThirdOfTheGappedArea() throws {
        let display = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let window = CGRect(x: 200, y: 200, width: 600, height: 400)
        let options = WindowLayoutOptions(gap: 10, cycleSizes: true)
        // The gapped area is 10, 35, 1420 × 855; the inner edge of each half keeps half the gap.
        func frame(_ action: WindowAction, _ step: Int) throws -> CGRect {
            try XCTUnwrap(WindowGeometry.target(action, window: window, displays: [display], options: options, step: step))
        }
        XCTAssertEqual(try frame(.leftHalf, 0), CGRect(x: 10, y: 35, width: 705, height: 855))
        let leftTwoThirds = try frame(.leftHalf, 1), leftThird = try frame(.leftHalf, 2)
        XCTAssertEqual(leftTwoThirds.minX, 10)
        XCTAssertEqual(leftTwoThirds.width, 1420 * 2 / 3 - 5, accuracy: 0.0001)
        XCTAssertEqual(leftThird.width, 1420 / 3 - 5, accuracy: 0.0001)
        let rightTwoThirds = try frame(.rightHalf, 1)
        XCTAssertEqual(rightTwoThirds.maxX, 1430, accuracy: 0.0001)
        XCTAssertEqual(rightTwoThirds.width, 1420 * 2 / 3 - 5, accuracy: 0.0001)
        // Left ⅓ and right ⅔ sit one gap apart.
        XCTAssertEqual(rightTwoThirds.minX - leftThird.maxX, 10, accuracy: 0.0001)
        let topTwoThirds = try frame(.topHalf, 1), bottomThird = try frame(.bottomHalf, 2)
        XCTAssertTrue(WindowGeometry.close(topTwoThirds, CGRect(x: 10, y: 35, width: 1420, height: 565)), "\(topTwoThirds)")
        XCTAssertTrue(WindowGeometry.close(bottomThird, CGRect(x: 10, y: 610, width: 1420, height: 280)), "\(bottomThird)")
        XCTAssertEqual(bottomThird.minY - topTwoThirds.maxY, 10, accuracy: 0.0001)
        XCTAssertEqual(bottomThird.maxY, 890, accuracy: 0.0001)
        // Quarters and thirds do not cycle.
        XCTAssertEqual(try frame(.topLeft, 2), try frame(.topLeft, 0))
        XCTAssertEqual(try frame(.leftThird, 1), try frame(.leftThird, 0))
    }

    /// The layouts as they were before layout options existed.
    private static func todaysTarget(_ action: WindowAction, window: CGRect, displays: [CGRect]) -> CGRect? {
        guard let index = WindowGeometry.displayIndex(for: window, displays: displays) else { return nil }
        let display = displays[index]
        let halfWidth = display.width / 2, halfHeight = display.height / 2
        switch action {
        case .leftHalf: return CGRect(x: display.minX, y: display.minY, width: halfWidth, height: display.height)
        case .rightHalf: return CGRect(x: display.midX, y: display.minY, width: halfWidth, height: display.height)
        case .topHalf: return CGRect(x: display.minX, y: display.minY, width: display.width, height: halfHeight)
        case .bottomHalf: return CGRect(x: display.minX, y: display.midY, width: display.width, height: halfHeight)
        case .topLeft: return CGRect(x: display.minX, y: display.minY, width: halfWidth, height: halfHeight)
        case .topRight: return CGRect(x: display.midX, y: display.minY, width: halfWidth, height: halfHeight)
        case .bottomLeft: return CGRect(x: display.minX, y: display.midY, width: halfWidth, height: halfHeight)
        case .bottomRight: return CGRect(x: display.midX, y: display.midY, width: halfWidth, height: halfHeight)
        case .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds:
            let third = display.width / 3
            let offset: CGFloat = action == .rightThird ? 2 : (action == .centerThird || action == .rightTwoThirds ? 1 : 0)
            let width = (action == .leftTwoThirds || action == .rightTwoThirds) ? third * 2 : third
            return CGRect(x: display.minX + offset * third, y: display.minY, width: width, height: display.height)
        case .centeredSmall, .centeredMedium, .centeredLarge:
            let fraction: CGFloat = action == .centeredSmall ? 0.5 : (action == .centeredMedium ? 0.7 : 0.9)
            let width = display.width * fraction, height = display.height * fraction
            return CGRect(x: display.midX - width / 2, y: display.midY - height / 2, width: width, height: height)
        case .maximize: return display
        case .center:
            let size = CGSize(width: min(window.width, display.width), height: min(window.height, display.height))
            return CGRect(x: display.midX - size.width / 2, y: display.midY - size.height / 2, width: size.width, height: size.height)
        case .nextDisplay, .previousDisplay:
            guard displays.count > 1 else { return window }
            let next = displays[(index + (action == .nextDisplay ? 1 : displays.count - 1)) % displays.count]
            let width = min(window.width, next.width), height = min(window.height, next.height)
            let x = max(0, min(1, (window.minX - display.minX) / max(1, display.width - window.width)))
            let y = max(0, min(1, (window.minY - display.minY) / max(1, display.height - window.height)))
            return CGRect(x: next.minX + x * (next.width - width), y: next.minY + y * (next.height - height), width: width, height: height)
        case .minimize, .restore, .toggleFullScreen: return nil
        }
    }
}
