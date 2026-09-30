import XCTest
@testable import FrogApp

@MainActor
final class WindowSwitcherCacheTests: XCTestCase {
    func testAnInventoryThatAgesWhileTypingRequiresFreshDiscovery() async {
        let cache = WindowSwitcherCache()
        let old = window("Old window", pid: 10)
        _ = await cache.update { .init(windows: [old], current: old.id) }
        XCTAssertNotNil(cache.readySnapshot(frontPID: 10))
        XCTAssertNil(cache.readySnapshot(frontPID: 10, at: .now.advanced(by: .seconds(6))))
        let new = window("New window", pid: 10)
        _ = await cache.update { .init(windows: [new], current: new.id) }
        XCTAssertEqual(cache.readySnapshot(frontPID: 10)?.windows.map(\.id), [new.id])
    }

    func testCachedInventoryIsImmediatelyAvailableDuringSlowRefresh() async throws {
        let cache = WindowSwitcherCache()
        let first = window("First", pid: 10)
        let second = window("Second", pid: 20)
        _ = await cache.update { .init(windows: [first, second], current: first.id) }
        let gate = SnapshotGate()
        let pending = Task { await cache.update { await gate.wait() } }
        await gate.waitUntilStarted()
        // The invocation reads memory synchronously; it does not await the AX scan.
        XCTAssertEqual(cache.readySnapshot(frontPID: 10)?.windows.map(\.id), [first.id, second.id])
        cache.noteFocused(second.id)
        XCTAssertEqual(cache.readySnapshot(frontPID: 20)?.windows.first?.id, second.id)
        cache.cancelRefresh()
        await gate.finish(.init(windows: [], current: nil))
        _ = await pending.value
        XCTAssertEqual(cache.snapshot?.windows.count, 2, "Cancelled refresh must not replace the warm inventory")
    }

    func testQuickTapNeverShowsPanelIncludingLateDataOrTimer() {
        var presentation = WindowSwitchPresentation()
        presentation.begin(1, ready: false)
        presentation.release(1)
        presentation.elapsed(1)
        presentation.loaded(1)
        XCTAssertFalse(presentation.shouldShow)
        presentation.begin(2, ready: true)
        presentation.release(2)
        presentation.elapsed(2)
        XCTAssertFalse(presentation.shouldShow)
    }

    func testHeldShortcutShowsOnlyPopulatedInventoryAndIgnoresOlderTimer() {
        var presentation = WindowSwitchPresentation()
        presentation.begin(1, ready: false)
        presentation.elapsed(1)
        XCTAssertFalse(presentation.shouldShow)
        presentation.loaded(1)
        XCTAssertTrue(presentation.shouldShow)
        presentation.cancel(1)
        presentation.begin(2, ready: true)
        presentation.elapsed(1)
        XCTAssertFalse(presentation.shouldShow)
        presentation.elapsed(2)
        XCTAssertTrue(presentation.shouldShow)
    }

    private func window(_ title: String, pid: pid_t) -> SwitcherWindow {
        SwitcherWindow(id: UUID(), pid: pid, appName: "Fixture", title: title, minimized: false, hidden: false)
    }
}

private actor SnapshotGate {
    private var continuation: CheckedContinuation<WindowCatalog.Snapshot, Never>?
    func wait() async -> WindowCatalog.Snapshot { await withCheckedContinuation { continuation = $0 } }
    func waitUntilStarted() async { while continuation == nil { await Task.yield() } }
    func finish(_ snapshot: WindowCatalog.Snapshot) { continuation?.resume(returning: snapshot); continuation = nil }
}
