import XCTest
@testable import FrogApp

@MainActor
final class WindowSwitcherCacheTests: XCTestCase {
    func testPartialInventoryUpdatesRowsButDoesNotPretendDiscoveryIsFresh() async {
        let cache = WindowSwitcherCache()
        let old = window("Old", pid: 10)
        _ = await cache.update { .init(windows: [old], current: old.id) }
        let latest = window("New", pid: 20)
        let result = await cache.update { .init(windows: [latest, old], current: nil, completeness: .partial) }
        XCTAssertEqual(result?.windows.map(\.id), [latest.id, old.id])
        XCTAssertEqual(cache.readySnapshot(frontPID: 20)?.windows.map(\.id), [latest.id, old.id])
        XCTAssertTrue(cache.needsRefresh(), "An explicit invocation should retry an incomplete inventory without withholding its rows")
        cache.noteFocused(old.id)
        XCTAssertEqual(cache.snapshot?.completeness, .partial)
        _ = await cache.update { .init(windows: [], current: nil, completeness: .cancelled) }
        XCTAssertEqual(cache.snapshot?.windows.map(\.id), [old.id, latest.id])
        _ = await cache.update { .init(windows: [], current: nil, completeness: .unavailable) }
        XCTAssertEqual(cache.snapshot?.windows.map(\.id), [old.id, latest.id])
        _ = await cache.update { .init(windows: [], current: nil) }
        XCTAssertEqual(cache.readySnapshot(frontPID: nil)?.windows.count, 0)
    }

    func testAnInventoryThatAgesWhileTypingPresentsImmediatelyAndRequestsFreshDiscovery() async {
        let cache = WindowSwitcherCache()
        let old = window("Old window", pid: 10)
        _ = await cache.update { .init(windows: [old], current: old.id) }
        XCTAssertNotNil(cache.readySnapshot(frontPID: 10))
        XCTAssertTrue(cache.needsRefresh(at: .now.advanced(by: .seconds(6))))
        XCTAssertNotNil(cache.readySnapshot(frontPID: 10))
        let new = window("New window", pid: 10)
        _ = await cache.update { .init(windows: [new], current: new.id) }
        XCTAssertEqual(cache.readySnapshot(frontPID: 10)?.windows.map(\.id), [new.id])
        XCTAssertFalse(cache.needsRefresh())
    }

    func testWarmRowsExcludeDepartedOwnersWithoutWaitingForDiscovery() async {
        let cache = WindowSwitcherCache()
        let departed = window("Departed", pid: 10), live = window("Live", pid: 20)
        _ = await cache.update { .init(windows: [departed, live], current: departed.id) }
        let ready = cache.readySnapshot(frontPID: 20, livePIDs: [20])
        XCTAssertEqual(ready?.windows.map(\.id), [live.id])
        XCTAssertEqual(ready?.current, live.id)
    }

    func testQuickSwitchReturnsToThePreviousAppBeforeTheFrontOneWasRecorded() async throws {
        let cache = WindowSwitcherCache()
        let editor = window("Editor", pid: 10), browser = window("Browser", pid: 20), other = window("Other", pid: 30)
        _ = await cache.update { .init(windows: [editor, browser, other], current: editor.id) }
        // The browser came forward, but typing retired its activation and paused the scans.
        let ready = try XCTUnwrap(cache.readySnapshot(frontPID: 20))
        XCTAssertEqual(ready.windows.map(\.id), [browser.id, editor.id, other.id])
        var session = WindowSwitchSession<UUID>()
        session.begin(windows: ready.windows.map(\.id), current: ready.current, backwards: false)
        XCTAssertEqual(session.selected, editor.id, "One Command-Tab must go back to the app used before, not to a third one")
        cache.noteFocused(other.id)
        XCTAssertEqual(cache.readySnapshot(frontPID: 30)?.windows.map(\.id), [other.id, browser.id, editor.id],
                       "The browser's turn in front stays in the order")
    }

    func testQuickSwitchBackLeavesTheChosenWindowNotAnotherWindowOfItsApp() async throws {
        let cache = WindowSwitcherCache()
        let editor = window("Editor", pid: 10), inbox = window("Inbox", pid: 20), draft = window("Draft", pid: 20)
        _ = await cache.update { .init(windows: [editor, inbox, draft], current: editor.id) }
        // The draft was chosen, and the next Command-Tab retired its activation unrecorded.
        cache.noteChosen(draft.id)
        XCTAssertEqual(cache.readySnapshot(frontPID: 10)?.current, editor.id, "Its app has not come forward yet")
        let back = try XCTUnwrap(cache.readySnapshot(frontPID: 20))
        XCTAssertEqual(back.current, draft.id)
        XCTAssertEqual(back.windows.map(\.id), [draft.id, editor.id, inbox.id])
        let again = try XCTUnwrap(cache.readySnapshot(frontPID: 10))
        var session = WindowSwitchSession<UUID>()
        session.begin(windows: again.windows.map(\.id), current: again.current, backwards: false)
        XCTAssertEqual(session.selected, draft.id, "Toggling returns to the draft, not to the app's other window")
    }

    func testRecordedFocusReplacesTheChosenWindow() async {
        let cache = WindowSwitcherCache()
        let editor = window("Editor", pid: 10), inbox = window("Inbox", pid: 20), draft = window("Draft", pid: 20)
        _ = await cache.update { .init(windows: [editor, inbox, draft], current: editor.id) }
        cache.noteChosen(draft.id)
        cache.noteFocused(inbox.id)
        XCTAssertEqual(cache.readySnapshot(frontPID: 20)?.current, inbox.id, "The user clicked another window afterwards")
        cache.noteChosen(draft.id)
        cache.forgetChosen(draft.id)
        XCTAssertEqual(cache.readySnapshot(frontPID: 20)?.current, inbox.id, "macOS refused the activation")
        cache.noteChosen(draft.id)
        _ = await cache.update { .init(windows: [inbox, editor, draft], current: inbox.id) }
        XCTAssertEqual(cache.readySnapshot(frontPID: 20)?.current, inbox.id, "A scan read the focused window itself")
    }

    func testRefreshingHeldInventoryPreservesCyclingOrderAndSelection() {
        var session = WindowSwitchSession<Int>()
        session.begin(windows: [1, 2, 3], current: 1, backwards: false)
        session.reconcile(windows: [4, 3, 2, 1])
        XCTAssertEqual(session.windows, [1, 2, 3, 4])
        XCTAssertEqual(session.selected, 2)
        session.step(backwards: false)
        XCTAssertEqual(session.selected, 3)
        session.reconcile(windows: [4, 2])
        XCTAssertEqual(session.windows, [2, 4])
        XCTAssertEqual(session.selected, 2)
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
