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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root)
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
        // the list scrolls until the row shows clear of the bottom fade, not until it is centred.
        let host = try XCTUnwrap(window.contentView)
        var clearance = try await self.clearance("App cleaner", in: scroll, of: host)
        XCTAssertLessThan(clearance, 0, "App cleaner starts below the visible rows")
        try await choose(.cleaner)
        XCTAssertGreaterThan(y(), 90)
        clearance = try await self.clearance("App cleaner", in: scroll, of: host)
        XCTAssertGreaterThanOrEqual(clearance, fade - 1, "The chosen row shows clear of the bottom fade")
        XCTAssertLessThan(clearance, fade + 12, "The list scrolls just enough, not until the row is centred")
        let revealed = y()
        try await choose(.cleaner)
        XCTAssertEqual(y(), revealed, "Choosing the row again does not move the list")
    }

    /// A window that opens on a page whose row is out of view shows that row clear of the fade too.
    func testAWindowOpeningOnAFeatureOutOfViewShowsItsRow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root)
        defer { model.shutdown() }
        model.toolkit.select(.feature(.cleaner))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 520), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        defer { window.orderOut(nil); window.contentView = nil }
        let host = NSHostingView(rootView: MainView().environmentObject(model))
        window.contentView = host
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(600))
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first { $0.frame.width < 200 })
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0, "The list scrolled to the row")
        let clearance = try await self.clearance("App cleaner", in: scroll, of: host)
        XCTAssertGreaterThanOrEqual(clearance, fade - 1, "The row shows clear of the bottom fade")
    }

    /// The height of the fade at the bottom of the list (`bottomScrollFade`).
    private let fade: CGFloat = 20

    /// How far a row sits above the bottom edge of the list; negative while it is below it.
    private func clearance(_ row: String, in scroll: NSScrollView, of host: NSView) async throws -> CGFloat {
        let frame = try AccessibleControls.frame(of: try await AccessibleControls.require(row, role: .button, in: host), in: scroll)
        return scroll.isFlipped ? scroll.bounds.maxY - frame.maxY : frame.minY - scroll.bounds.minY
    }

    /// Every feature on, so the list is long.
    private func makeModel(_ root: URL) throws -> AppModel {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var configuration = Configuration()
        for feature in FeatureID.allCases { configuration.preferences.setFeature(feature, enabled: true) }
        try ConfigurationStore(directory: root).save(configuration)
        let usage = UsageDashboardModel(defaults: temporaryDefaults(), fixtureRoot: root.appendingPathComponent("fixtures"))
        return AppModel(dataDirectory: root, registerShortcuts: false, readKey: { _ in nil }, readAccessibility: { true },
                        toolkit: Toolkit(makeUsage: { usage }, showsUsageStatusItem: false),
                        systemStatusTick: { try await Task.sleep(for: .seconds(3_600)) })
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
}
