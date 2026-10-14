import XCTest
import ApplicationServices
@testable import FrogApp

final class WindowCatalogTests: XCTestCase {
    func testOwnerTimeoutRetainsOnlyWindowsStillInItsSuccessfulWindowList() async throws {
        let fixture = CatalogFixture()
        fixture.setWindows(.success([fixture.a, fixture.b]), pid: 20)
        let catalog = WindowCatalog(reader: fixture.reader)
        let first = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        let ownerIDs = first.windows.filter { $0.pid == 20 }.map(\.id)
        XCTAssertEqual(ownerIDs.count, 2)
        fixture.setWindows(.success([fixture.b]), pid: 20)
        fixture.setMetadata(.failure(.cannotComplete))
        let partial = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertEqual(partial.windows.filter { $0.pid == 20 }.map(\.id), [ownerIDs[1]],
                       "Skipping an unresponsive owner's unread metadata must not resurrect windows absent from its successful list")
    }

    func testTimedOutOwnerDoesNotMultiplyTimeoutAcrossEveryWindow() async {
        let fixture = CatalogFixture()
        fixture.setWindows(.success((2000..<2050).map { AXUIElementCreateApplication(pid_t($0)) }), pid: 20)
        let catalog = WindowCatalog(reader: fixture.reader)
        let first = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        let before = fixture.metadataReads
        fixture.setMetadata(.failure(.cannotComplete))
        let partial = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        let reads = fixture.metadataReads - before
        print("SWITCHER LATENCY timed-out 51-window inventory: \(reads) AX metadata attempts across 2 owners")
        XCTAssertEqual(reads, 2, "One unresponsive owner must not charge its AX timeout for every window")
        XCTAssertEqual(partial.windows, first.windows, "Keep bounded last-known identities for the skipped windows")
        XCTAssertEqual(partial.completeness, .partial)
    }

    func testActivationRecencySurvivesTheNextInventoryRefresh() async throws {
        let fixture = CatalogFixture()
        let writes = ActivationFixture()
        let catalog = WindowCatalog(reader: fixture.reader, writer: writes.writer)
        let first = await catalog.snapshot(applications: fixture.apps, frontPID: 10)
        let selected = try XCTUnwrap(first.windows.last)
        let raised = await catalog.raise(id: selected.id)
        XCTAssertTrue(raised)
        let refreshed = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertEqual(refreshed.windows.first?.id, selected.id)
    }

    func testWindowFoundInFrontWithoutARecordedFocusKeepsItsTurnInTheOrder() async throws {
        let fixture = CatalogFixture()
        let writes = ActivationFixture()
        let catalog = WindowCatalog(reader: fixture.reader, writer: writes.writer)
        let first = await catalog.snapshot(applications: fixture.apps, frontPID: 10)
        let (recorded, unrecorded) = (try XCTUnwrap(first.windows.first), try XCTUnwrap(first.windows.last))
        catalog.noteFront(id: unrecorded.id)
        let raised = await catalog.raise(id: recorded.id)
        XCTAssertTrue(raised)
        fixture.setWindows(.success([fixture.a, AXUIElementCreateApplication(1011)]), pid: 10)
        let refreshed = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertEqual(refreshed.windows.prefix(2).map(\.id), [recorded.id, unrecorded.id])
    }

    func testWindowReadInFrontAsTheSwitcherOpensIsTheOneReturnedTo() async throws {
        for late in [false, true] {
            let fixture = CatalogFixture()
            let writes = ActivationFixture()
            let second = AXUIElementCreateApplication(1011)
            fixture.setWindows(.success([fixture.a, second]), pid: 10)
            let catalog = WindowCatalog(reader: fixture.reader, writer: writes.writer)
            let first = await catalog.snapshot(applications: fixture.apps, frontPID: 10)
            let (recorded, clicked, other) = (first.windows[0], first.windows[1], first.windows[2])
            // The second window was clicked and typed in; scans pause while typing.
            fixture.setFocused(second, pid: 10)
            catalog.noteFront(id: recorded.id)
            if late { let raised = await catalog.raise(id: other.id); XCTAssertTrue(raised) }
            let left = await catalog.noteFocus(of: fixture.apps[0], insteadOf: recorded.id)
            XCTAssertEqual(left, clicked)
            if !late { let raised = await catalog.raise(id: other.id); XCTAssertTrue(raised) }
            let refreshed = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
            XCTAssertEqual(refreshed.windows.map(\.id), [other.id, clicked.id, recorded.id],
                           "The window that was left comes next, whether its reading arrived before the switch or after")
        }
    }

    func testWindowReadInFrontTakesTheTurnOfTheGuessWhichGoesBack() async throws {
        let fixture = CatalogFixture()
        let second = AXUIElementCreateApplication(1011), earlier = AXUIElementCreateApplication(1021)
        fixture.setWindows(.success([fixture.a, second]), pid: 10)
        fixture.setWindows(.success([fixture.b, earlier]), pid: 20)
        let catalog = WindowCatalog(reader: fixture.reader)
        fixture.setFocused(earlier, pid: 20)
        _ = await catalog.snapshot(applications: fixture.apps, frontPID: 20)
        fixture.setFocused(fixture.b, pid: 20)
        let first = await catalog.snapshot(applications: fixture.apps, frontPID: 20)
        XCTAssertEqual(first.windows.count, 4)
        let (front, before, guess, clicked) = (first.windows[0], first.windows[1], first.windows[2], first.windows[3])
        XCTAssertEqual([front.pid, before.pid, guess.pid, clicked.pid], [20, 20, 10, 10])
        // The other app's second window was clicked and typed in: its first row is only a guess.
        fixture.setFocused(second, pid: 10)
        catalog.noteFront(id: guess.id)
        let left = await catalog.noteFocus(of: fixture.apps[0], insteadOf: guess.id)
        XCTAssertEqual(left?.id, clicked.id)
        let refreshed = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertEqual(refreshed.windows.map(\.id), [clicked.id, front.id, before.id, guess.id],
                       "A window that was never in front must not become the next target")
        // A scan that ranked the guess before the reading arrived leaves the reading in front of it.
        catalog.noteFront(id: before.id)
        _ = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        _ = await catalog.noteFocus(of: fixture.apps[1], insteadOf: before.id)
        let ranked = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertEqual(ranked.windows.map(\.id), [front.id, before.id, clicked.id, guess.id])
    }

    func testWindowMadeSinceTheLastScanIsListedAndCanBeChosenBeforeTheNextOne() async throws {
        let fixture = CatalogFixture()
        let writes = ActivationFixture()
        let catalog = WindowCatalog(reader: fixture.reader, writer: writes.writer)
        let first = await catalog.snapshot(applications: fixture.apps, frontPID: 10)
        let recorded = try XCTUnwrap(first.windows.first)
        let made = AXUIElementCreateApplication(1011)
        fixture.setFocused(made, pid: 10)
        fixture.setMetadata(.success(.init(subrole: "AXFloatingWindow", title: "Palette")))
        catalog.noteFront(id: recorded.id)
        let palette = await catalog.noteFocus(of: fixture.apps[0], insteadOf: recorded.id)
        XCTAssertNil(palette, "A palette is not a window to switch to")
        fixture.setMetadata(.success(.init(title: " Draft ")))
        let read = await catalog.noteFocus(of: fixture.apps[0], insteadOf: recorded.id)
        let row = try XCTUnwrap(read)
        XCTAssertEqual([row.appName, row.title], ["A", "Draft"])
        XCTAssertEqual(row.pid, 10)
        let raised = await catalog.raise(id: row.id)
        XCTAssertTrue(raised, "The window can be returned to before a scan has listed it")
        fixture.setWindows(.success([fixture.a, made]), pid: 10)
        let refreshed = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertEqual(refreshed.windows.prefix(2).map(\.id), [row.id, recorded.id])
    }

    func testWindowsFoundThroughAccessibilityAreNotLookedUpAgainForOtherDesktops() async {
        let fixture = CatalogFixture()
        let asked = AskedWindows()
        var reader = fixture.reader
        reader.windowID = { [fixture] element in CFEqual(element, fixture.a) ? 101 : 202 }
        reader.offSpaceWindows = { _, known in asked.record(known); return [.init(id: 303, pid: 20, title: "Parked")] }
        let catalog = WindowCatalog(reader: reader)
        let snapshot = await catalog.snapshot(applications: fixture.apps, frontPID: 10)
        XCTAssertEqual(asked.known, [101, 202], "WindowServer is asked once per window for its Desktop: not for those already listed")
        XCTAssertEqual(snapshot.windows.map(\.windowID), [101, 202, 303])
    }

    func testOnlyWindowsThatCanBeParkedOnAnotherDesktopAreAskedAboutTheirs() {
        func row(_ id: CGWindowID, pid: pid_t = 10, layer: Int = 0, alpha: Double = 1, side: Int = 400, title: String? = nil) -> [String: Any] {
            var row: [String: Any] = [
                kCGWindowNumber as String: NSNumber(value: id), kCGWindowOwnerPID as String: NSNumber(value: pid),
                kCGWindowLayer as String: NSNumber(value: layer), kCGWindowAlpha as String: NSNumber(value: alpha),
                kCGWindowBounds as String: CGRect(x: 0, y: 0, width: side, height: side).dictionaryRepresentation]
            if let title { row[kCGWindowName as String] = title }
            return row
        }
        let rows = [row(1, title: "Parked"), row(2), row(3, side: 1), row(4, layer: 25), row(5, alpha: 0), row(6, pid: 30), row(7, pid: 20)]
        let candidates = WindowSpaceBridge.candidates(in: rows, owners: [10, 20], known: [2])
        XCTAssertEqual(candidates.map(\.id), [1, 7],
                       "A window already listed, a one-point helper, another layer, an invisible window and another owner cost no lookup")
        XCTAssertEqual(candidates.map(\.pid), [10, 20])
        XCTAssertEqual(candidates.first?.title, "Parked")
    }

    func testOnlyAWindowOnAKnownDesktopOutOfSightIsTravelledTo() {
        let topology = [WindowSpaceBridge.Display(name: "Main", current: 1, spaces: [1, 2]),
                        WindowSpaceBridge.Display(name: "Side", current: 5, spaces: [5, 6])]
        let travel = WindowSpaceBridge.destination(of: [6], in: topology)
        XCTAssertEqual(travel?.display, "Side")
        XCTAssertEqual(travel?.space, 6)
        XCTAssertNil(WindowSpaceBridge.destination(of: [2, 5], in: topology), "A window on a Desktop in sight needs no travel")
        // A Space no display lists, a full-screen tile say: Accessibility and the app's activation
        // still bring it forward, so the selection must not fail for want of a Desktop to select.
        XCTAssertNil(WindowSpaceBridge.destination(of: [9], in: topology))
    }

    func testSelectionFinishesWhileUnrelatedDiscoveryIsStillBlocked() async throws {
        let fixture = CatalogFixture()
        let writes = ActivationFixture()
        let catalog = WindowCatalog(reader: fixture.reader, writer: writes.writer)
        let first = await catalog.snapshot(applications: fixture.apps, frontPID: 10)
        let selected = try XCTUnwrap(first.windows.first)
        let entered = expectation(description: "Unrelated AX discovery entered")
        let release = DispatchSemaphore(value: 0)
        fixture.onRead = { pid in if pid == 20 { entered.fulfill(); release.wait() } }
        let scan = Task { await catalog.snapshot(applications: fixture.apps, frontPID: nil) }
        await fulfillment(of: [entered], timeout: 2)
        let finished = expectation(description: "Selection bypassed blocked scan")
        let start = ContinuousClock.now
        let activation = Task {
            let result = await catalog.raise(id: selected.id)
            finished.fulfill()
            return result
        }
        await fulfillment(of: [finished], timeout: 0.5)
        print("SWITCHER LATENCY activation during blocked scan: \(start.duration(to: .now))")
        scan.cancel(); release.signal()
        let activated = await activation.value
        XCTAssertTrue(activated)
        let cancelled = await scan.value
        XCTAssertEqual(cancelled.completeness, .cancelled)
        XCTAssertEqual(writes.events, ["validate", "minimized", "raise", "main"])
        // A cancelled inventory must not retire the published activation handle.
        let retained = await catalog.raise(id: selected.id)
        XCTAssertTrue(retained)
        fixture.onRead = nil
        fixture.setWindows(.success([]), pid: selected.pid)
        _ = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        let removed = await catalog.raise(id: selected.id)
        XCTAssertFalse(removed, "A successful empty read must retire the closed window")
    }

    func testInputInvalidationDuringAXReadPreventsEveryFocusChangingWrite() async throws {
        let fixture = CatalogFixture()
        let writes = ActivationFixture()
        let catalog = WindowCatalog(reader: fixture.reader, writer: writes.writer)
        let first = await catalog.snapshot(applications: fixture.apps, frontPID: 10)
        let selected = try XCTUnwrap(first.windows.first)
        let entered = expectation(description: "Activation validation entered")
        let release = DispatchSemaphore(value: 0)
        writes.onValidate = { entered.fulfill(); release.wait() }
        let activation = Task { await catalog.raise(id: selected.id, isCurrent: { writes.current }) }
        await fulfillment(of: [entered], timeout: 2)
        // Models the event-tap invalidation before its main-queue message runs.
        writes.invalidate()
        release.signal()
        let result = await activation.value
        XCTAssertFalse(result)
        XCTAssertEqual(writes.events, ["validate"])
    }

    func testInputAfterTheAppWasAskedForStillRaisesThePreparedWindow() async throws {
        let fixture = CatalogFixture()
        let writes = ActivationFixture()
        let catalog = WindowCatalog(reader: fixture.reader, writer: writes.writer)
        let first = await catalog.snapshot(applications: fixture.apps, frontPID: 10)
        let (selected, other) = (try XCTUnwrap(first.windows.first), try XCTUnwrap(first.windows.last))
        let prepared = await catalog.prepareActivation(id: selected.id, isCurrent: { writes.current })
        XCTAssertTrue(prepared)
        let entered = expectation(description: "Raise validation entered")
        let release = DispatchSemaphore(value: 0)
        writes.onValidate = { entered.fulfill(); release.wait() }
        let activation = Task { await catalog.raise(id: selected.id, isCurrent: { writes.current }, requested: true) }
        await fulfillment(of: [entered], timeout: 2)
        // A keystroke retires the activation and the switcher cancels its task.
        writes.invalidate(); activation.cancel()
        release.signal()
        let raised = await activation.value
        XCTAssertTrue(raised, "The app comes forward whatever input follows its request; so must the window chosen in it")
        XCTAssertEqual(writes.events, ["validate", "minimized", "raise", "main"])
        writes.onValidate = nil

        // Only the window prepared for the request: anything else still stops for input.
        let unprepared = await catalog.raise(id: other.id, isCurrent: { writes.current }, requested: true)
        XCTAssertFalse(unprepared)
        XCTAssertEqual(writes.events, ["validate", "minimized", "raise", "main"])
    }

    func testUnansweredOwnerRetentionIsCountBounded() async {
        let fixture = CatalogFixture()
        fixture.setWindows(.success((2000..<2300).map { AXUIElementCreateApplication(pid_t($0)) }), pid: 20)
        let catalog = WindowCatalog(reader: fixture.reader)
        let first = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertEqual(first.windows.count, 301)
        fixture.setWindows(.failure(.cannotComplete), pid: 10)
        fixture.setWindows(.failure(.cannotComplete), pid: 20)
        let partial = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertEqual(partial.windows.count, 256)
        XCTAssertTrue(Set(partial.windows.map(\.id)).isSubset(of: Set(first.windows.map(\.id))))
    }

    func testWindowMetadataTimeoutRetainsOnlyThatWindowAndExpiresWithoutExtendingItsAge() async throws {
        let fixture = CatalogFixture()
        let catalog = WindowCatalog(reader: fixture.reader, now: { fixture.now })
        let first = await catalog.snapshot(applications: fixture.apps, frontPID: 20)
        fixture.setMetadata(.failure(.cannotComplete))
        fixture.advance(seconds: 20)
        let partial = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertEqual(partial.windows, first.windows)
        XCTAssertEqual(partial.completeness, .partial)
        fixture.advance(seconds: 11)
        let expired = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertTrue(expired.windows.isEmpty)
        fixture.setMetadata(.success(.init(title: "Document")))
        let recovered = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertTrue(Set(recovered.windows.map(\.id)).isDisjoint(with: first.windows.map(\.id)))
    }

    func testCancelledScanCannotPublishPartialRowsOrPrunePreviousIdentity() async throws {
        let fixture = CatalogFixture()
        let catalog = WindowCatalog(reader: fixture.reader)
        let first = await catalog.snapshot(applications: fixture.apps, frontPID: 20)
        let entered = expectation(description: "AX read entered")
        let release = DispatchSemaphore(value: 0)
        fixture.onRead = { pid in if pid == 20 { entered.fulfill(); release.wait() } }
        let scan = Task { await catalog.snapshot(applications: fixture.apps, frontPID: nil) }
        await fulfillment(of: [entered], timeout: 2)
        scan.cancel(); release.signal()
        let cancelled = await scan.value
        XCTAssertEqual(cancelled.completeness, .cancelled)
        XCTAssertFalse(cancelled.isPublishable)
        XCTAssertTrue(cancelled.windows.isEmpty)
        fixture.onRead = nil
        let recovered = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertEqual(recovered.windows, first.windows)
    }

    func testDepartedOwnersAreRemovedEvenAfterAnUnansweredScan() async {
        let fixture = CatalogFixture()
        let catalog = WindowCatalog(reader: fixture.reader)
        _ = await catalog.snapshot(applications: fixture.apps, frontPID: 20)
        fixture.setWindows(.failure(.cannotComplete), pid: 20)
        _ = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        let departed = await catalog.snapshot(applications: [fixture.apps[0]], frontPID: nil)
        XCTAssertEqual(departed.windows.map(\.pid), [10])
        XCTAssertEqual(departed.completeness, .complete)
    }

    func testWindowOneScanMissesComesBackWithItsIdentityAndItsPlaceInTheOrder() async throws {
        let fixture = CatalogFixture()
        fixture.numberWindows()
        let catalog = WindowCatalog(reader: fixture.reader, now: { fixture.now })
        let first = await catalog.snapshot(applications: fixture.apps, frontPID: 20)
        let original = try XCTUnwrap(first.windows.first { $0.pid == 20 })
        XCTAssertEqual(first.windows.first, original)
        // A Desktop changed while the scan ran: the window was on neither side of it.
        fixture.setWindows(.success([]), pid: 20)
        let missed = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertEqual(missed.windows.map(\.pid), [10], "The scan lists what it found")
        fixture.setWindows(.success([fixture.b]), pid: 20)
        let returned = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertEqual(returned.windows.first, original, "The window used last must still be the one returned to")
        XCTAssertEqual(returned.windows.map(\.pid), [20, 10])

        // Once its owner quits, or a while after, a window number is not held for it any longer.
        _ = await catalog.snapshot(applications: [fixture.apps[0]], frontPID: nil)
        let relaunched = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertNotEqual(relaunched.windows.first { $0.pid == 20 }?.id, original.id)
        let kept = try XCTUnwrap(relaunched.windows.first { $0.pid == 20 })
        fixture.setWindows(.success([]), pid: 20)
        _ = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        fixture.advance(seconds: 301)
        _ = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        fixture.setWindows(.success([fixture.b]), pid: 20)
        let late = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertNotEqual(late.windows.first { $0.pid == 20 }?.id, kept.id)
    }

    func testUnansweredOwnerRetainsIdentityMetadataAndRecencyUntilARealEmptyAnswer() async throws {
        let fixture = CatalogFixture()
        let catalog = WindowCatalog(reader: fixture.reader)
        let first = await catalog.snapshot(applications: fixture.apps, frontPID: 20)
        let original = try XCTUnwrap(first.windows.first { $0.pid == 20 })
        fixture.setWindows(.failure(.cannotComplete), pid: 20)
        let partial = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertEqual(partial.windows.first, original, "An AX timeout is not evidence that the most recent window closed")
        fixture.setWindows(.success([fixture.b]), pid: 20)
        let recovered = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertEqual(recovered.windows.first, original, "Recovery must keep the window's identity and MRU position")
        fixture.setWindows(.success([]), pid: 20)
        let empty = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertEqual(empty.windows.map(\.pid), [10])
        fixture.setWindows(.success([fixture.b]), pid: 20)
        let reopened = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertNotEqual(reopened.windows.first { $0.pid == 20 }?.id, original.id)
    }
}

private final class ActivationFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var valid = true
    var onValidate: (@Sendable () -> Void)?
    var events: [String] { lock.withLock { recorded } }
    var current: Bool { lock.withLock { valid } }
    func invalidate() { lock.withLock { valid = false } }
    private func record(_ event: String) { lock.withLock { recorded.append(event) } }
    var writer: WindowActivationExecutor.Writer {
        .init(isTrusted: { true }, isWindow: { [self] _ in record("validate"); onValidate?(); return true },
              isMinimized: { [self] _ in record("minimized"); return false },
              unminimize: { [self] _ in record("unminimize"); return true },
              raise: { [self] _ in record("raise"); return .success },
              makeMain: { [self] _ in record("main") },
              bringForward: { [self] _ in record("forward"); return true })
    }
}

private final class CatalogFixture: @unchecked Sendable {
    let a = AXUIElementCreateApplication(1010)
    let b = AXUIElementCreateApplication(1020)
    let apps = [SwitcherApplication(pid: 10, name: "A", hidden: false), SwitcherApplication(pid: 20, name: "B", hidden: false)]
    private let lock = NSLock()
    private var lists: [pid_t: WindowCatalog.Reading<[AXUIElement]>] = [:]
    private var metadata: WindowCatalog.Reading<WindowCatalog.Metadata> = .success(.init(title: "Document"))
    private var reads = 0
    var metadataReads: Int { lock.withLock { reads } }
    private var timestamp = ContinuousClock.now
    private var readHook: (@Sendable (pid_t) -> Void)?
    var onRead: (@Sendable (pid_t) -> Void)? {
        get { lock.withLock { readHook } }
        set { lock.withLock { readHook = newValue } }
    }
    var now: ContinuousClock.Instant { lock.withLock { timestamp } }
    func advance(seconds: Int) { lock.withLock { timestamp = timestamp.advanced(by: .seconds(seconds)) } }
    func setMetadata(_ result: WindowCatalog.Reading<WindowCatalog.Metadata>) { lock.withLock { metadata = result } }
    init() { lists = [10: .success([a]), 20: .success([b])] }
    func setWindows(_ result: WindowCatalog.Reading<[AXUIElement]>, pid: pid_t) { lock.withLock { lists[pid] = result } }
    private var focus: [pid_t: AXUIElement] = [:]
    func setFocused(_ element: AXUIElement, pid: pid_t) { lock.withLock { focus[pid] = element } }
    private var numbered = false
    /// Gives `a` and `b` the native window numbers 101 and 202, as real windows have.
    func numberWindows() { lock.withLock { numbered = true } }
    var reader: WindowCatalog.Reader {
        WindowCatalog.Reader(isTrusted: { true }, windows: { [self] pid in
            onRead?(pid)
            return lock.withLock { lists[pid] ?? .success([]) }
        }, focusedWindow: { [self] pid in lock.withLock { focus[pid] } ?? (pid == 10 ? a : b) }, metadata: { [self] _ in lock.withLock { reads += 1; return metadata } },
           windowID: { [self] element in lock.withLock { numbered } ? (CFEqual(element, a) ? 101 : 202) : nil }, offSpaceWindows: { _, _ in [] })
    }
}

private final class AskedWindows: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<CGWindowID>?
    var known: Set<CGWindowID>? { lock.withLock { ids } }
    func record(_ known: Set<CGWindowID>) { lock.withLock { ids = known } }
}
