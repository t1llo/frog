import XCTest
import AppKit
import SwiftUI
@testable import FrogApp

@MainActor
final class WindowSwitcherLatencyTests: XCTestCase {
    func testSyntheticNativeRowsPresentationTiming() async {
        let model = WindowSwitcherDisplay()
        let rows = (0..<200).map { index in
            SwitcherWindow(id: UUID(), pid: pid_t(1000 + index), appName: "Fixture \(index)",
                           title: "Synthetic document \(index)", minimized: false, hidden: false)
        }
        let host = NSHostingView(rootView: WindowSwitcherOverlay(model: model, choose: { _ in }, hover: { _ in }))
        host.sizingOptions = []
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: WindowSwitcherLayout.size(windowCount: rows.count)),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        defer { panel.orderOut(nil); panel.close() }
        host.layoutSubtreeIfNeeded()
        let preparation = ContinuousClock.now
        model.preload(.init(windows: rows, current: rows[0].id), in: panel)
        let preparationTime = preparation.duration(to: .now)
        XCTAssertEqual(model.windows, rows)
        XCTAssertFalse(panel.isVisible, "Prewarming must not present or activate the panel")
        let first = ContinuousClock.now
        model.selected = rows[1].id
        panel.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        let cold = first.duration(to: .now)
        panel.orderOut(nil)
        var samples: [Duration] = []
        for index in 0..<20 {
            let start = ContinuousClock.now
            model.selected = rows[index % 10].id
            panel.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            samples.append(start.duration(to: .now))
            panel.orderOut(nil)
        }
        samples.sort()
        print("SWITCHER LATENCY native 200-row presentation: idle preparation \(preparationTime), first \(cold), warm p50 \(samples[10]), p95 \(samples[18])")
        XCTAssertEqual(panel.frame.height, 352, "Rows-only geometry must remain intact")
        XCTAssertLessThan(samples[18], .milliseconds(100), "Warm native presentation must not acquire a discovery-sized stall")
    }

    func testTypingAgedInventoryStillPresentsSynchronously() async {
        let cache = WindowSwitcherCache()
        let window = SwitcherWindow(id: UUID(), pid: 10, appName: "Fixture", title: "Synthetic", minimized: false, hidden: false)
        _ = await cache.update { .init(windows: [window], current: window.id) }
        XCTAssertTrue(cache.needsRefresh(at: .now.advanced(by: .seconds(6))))
        let start = ContinuousClock.now
        let ready = cache.readySnapshot(frontPID: 10)
        print("SWITCHER LATENCY aged cached lookup: \(start.duration(to: .now)); requires blocking discovery: \(ready == nil)")
        XCTAssertEqual(ready?.windows.map(\.id), [window.id], "Typing must not turn the next Command–Tab into a full AX inventory wait")
    }

    func testActivationRequestDoesNotWaitForWindowAXRoundTrips() async {
        var elapsed = 0
        var requestedAt: Int?
        var frontmost = false
        let result = await WindowActivation.perform(raise: {
            elapsed += 100 // A slow application takes one AX timeout to respond.
            return true
        }, request: {
            requestedAt = elapsed
            frontmost = true
            return true
        }, bringForward: { false }, isFrontmost: { frontmost }, pause: {})
        print("SWITCHER LATENCY synthetic activation request: \(requestedAt ?? -1) ms; completion: \(elapsed) ms")
        XCTAssertTrue(result)
        XCTAssertEqual(requestedAt, 0, "Start the application transition before waiting on its AX window")
        XCTAssertEqual(elapsed, 100, "A successful frontmost selection needs one window raise, not two")
    }

    func testSameApplicationSelectionRaisesOnceWithoutActivation() async {
        var raises = 0
        let result = await WindowActivation.perform(raise: { raises += 1; return true }, request: {
            XCTFail("Same-app switching must not activate the app again"); return false
        }, bringForward: { XCTFail("Unexpected fallback"); return false }, isFrontmost: { true }, pause: {})
        XCTAssertTrue(result)
        XCTAssertEqual(raises, 1)
    }
}
