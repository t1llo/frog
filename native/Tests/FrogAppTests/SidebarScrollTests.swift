import AppKit
import SwiftUI
import XCTest
import FrogCore
import FrogUsage
@testable import FrogApp

/// The sidebar's feature list in a short window, where it has to scroll: it rests only on a row's top edge, so no
/// row shows cut in half under the search field, and Models, Features and Settings scroll at its end.
@MainActor
final class SidebarScrollTests: XCTestCase {
    func testChoosingAFeatureInViewLeavesTheListWhereItIsAndOneOutOfViewScrollsToTheNextWholeRow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root)
        defer { model.shutdown() }
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 520), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        defer { window.orderOut(nil); window.contentView = nil }
        window.contentView = NSHostingView(rootView: MainView().environmentObject(model))
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(600))
        let scroll = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSScrollView }.first { $0.frame.width < 260 })
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
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertGreaterThan(y(), 0, "The scroll wheel scrolls the list")
        try await assertNoRowCutAtTheTop(of: scroll, in: window.contentView!)
        let scrolled = y()
        // App cleaner is below the visible rows, with or without the Finish setup button under the list:
        // the list scrolls until the row shows clear of the bottom fade, not until it is centred.
        let host = try XCTUnwrap(window.contentView)
        var clearance = try await self.clearance("App cleaner", in: scroll, of: host)
        XCTAssertLessThan(clearance, 0, "App cleaner starts below the visible rows")
        try await choose(.cleaner)
        XCTAssertGreaterThan(y(), scrolled)
        clearance = try await self.clearance("App cleaner", in: scroll, of: host)
        XCTAssertGreaterThanOrEqual(clearance, fade - 1, "The chosen row shows clear of the bottom fade")
        XCTAssertLessThan(clearance, fade + 40, "The list scrolls to the next row edge, not until the row is centred")
        try await assertNoRowCutAtTheTop(of: scroll, in: host)
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
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first { $0.frame.width < 260 })
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0, "The list scrolled to the row")
        let clearance = try await self.clearance("App cleaner", in: scroll, of: host)
        XCTAssertGreaterThanOrEqual(clearance, fade - 1, "The row shows clear of the bottom fade")
        try await assertNoRowCutAtTheTop(of: scroll, in: host)
    }

    /// In the short window Settings scrolls at the end of the list, and scrolled to the end the top row is whole too.
    func testTheEndOfAShortListShowsSettingsAndWholeRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root)
        defer { model.shutdown() }
        model.toolkit.select(.settings)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 520), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        defer { window.orderOut(nil); window.contentView = nil }
        let host = NSHostingView(rootView: MainView().environmentObject(model))
        window.contentView = host
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(800))
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first { $0.frame.width < 260 })
        let settings = try AccessibleControls.frame(of: try await AccessibleControls.require("Settings", role: .button, in: host), in: scroll)
        XCTAssertTrue(scroll.bounds.contains(settings), "Settings is in the scrolling list, in view")
        try await assertNoRowCutAtTheTop(of: scroll, in: host)
    }

    /// In a tall window everything fits: nothing scrolls, and Settings is pinned under the list.
    func testATallWindowPinsSettingsUnderAListThatFits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root)
        defer { model.shutdown() }
        let height = min(1_200, (NSScreen.screens.first?.visibleFrame.height ?? 900) - 40)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 20, width: 900, height: height), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        defer { window.orderOut(nil); window.contentView = nil }
        let host = NSHostingView(rootView: MainView().environmentObject(model))
        window.contentView = host
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(800))
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first { $0.frame.width < 260 })
        let rows = try XCTUnwrap(scroll.documentView).frame.height
        try XCTSkipIf(rows > height - 200, "The screen is too short for every row to fit")
        XCTAssertLessThanOrEqual(rows, scroll.contentView.bounds.height + 0.5, "The list fits")
        let settings = try AccessibleControls.frame(of: try await AccessibleControls.require("Settings", role: .button, in: host), in: scroll)
        XCTAssertFalse(scroll.bounds.intersects(settings), "Settings is pinned under the list")
    }

    /// The height of the fade at the bottom of the list (`bottomScrollFade`) once it scrolls over the panel's edge.
    private let fade: CGFloat = 24

    /// No button in the list is cut by its top edge: the list rests on a row edge.
    private func assertNoRowCutAtTheTop(of scroll: NSScrollView, in host: NSView, file: StaticString = #filePath, line: UInt = #line) async throws {
        _ = try await AccessibleControls.element("Settings", role: .button, in: host)
        let top = scroll.isFlipped ? scroll.bounds.minY : scroll.bounds.maxY
        for element in AccessibleControls.elements(in: host) where element.role == NSAccessibility.Role.button.rawValue {
            let frame = try AccessibleControls.frame(of: element, in: scroll)
            guard frame.width > 0, frame.minX < scroll.bounds.maxX, frame.maxX > scroll.bounds.minX else { continue }
            let cut = scroll.isFlipped ? frame.minY < top - 0.5 && frame.maxY > top + 0.5 : frame.maxY > top + 0.5 && frame.minY < top - 0.5
            XCTAssertFalse(cut, "\(element.label ?? element.title ?? "A row") is cut by the list's top edge", file: file, line: line)
        }
    }

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
