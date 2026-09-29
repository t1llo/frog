import AppKit
import SwiftUI
import XCTest
@testable import FrogApp

@MainActor
final class ScrollAppearanceTests: XCTestCase {
    func testScrollbarAppearanceDoesNotChangeAfterTheFirstFrame() async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ScrollView {
            VStack { ForEach(0..<100, id: \.self) { Text("Row \($0)").frame(height: 30) } }.minimalScrollbars()
        })
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        window.orderFront(nil); host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
        let firstWidth = scroll.contentSize.width
        let firstInsets = scroll.scrollerInsets
        XCTAssertEqual(scroll.scrollerStyle, .overlay)
        XCTAssertTrue(scroll.autohidesScrollers)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(scroll.scrollerStyle, .overlay)
        XCTAssertEqual(scroll.contentSize.width, firstWidth)
        XCTAssertEqual(scroll.scrollerInsets.top, firstInsets.top)
        XCTAssertEqual(scroll.scrollerInsets.right, firstInsets.right)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
