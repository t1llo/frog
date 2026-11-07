import AppKit
import SwiftUI
import XCTest
import FrogCore
import FrogUsage
@testable import FrogApp

/// The sidebar's feature list in a short window, where it has to scroll: it rests only on a row's top edge, so no
/// row shows cut in half under the search field or above Models, Features and Settings, which stay pinned under it at
/// every window height.
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
        // Below the visible rows it is hidden, never shown cut above the pinned rows.
        if let below = try AccessibleControls.elements(in: host).first(where: { $0.role == NSAccessibility.Role.button.rawValue && ($0.label ?? $0.title) == "App cleaner" }) {
            let frame = try AccessibleControls.frame(of: below, in: scroll)
            XCTAssertLessThan(scroll.isFlipped ? scroll.bounds.maxY - frame.maxY : frame.minY - scroll.bounds.minY, 0,
                              "App cleaner starts below the visible rows")
        }
        try await choose(.cleaner)
        XCTAssertGreaterThan(y(), scrolled)
        let clearance = try await self.clearance("App cleaner", in: scroll, of: host)
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

    /// In the smallest window, on any page, Models, Features and Settings stay pinned under the list and in view,
    /// and no row shows cut at either edge of the list.
    func testTheSmallestWindowKeepsModelsFeaturesAndSettingsPinnedOnEveryPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root)
        defer { model.shutdown() }
        model.toolkit.select(.settings)
        let size = MainView.minimumSize
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: size.width, height: size.height), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        defer { window.orderOut(nil); window.contentView = nil }
        let host = NSHostingView(rootView: MainView().environmentObject(model))
        window.contentView = host
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(800))
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first { $0.frame.width < 260 })
        let rows = try XCTUnwrap(scroll.documentView).frame.height
        XCTAssertGreaterThan(rows, scroll.contentView.bounds.height + 100, "The list is longer than the window")
        let routes: [ToolkitRoute] = [.settings, .feature(.phone), .feature(.explain), .feature(.scratchpad), .feature(.scripts),
                                      .feature(.usage), .feature(.systemMonitor), .feature(.cleaner), .features, .models, .feature(.writing)]
        for route in routes {
            model.toolkit.select(route)
            try await Task.sleep(for: .milliseconds(400))
            for title in ["Models", "Features", "Settings"] {
                let frame = try AccessibleControls.frame(of: try await AccessibleControls.require(title, role: .button, in: host), in: host)
                let list = scroll.convert(scroll.bounds, to: host)
                XCTAssertTrue(host.bounds.contains(frame), "\(title) is in view on \(route)")
                XCTAssertFalse(list.intersects(frame), "\(title) is pinned under the list on \(route), not in it")
            }
            try await assertNoRowCutAtTheTop(of: scroll, in: host)
            try assertNoRowCutAtTheBottom(of: scroll, in: host)
        }
    }

    /// The pinned rows stay pinned while the list is scrolled all the way down, and the list's last row shows whole.
    func testScrollingToTheEndOfTheListLeavesThePinnedRowsInPlace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root)
        defer { model.shutdown() }
        let size = MainView.minimumSize
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: size.width, height: size.height), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        defer { window.orderOut(nil); window.contentView = nil }
        let host = NSHostingView(rootView: MainView().environmentObject(model))
        window.contentView = host
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(800))
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first { $0.frame.width < 260 })
        let settings = try AccessibleControls.frame(of: try await AccessibleControls.require("Settings", role: .button, in: host), in: host)
        let point = window.convertPoint(toScreen: scroll.convert(NSPoint(x: 60, y: 120), to: nil))
        let screenHeight = try XCTUnwrap(NSScreen.screens.first).frame.height
        for _ in 0..<12 {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -80, wheel2: 0, wheel3: 0))
            event.location = CGPoint(x: point.x, y: screenHeight - point.y)
            window.sendEvent(try XCTUnwrap(NSEvent(cgEvent: event)))
            try await Task.sleep(for: .milliseconds(80))
        }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0, "The list scrolled")
        let after = try AccessibleControls.frame(of: try await AccessibleControls.require("Settings", role: .button, in: host), in: host)
        XCTAssertEqual(after.minY, settings.minY, accuracy: 0.5, "Settings did not move")
        try await assertNoRowCutAtTheTop(of: scroll, in: host)
        try assertNoRowCutAtTheBottom(of: scroll, in: host)
        let last = try AccessibleControls.frame(of: try await AccessibleControls.require("App cleaner", role: .button, in: host), in: scroll)
        XCTAssertTrue(scroll.bounds.contains(last), "Scrolled to the end, the last feature shows whole")
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

    /// The height of the fade at the bottom of the list (`bottomScrollFade`), above the pinned rows.
    private let fade: CGFloat = FrogStyle.sidebarGroupGap

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

    /// No button the list shows is cut by its bottom edge: a row that would be is hidden until all of it fits.
    private func assertNoRowCutAtTheBottom(of scroll: NSScrollView, in host: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
        let bottom = scroll.isFlipped ? scroll.bounds.maxY : scroll.bounds.minY
        for element in AccessibleControls.elements(in: host) where element.role == NSAccessibility.Role.button.rawValue {
            let frame = try AccessibleControls.frame(of: element, in: scroll)
            guard frame.width > 0, frame.minX < scroll.bounds.maxX, frame.maxX > scroll.bounds.minX else { continue }
            let cut = frame.minY < bottom - 0.5 && frame.maxY > bottom + 0.5
            XCTAssertFalse(cut, "\(element.label ?? element.title ?? "A row") is cut by the list's bottom edge", file: file, line: line)
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
