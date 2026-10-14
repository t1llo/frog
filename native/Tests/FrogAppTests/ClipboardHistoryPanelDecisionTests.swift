import AppKit
import XCTest
@testable import FrogApp

/// What the clipboard panel decides, on events built in the test. No panel is shown.
@MainActor
final class ClipboardHistoryPanelDecisionTests: XCTestCase {
    func testCopyShortcutFollowsTheKeyboardLayout() throws {
        func key(_ code: UInt16, _ characters: String, ignoringModifiers: String? = nil,
                 flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: ignoringModifiers ?? characters, isARepeat: false, keyCode: code))
        }
        XCTAssertTrue(ClipboardHistoryController.isCopyShortcut(try key(8, "c")), "QWERTY")
        XCTAssertTrue(ClipboardHistoryController.isCopyShortcut(try key(34, "c")), "Dvorak types C with the key QWERTY has as I")
        XCTAssertFalse(ClipboardHistoryController.isCopyShortcut(try key(8, "j")), "On Dvorak the QWERTY C key is J")
        XCTAssertTrue(ClipboardHistoryController.isCopyShortcut(try key(8, "c", ignoringModifiers: "с")),
            "A Cyrillic layout types C while Command is held")
        XCTAssertTrue(ClipboardHistoryController.isCopyShortcut(try key(8, "")), "An event without characters keeps the QWERTY position")
        XCTAssertFalse(ClipboardHistoryController.isCopyShortcut(try key(8, "c", flags: [.command, .shift])))
        XCTAssertFalse(ClipboardHistoryController.isCopyShortcut(try key(8, "c", flags: [])))
    }

    func testOnlyAScrollThatMovesSomethingCountsAsNewInput() throws {
        // Built, never posted: a trackpad scroll in its phases.
        func scroll(_ delta: Int32, phase: Int64 = 0, momentum: Int64 = 0) throws -> NSEvent {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: delta, wheel2: 0, wheel3: 0))
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            return try XCTUnwrap(NSEvent(cgEvent: event))
        }
        let began = try scroll(-12, phase: Int64(CGScrollPhase.began.rawValue))
        XCTAssertNotEqual(began.scrollingDeltaY, 0)
        XCTAssertTrue(ClipboardHistoryController.isNewInput(began), "Scrolling with the fingers is input")
        XCTAssertTrue(ClipboardHistoryController.isNewInput(try scroll(-3)), "A mouse wheel is input")

        let coasting = try scroll(-8, momentum: Int64(CGMomentumScrollPhase.continuous.rawValue))
        XCTAssertFalse(coasting.momentumPhase.isEmpty)
        XCTAssertFalse(ClipboardHistoryController.isNewInput(coasting), "A flick that is still coasting began before")
        let resting = try scroll(0, phase: Int64(CGScrollPhase.mayBegin.rawValue))
        XCTAssertEqual(resting.scrollingDeltaY, 0)
        XCTAssertFalse(ClipboardHistoryController.isNewInput(resting), "Fingers resting on the trackpad move nothing")

        let keyDown = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        XCTAssertTrue(ClipboardHistoryController.isNewInput(keyDown))
    }

    func testPanelOpensOnTheScreenItIsGiven() {
        let size = CGSize(width: 480, height: 200)
        // Where the panel opened so far on a built-in display: where NSWindow.center() puts it.
        let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 949)
        XCTAssertEqual(ClipboardHistoryLayout.origin(size: size, in: builtIn), CGPoint(x: 516, y: 561))
        // A second display to the right of it and lower down.
        let second = CGRect(x: 1512, y: -300, width: 1920, height: 1055)
        let origin = ClipboardHistoryLayout.origin(size: size, in: second)
        XCTAssertTrue(second.contains(CGRect(origin: origin, size: size)), "The panel lies on the second display")
        XCTAssertEqual(origin.x + size.width / 2, second.midX, "Centred across that display")
        XCTAssertGreaterThan(origin.y + size.height / 2, second.midY, "Somewhat above its middle")
    }
}
