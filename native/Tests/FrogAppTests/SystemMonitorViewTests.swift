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

    func testNativeWindowOrderOutReturnsToRecordingOutOfSightEvenIfSwiftUIViewStaysMounted() async throws {
        _ = NSApplication.shared
        let sampler = VisibleMonitorFixture()
        let monitor = SystemMonitor(sampler: sampler, interval: .milliseconds(5), backgroundInterval: .milliseconds(5))
        monitor.configure(enabled: true)
        let host = NSHostingView(rootView: SystemMonitorView(monitor: monitor, presenter: .frogMenu).frame(width: 282).fixedSize(horizontal: false, vertical: true))
        let window = MonitorVisibilityFixtureWindow(contentRect: NSRect(x: 80, y: 80, width: 282, height: 350), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        defer { monitor.stop(); window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        try await waitUntil { await sampler.full == true }
        XCTAssertFalse(monitor.history.isEmpty)
        window.orderOut(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        try await waitUntil { await sampler.full == false }
        XCTAssertTrue(monitor.isSampling, "Closing the menu keeps the CPU and GPU recording")
        let shown = monitor.history.count
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(monitor.history.count, shown, "Nothing is published to a view nobody sees")
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        try await waitUntil { await sampler.full == true }
        XCTAssertGreaterThan(monitor.history.count, shown, "What was recorded out of sight is in the graph")
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        try await waitUntil { await sampler.full == false }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for monitor state")
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
    /// Whether the newest sample was a full one, as taken for a visible view.
    private(set) var full: Bool?
    func sample(reset: Bool, full: Bool) async -> SystemMonitorSnapshot {
        self.full = full
        return .init(cpu: .value(0.23), gpu: .value(0.1))
    }
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
    /// Ten minutes of samples, with a line only for the readings the snapshot has.
    private var history: [SystemMonitorSample] {
        let cpu = state.snapshot.cpu.value != nil, gpu = state.snapshot.gpu.value != nil
        return (0..<120).map { index in
            let step = Double(index)
            let load: Double = 0.28 + 0.2 * sin(step / 9) + 0.06 * sin(step / 2)
            let render: Double = 0.12 + 0.08 * sin(step / 14 + 1)
            return SystemMonitorSample(time: Date(timeIntervalSinceReferenceDate: step * 5), cpu: cpu ? load : nil, gpu: gpu ? render : nil)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Frog").fontWeight(.semibold); Spacer(); SystemMonitorMenuSelector(selection: $state.tab) }
                .padding(.horizontal, 8).frame(height: 42)
            if state.tab == .system {
                SystemMonitorOverview(snapshot: state.snapshot, history: history)
            } else {
                Text("Stay awake").padding(12)
                Text("Command bar").padding(12)
            }
            Text("Open Frog").padding(9)
            Divider().padding(.horizontal, 8)
            HStack { Text("v1.0.0"); Spacer(); Text("Quit Frog") }
                .font(.system(size: 10)).foregroundStyle(FrogStyle.muted).padding(9)
        }.padding(5).frame(width: 292).fixedSize(horizontal: false, vertical: true)
            .font(.system(size: 12)).foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).controlSize(.small)
            .frogPanel().background(MenuWindowSizing())
    }
}
