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

    func testFocusReadBegunBeforeAWindowWasChosenDoesNotReplaceTheChoice() async {
        let cache = WindowSwitcherCache()
        let editor = window("Editor", pid: 10), inbox = window("Inbox", pid: 20), draft = window("Draft", pid: 20)
        _ = await cache.update { .init(windows: [editor, inbox, draft], current: editor.id) }
        // The monitor asks which window is in front. Before a slow answer arrives the list
        // is opened and released on Draft, and a keystroke retires the activation unrecorded.
        let asked = cache.turn
        _ = cache.readySnapshot(frontPID: 10)
        cache.noteChosen(draft.id)
        cache.noteFocused(editor.id, readAt: asked)
        XCTAssertEqual(cache.readySnapshot(frontPID: 20)?.current, draft.id, "The answer is older than the choice, not a click made after it")
        // An answer with nothing in between counts as before.
        cache.noteFocused(inbox.id, readAt: cache.turn)
        XCTAssertEqual(cache.readySnapshot(frontPID: 20)?.current, inbox.id)
    }

    func testWindowClickedInTheFrontAppWithoutARecordedFocusIsTheOneLeft() async throws {
        let cache = WindowSwitcherCache()
        let inbox = window("Inbox", pid: 20), editor = window("Editor", pid: 10), draft = window("Draft", pid: 20)
        _ = await cache.update { .init(windows: [inbox, editor, draft], current: inbox.id) }
        // The draft was clicked and typed in. Scans pause while typing, so the inbox is still on record.
        XCTAssertEqual(cache.readySnapshot(frontPID: 20)?.current, inbox.id)
        cache.noteLeft(draft)
        let ready = try XCTUnwrap(cache.readySnapshot(frontPID: 20))
        XCTAssertEqual(ready.current, draft.id, "The reading taken as the switcher opens replaces the record")
        XCTAssertEqual(ready.windows.map(\.id), [draft.id, inbox.id, editor.id])
        // A window made since the last scan has no row yet.
        let fresh = window("Untitled", pid: 20)
        cache.noteLeft(fresh)
        XCTAssertEqual(cache.readySnapshot(frontPID: 20)?.windows.map(\.id), [fresh.id, draft.id, inbox.id, editor.id])
    }

    func testWindowLeftIsReturnedToWhenItsReadingArrivesAfterTheRelease() async throws {
        let cache = WindowSwitcherCache()
        let inbox = window("Inbox", pid: 20), editor = window("Editor", pid: 10), draft = window("Draft", pid: 20)
        for recorded in [false, true] {
            _ = await cache.update { .init(windows: [inbox, editor, draft], current: inbox.id) }
            let guessed = try XCTUnwrap(cache.readySnapshot(frontPID: 20))
            var session = WindowSwitchSession<UUID>()
            session.begin(windows: guessed.windows.map(\.id), current: guessed.current, backwards: false)
            XCTAssertEqual(session.selected, editor.id)
            // Command was released before the draft was read as the window in front.
            cache.noteChosen(editor.id)
            if recorded { cache.noteFocused(editor.id) }
            cache.noteLeft(draft, selected: editor.id)
            let back = try XCTUnwrap(cache.readySnapshot(frontPID: 10))
            XCTAssertEqual(back.windows.map(\.id), [editor.id, draft.id, inbox.id])
            session.begin(windows: back.windows.map(\.id), current: back.current, backwards: false)
            XCTAssertEqual(session.selected, draft.id, "Toggling back returns to the window that was left, not to the one last recorded")
        }
    }

    func testFrontWindowReadAfterAGuessTakesItsTurnAndPutsTheGuessBack() async throws {
        let cache = WindowSwitcherCache()
        let editor = window("Editor", pid: 10), other = window("Other", pid: 30)
        let inbox = window("Inbox", pid: 20), draft = window("Draft", pid: 20)
        _ = await cache.update { .init(windows: [editor, other, inbox, draft], current: editor.id) }
        // The draft was clicked from the editor and typed in: its app came forward unrecorded.
        XCTAssertEqual(cache.readySnapshot(frontPID: 20)?.current, inbox.id, "The app's first window is the guess")
        cache.noteLeft(draft)
        let ready = try XCTUnwrap(cache.readySnapshot(frontPID: 20))
        XCTAssertEqual(ready.windows.map(\.id), [draft.id, editor.id, other.id, inbox.id])
        var session = WindowSwitchSession<UUID>()
        session.begin(windows: ready.windows.map(\.id), current: ready.current, backwards: false)
        XCTAssertEqual(session.selected, editor.id, "One Command-Tab goes back to the editor, not to a window that was never in front")
        // The draft was chosen, but a second Command-Tab retired its activation before the raise.
        _ = await cache.update { .init(windows: [editor, other, inbox, draft], current: editor.id) }
        cache.noteChosen(draft.id)
        XCTAssertEqual(cache.readySnapshot(frontPID: 20)?.current, draft.id)
        cache.noteLeft(inbox)
        let retired = try XCTUnwrap(cache.readySnapshot(frontPID: 20))
        XCTAssertEqual(retired.windows.map(\.id), [inbox.id, editor.id, other.id, draft.id])
        // A reading that confirms the guess changes nothing.
        _ = await cache.update { .init(windows: [editor, other, inbox, draft], current: editor.id) }
        _ = cache.readySnapshot(frontPID: 20)
        cache.noteLeft(inbox)
        XCTAssertEqual(cache.readySnapshot(frontPID: 20)?.windows.map(\.id), [inbox.id, editor.id, other.id, draft.id])
        // Nor does a reading of the app still in front take away the window chosen in another.
        _ = await cache.update { .init(windows: [editor, other, inbox, draft], current: editor.id) }
        cache.noteChosen(draft.id)
        cache.noteLeft(editor)
        XCTAssertEqual(cache.readySnapshot(frontPID: 20)?.current, draft.id)
    }

    func testSecondSwitchBeforeTheChosenAppIsReportedInFrontGoesBackToTheWindowLeft() async throws {
        let cache = WindowSwitcherCache()
        var requests = WindowSwitchFrontRequests()
        let editor = window("Editor", pid: 10), browser = window("Browser", pid: 20), other = window("Other", pid: 30)
        _ = await cache.update { .init(windows: [editor, browser, other], current: editor.id) }
        let start = ContinuousClock.now
        // The browser was chosen and asked for; macOS still reports the editor in front.
        cache.noteChosen(browser.id)
        requests.requested(20, at: start)
        let front = requests.front(10, at: start.advanced(by: .milliseconds(200)))
        XCTAssertEqual(front, 20, "The app asked for is the one being left by the next Command-Tab")
        let ready = try XCTUnwrap(cache.readySnapshot(frontPID: front))
        var session = WindowSwitchSession<UUID>()
        session.begin(windows: ready.windows.map(\.id), current: ready.current, backwards: false)
        XCTAssertEqual(session.selected, editor.id, "A second Command-Tab must go back, not choose the browser again")
        // Its report arriving with that list open is the switcher's own doing, once.
        XCTAssertTrue(requests.activated(20, at: start.advanced(by: .milliseconds(300))),
                      "The late report must not close the list opened since")
        XCTAssertFalse(requests.activated(20, at: start.advanced(by: .milliseconds(400))), "Coming forward again was not asked for")
        XCTAssertEqual(requests.front(20, at: start.advanced(by: .milliseconds(400))), 20)
    }

    func testAppsAskedForAreAwaitedInOrderAndOnlyBriefly() {
        var requests = WindowSwitchFrontRequests()
        let start = ContinuousClock.now
        XCTAssertEqual(requests.front(10, at: start), 10)
        XCTAssertFalse(requests.activated(20, at: start), "Nothing was asked for")
        // Back and forth before either report: both are the switcher's own, the last one leads.
        requests.requested(20, at: start)
        requests.requested(10, at: start.advanced(by: .milliseconds(100)))
        XCTAssertEqual(requests.front(20, at: start.advanced(by: .milliseconds(150))), 10)
        XCTAssertTrue(requests.activated(20, at: start.advanced(by: .milliseconds(200))))
        XCTAssertEqual(requests.front(20, at: start.advanced(by: .milliseconds(200))), 10, "The app asked for last is still to come")
        XCTAssertTrue(requests.activated(10, at: start.advanced(by: .milliseconds(250))))
        XCTAssertEqual(requests.front(nil, at: start.advanced(by: .milliseconds(250))), nil)
        // A report of the later request settles the earlier one, which never arrived.
        requests.requested(20, at: start)
        requests.requested(10, at: start.advanced(by: .milliseconds(100)))
        XCTAssertTrue(requests.activated(10, at: start.advanced(by: .milliseconds(200))))
        XCTAssertFalse(requests.activated(20, at: start.advanced(by: .milliseconds(300))))
        // Another app coming forward is someone else's doing and ends the wait.
        requests.requested(20, at: start)
        XCTAssertFalse(requests.activated(30, at: start.advanced(by: .milliseconds(100))))
        XCTAssertEqual(requests.front(30, at: start.advanced(by: .milliseconds(100))), 30)
        XCTAssertFalse(requests.activated(20, at: start.advanced(by: .milliseconds(200))))
        // macOS may never bring an app forward: what it reports counts again after a moment.
        requests.requested(20, at: start)
        XCTAssertEqual(requests.front(10, at: start.advanced(by: .milliseconds(900))), 20)
        XCTAssertEqual(requests.front(10, at: start.advanced(by: .seconds(2))), 10)
        XCTAssertFalse(requests.activated(20, at: start.advanced(by: .seconds(2))))
        // So does a request the switcher itself saw fail.
        requests.requested(20, at: start)
        requests.withdraw(20)
        XCTAssertEqual(requests.front(10, at: start), 10)
    }

    func testBackgroundInventoryFollowsWhatChangedAndRestsWithNobodyAtTheMac() async {
        var pace = WindowInventoryPace()
        let start = ContinuousClock.now
        func after(_ milliseconds: Int) -> ContinuousClock.Instant { start.advanced(by: .milliseconds(milliseconds)) }
        let active = Duration.seconds(1), away = Duration.seconds(60)
        XCTAssertTrue(pace.isDue(at: start, idle: away), "The first inventory waits for nothing")
        XCTAssertTrue(pace.isDue(at: start, idle: away, cached: false))
        pace.scanned(pace.mark, at: start)
        XCTAssertFalse(pace.isDue(at: after(2000), idle: active), "With nothing changed there is no scan of every app every two seconds")
        XCTAssertFalse(pace.isDue(at: after(3600), idle: active))
        XCTAssertTrue(pace.isDue(at: after(4000), idle: active))
        XCTAssertTrue(pace.isDue(at: after(1000), idle: active, cached: false), "Without rows there is nothing to wait for")
        // Command-Tab must still find the rows fresh a pass of the monitor after the scan
        // fell due, so that it rarely has to scan itself.
        let cache = WindowSwitcherCache()
        _ = await cache.update { .init(windows: [], current: nil) }
        XCTAssertFalse(cache.needsRefresh(at: .now.advanced(by: WindowInventoryPace.steady + .milliseconds(400))))
        // An app or a window came or went: as promptly as before, and no more often.
        pace.noteChange()
        XCTAssertFalse(pace.isDue(at: after(1000), idle: active))
        XCTAssertTrue(pace.isDue(at: after(2000), idle: active))
        // What changed while a scan ran needs another one.
        let began = pace.mark
        pace.noteChange()
        pace.scanned(began, at: after(2000))
        XCTAssertFalse(pace.isDue(at: after(3600), idle: active))
        XCTAssertTrue(pace.isDue(at: after(4000), idle: active))
        // Nobody at the Mac: no scan whatever changed, and no reading of the front window either.
        XCTAssertFalse(pace.isDue(at: after(60_000), idle: away))
        XCTAssertFalse(pace.watches(idle: away))
        XCTAssertTrue(pace.watches(idle: active))
        XCTAssertTrue(pace.isDue(at: after(60_000), idle: active), "The first pass after someone returns")
        // The time without input comes from macOS and need not be a time.
        XCTAssertEqual(WindowInventoryPace.untouched(12.5), .milliseconds(12_500))
        XCTAssertFalse(pace.watches(idle: WindowInventoryPace.untouched(.infinity)))
        XCTAssertTrue(pace.watches(idle: WindowInventoryPace.untouched(.nan)))
        XCTAssertTrue(pace.watches(idle: WindowInventoryPace.untouched(-1)))
        pace.scanned(pace.mark, at: after(60_000))
        XCTAssertFalse(pace.isDue(at: after(62_000), idle: active))
        // Screens asleep: nothing at all until they wake.
        pace.noteChange()
        pace.screensAsleep = true
        XCTAssertFalse(pace.isDue(at: after(62_000), idle: active))
        XCTAssertFalse(pace.isDue(at: after(62_000), idle: active, cached: false))
        XCTAssertFalse(pace.watches(idle: active))
        pace.screensAsleep = false
        XCTAssertTrue(pace.isDue(at: after(62_000), idle: active))
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
