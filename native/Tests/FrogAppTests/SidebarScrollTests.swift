import AppKit
import SwiftUI
import XCTest
import FrogCore
import FrogUsage
@testable import FrogApp

/// The sidebar's feature list in a short window, where it has to scroll.
@MainActor
final class SidebarScrollTests: XCTestCase {
    func testChoosingAFeatureInViewLeavesTheListWhereItIsAndOneOutOfViewScrollsJustEnough() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var configuration = Configuration()
        for feature in FeatureID.allCases { configuration.preferences.setFeature(feature, enabled: true) }
        try ConfigurationStore(directory: root).save(configuration)
        let usage = UsageDashboardModel(defaults: temporaryDefaults(), fixtureRoot: root.appendingPathComponent("fixtures"))
        let model = AppModel(dataDirectory: root, registerShortcuts: false, readKey: { _ in nil }, readAccessibility: { true },
                             toolkit: Toolkit(makeUsage: { usage }, showsUsageStatusItem: false),
                             systemStatusTick: { try await Task.sleep(for: .seconds(3_600)) })
        defer { model.shutdown() }
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 520), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        defer { window.orderOut(nil); window.contentView = nil }
        window.contentView = NSHostingView(rootView: MainView().environmentObject(model))
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(600))
        let scroll = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSScrollView }.first { $0.frame.width < 200 })
        func y() -> CGFloat { scroll.contentView.bounds.origin.y }
        func choose(_ feature: FeatureID) async throws {
            model.toolkit.select(.feature(feature))
            try await Task.sleep(for: .milliseconds(400))
        }
        let rows = try XCTUnwrap(scroll.documentView).frame.height
        XCTAssertGreaterThan(rows, scroll.contentView.bounds.height + 100, "The window is short enough for the list to scroll")
        XCTAssertEqual(scroll.scrollerStyle, .overlay)
        try await choose(.clipboard)
        XCTAssertEqual(y(), 0, "A row in view does not move the list")
        try await choose(.writing)
        XCTAssertEqual(y(), 0)

        let point = window.convertPoint(toScreen: scroll.convert(NSPoint(x: 60, y: 120), to: nil))
        let screenHeight = try XCTUnwrap(NSScreen.screens.first).frame.height
        for _ in 0..<3 {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -30, wheel2: 0, wheel3: 0))
            event.location = CGPoint(x: point.x, y: screenHeight - point.y)
            window.sendEvent(try XCTUnwrap(NSEvent(cgEvent: event)))
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTAssertEqual(y(), 90, "The scroll wheel scrolls the list")
        // App cleaner is below the visible rows, with or without the Finish setup button under the list:
        // the list scrolls until it shows, not until it is centred.
        try await choose(.cleaner)
        XCTAssertGreaterThan(y(), 90)
        XCTAssertLessThan(y(), 190)
        try await choose(.cleaner)
        XCTAssertLessThan(y(), 190)
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
}
