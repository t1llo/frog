import AppKit
import XCTest
@testable import FrogApp

@MainActor final class MenuWindowSizingTests: XCTestCase {
    func testConditionalMenuRowsResizeNativeWindowAndKeepTopEdge() async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 292, height: 326), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 292, height: 326))
        let measure = MenuWindowSizing.MenuSizeView(frame: host.bounds)
        host.addSubview(measure); window.contentView = host
        let top = window.frame.maxY
        // Match the real MenuBarExtra regression: async state removes a status row.
        measure.setFrameSize(NSSize(width: 292, height: 252))
        for _ in 0..<100 where window.frame.height != 252 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(window.frame.height, 252)
        XCTAssertEqual(window.frame.maxY, top)
        // A new notice can grow it again; intermediate layouts must not win.
        measure.setFrameSize(NSSize(width: 292, height: 280))
        measure.setFrameSize(NSSize(width: 292, height: 310))
        for _ in 0..<100 where window.frame.height != 310 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(window.frame.height, 310)
        XCTAssertEqual(window.frame.maxY, top)
        XCTAssertNil(measure.hitTest(NSPoint(x: 10, y: 10)), "Sizing must not intercept menu buttons")
    }
}
