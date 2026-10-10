import AppKit
import SwiftUI
import XCTest
@testable import FrogApp

@MainActor final class SystemMonitorViewTests: XCTestCase {
    func testSystemTabAndBatteryHeightTransitionsResizeNativeMenuWithoutBottomStrip() async throws {
        _ = NSApplication.shared
        let state = MonitorMenuFixtureState()
        let host = NSHostingView(rootView: MonitorMenuFixtureView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 292, height: 250), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await settle(host)
        let frogHeight = window.frame.height
        let top = window.frame.maxY
        state.tab = .system
        try await settle(host)
        let systemHeight = window.frame.height
        XCTAssertGreaterThan(systemHeight, frogHeight + 100)
        XCTAssertEqual(window.frame.width, 292, accuracy: 0.5)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5)
        XCTAssertEqual(systemHeight, host.fittingSize.height, accuracy: 1)
        XCTAssertLessThan(systemHeight, 520, "Overview must remain compact")
        try capture(host, suffix: "battery")

        state.snapshot.power.batteryFlow = .drawing(watts: 18)
        state.snapshot.power.charging = false
        state.snapshot.power.source = "Battery"
        try await settle(host)
        XCTAssertEqual(window.frame.height, systemHeight, accuracy: 0.5)
        XCTAssertEqual(window.frame.height, host.fittingSize.height, accuracy: 1)
        try capture(host, suffix: "battery-draw")

        state.snapshot.power.batteryPercent = nil
        state.snapshot.power.batteryFlow = nil
        state.snapshot.power.source = "Power adapter"
        state.snapshot.gpu = .unavailable
        try await settle(host)
        XCTAssertLessThan(window.frame.height, systemHeight)
        XCTAssertEqual(window.frame.height, host.fittingSize.height, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5)
        try capture(host, suffix: "desktop")

        state.snapshot = .init(cpu: .unavailable, gpu: .unavailable, diskRead: .unavailable, diskWrite: .unavailable)
        try await settle(host)
        XCTAssertEqual(window.frame.height, host.fittingSize.height, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5)
        try capture(host, suffix: "unavailable")

        state.tab = .frog
        try await settle(host)
        XCTAssertEqual(window.frame.height, frogHeight, accuracy: 0.5)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5)
    }

    func testNativeWindowOrderOutStopsCollectorEvenIfSwiftUIViewStaysMounted() async throws {
        _ = NSApplication.shared
        let monitor = SystemMonitor(sampler: VisibleMonitorFixture(), interval: .milliseconds(5))
        monitor.configure(enabled: true)
        let host = NSHostingView(rootView: SystemMonitorView(monitor: monitor).frame(width: 282).fixedSize(horizontal: false, vertical: true))
        let window = MonitorVisibilityFixtureWindow(contentRect: NSRect(x: 80, y: 80, width: 282, height: 350), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        defer { monitor.stop(); window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        for _ in 0..<100 where !monitor.isSampling { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(monitor.isSampling)
        window.orderOut(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        for _ in 0..<100 where monitor.isSampling { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(monitor.isSampling)
        XCTAssertTrue(monitor.cpuHistory.isEmpty)
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        for _ in 0..<100 where !monitor.isSampling { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(monitor.isSampling)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        for _ in 0..<100 where monitor.isSampling { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(monitor.isSampling)
    }

    private func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
    }

    private func capture(_ view: NSView, suffix: String) throws {
        guard let path = ProcessInfo.processInfo.environment["FROG_TEST_SYSTEM_SNAPSHOT"] else { return }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path + "-" + suffix + ".png"))
    }
}

/// XCTest windows can be fully occluded by the runner's Space even after order
/// front. Fix only that external input; native isVisible, mounting and order-out
/// remain real. Explicit notifications model WindowServer's visibility changes.
@MainActor private final class MonitorVisibilityFixtureWindow: NSWindow {
    override var occlusionState: NSWindow.OcclusionState { .visible }
}

private actor VisibleMonitorFixture: SystemMonitorSampling {
    func sample(reset: Bool) async -> SystemMonitorSnapshot { .init(cpu: .value(0.23), gpu: .value(0.1)) }
}

@MainActor private final class MonitorMenuFixtureState: ObservableObject {
    @Published var tab: SystemMonitorMenuTab = .frog
    @Published var snapshot = SystemMonitorSnapshot(
        cpu: .value(0.23), gpu: .value(0.1),
        diskCapacity: .init(total: 1_000_000_000_000, available: 420_000_000_000),
        diskRead: .value(4_200_000), diskWrite: .value(920_000),
        power: .init(source: "Power adapter", batteryPercent: 83, charging: true, thermal: "Normal", lowPower: false, batteryFlow: .charging(watts: 24)))
}

private struct MonitorMenuFixtureView: View {
    @ObservedObject var state: MonitorMenuFixtureState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Frog").fontWeight(.semibold); Spacer(); Text("Ready").foregroundStyle(FrogStyle.muted) }
                .padding(.horizontal, 8).padding(.vertical, 9)
            Divider().padding(.horizontal, 8)
            SystemMonitorMenuSelector(selection: $state.tab)
            if state.tab == .system {
                SystemMonitorOverview(snapshot: state.snapshot,
                    cpuHistory: (0..<30).map { 0.2 + Double($0 % 7) / 30 },
                    gpuHistory: (0..<30).map { 0.05 + Double($0 % 4) / 25 })
            } else {
                Text("Stay awake").padding(12)
                Text("Command bar").padding(12)
            }
            Divider().padding(.horizontal, 8)
            Text("Open Frog").padding(9)
            Divider().padding(.horizontal, 8)
            HStack { Text("v1.0.0"); Spacer(); Text("Quit Frog") }
                .font(.system(size: 10)).foregroundStyle(FrogStyle.muted).padding(9)
        }.padding(5).frame(width: 292).fixedSize(horizontal: false, vertical: true)
            .font(.system(size: 12)).foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).controlSize(.small)
            .frogPanel().background(MenuWindowSizing())
    }
}
