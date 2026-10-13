import AppKit
import XCTest
@testable import FrogApp

@MainActor
final class WindowClosingTests: XCTestCase {
    /// The notification center matches on the sender, so plain objects stand in for the windows.
    func testOnlyTheObservedWindowClosingIsReported() {
        var closed = 0
        let view = WindowClosing.ObserverView { closed += 1 }
        let own = NSObject(), other = NSObject()
        view.observe(own)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: other)
        XCTAssertEqual(closed, 0, "Another window of the process closing, such as an update window, is not this page closing")
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: own)
        XCTAssertEqual(closed, 1)

        view.observe(other)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: own)
        XCTAssertEqual(closed, 1, "A view moved to another window follows that window")
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: other)
        XCTAssertEqual(closed, 2)

        view.observe(nil)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: other)
        XCTAssertEqual(closed, 2, "A view taken out of its window stops listening")
    }
}
