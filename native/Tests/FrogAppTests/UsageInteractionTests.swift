import AppKit
import Combine
import XCTest
import FrogCore
import FrogTestSupport
import FrogUsage
@testable import FrogApp

@MainActor final class UsageInteractionTests: XCTestCase {
    func testOutsideClickClosesUsagePopoverAndInsideClickKeepsItOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = temporaryDefaults()
        defer { try? FileManager.default.removeItem(at: root) }
        let usage = UsageDashboardModel(defaults: defaults, fixtureRoot: root)
        let controller = UsageStatusItemController(usage: usage, openDashboard: {})
        defer { controller.stop() }
        let outside = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 160, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        outside.isReleasedWhenClosed = false
        outside.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 100))
        outside.orderFront(nil)
        defer { outside.orderOut(nil) }
        let anchor = NSWindow(contentRect: NSRect(x: 400, y: 500, width: 50, height: 30), styleMask: .borderless, backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 30))
        anchor.orderFront(nil)
        defer { anchor.orderOut(nil) }
        controller.showPopup(relativeTo: try XCTUnwrap(anchor.contentView))
        for _ in 0..<100 where !controller.isPopupShown { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(controller.isPopupShown)
        let window = try XCTUnwrap(controller.popup)
        func click(_ target: NSWindow) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 15, y: 15), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                NSApplication.shared.sendEvent(event)
            }
        }
        try click(window)
        XCTAssertTrue(controller.isPopupShown, "Interacting inside must not dismiss the popup")
        try click(outside)
        for _ in 0..<100 where controller.isPopupShown { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(controller.isPopupShown, "Clicking another Frog window must dismiss the popup too")

        // Same surface as Frog's menu-bar popup: a plain panel beneath the item, no popover arrow.
        var opened: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: .frogMenuPopupWillOpen, object: nil, queue: nil) { note in
            (note.object as? String).map { opened.append($0) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let anchorView = try XCTUnwrap(anchor.contentView)
        controller.showPopup(relativeTo: anchorView)
        XCTAssertEqual(opened, [UsageStatusPopover.popupName], "Opening tells Frog's own popup to close")
        let panel = try XCTUnwrap(controller.popup)
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.frame.width, UsageStatusPopover.width)
        XCTAssertEqual(panel.frame.minX, anchor.frame.minX, "Left-aligned with the status item")
        XCTAssertEqual(panel.frame.maxY, anchor.frame.minY - 5)
        NotificationCenter.default.post(name: .frogMenuPopupWillOpen, object: UsageStatusPopover.popupName)
        XCTAssertTrue(controller.isPopupShown)
        NotificationCenter.default.post(name: .frogMenuPopupWillOpen, object: FrogStatusMenu.popupName)
        for _ in 0..<100 where controller.isPopupShown { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(controller.isPopupShown, "Opening Frog's popup closes this one")
    }

    func testMenuBarReadoutFallsBackToThePeriodEstimateInsteadOfOnlyAName() {
        let name = UsageStatusReadout.image(provider: "Claude", windows: [])
        let estimate = UsageStatusReadout.Estimate(range: "7d", value: "$185")
        let fallback = UsageStatusReadout.image(provider: "Claude", windows: [], estimate: estimate)
        XCTAssertTrue(fallback.isTemplate)
        XCTAssertNotEqual(fallback.size.width, name.size.width)
        XCTAssertEqual(UsageStatusReadout.description(provider: "Claude", windows: [], estimate: estimate),
                       "LLM usage · Claude\nAPI estimate, last 7d: $185")
    }
}
