import AppKit
import SwiftUI
import XCTest
@testable import FrogApp

/// The thin, overlay scrollers of Frog are set by a probe that has to sit inside the scroll view.
@MainActor
final class PageScrollbarTests: XCTestCase {
    func testPagesBuiltOnPageScrollGetThinScrollers() throws {
        let (host, window) = place(PageScroll { ForEach(0..<100, id: \.self) { Text("Row \($0)").frame(height: 30) } })
        defer { window.close() }
        try assertThinScrollers(in: host)
    }

    func testTheRulesListGetsThinScrollers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in nil })
        defer { model.shutdown() }
        let (host, window) = place(RulesView().environmentObject(model))
        defer { window.close() }
        try assertThinScrollers(in: host)
    }

    private func assertThinScrollers(in host: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
        let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
        XCTAssertFalse(scrolls.isEmpty, file: file, line: line)
        for scroll in scrolls {
            XCTAssertEqual(scroll.scrollerStyle, .overlay, file: file, line: line)
            XCTAssertTrue(scroll.autohidesScrollers, file: file, line: line)
            XCTAssertEqual(scroll.scrollerInsets.top, 6, "The probe must reach the scroll view it sits in", file: file, line: line)
            XCTAssertEqual(scroll.scrollerInsets.right, 2, file: file, line: line)
        }
    }

    /// The window is never shown. It only gives the hosted scroll view a place to live.
    private func place<Content: View>(_ view: Content) -> (NSHostingView<Content>, NSWindow) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
