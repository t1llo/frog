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
              raise: { [self] _ in record("raise"); return true },
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
    var reader: WindowCatalog.Reader {
        WindowCatalog.Reader(isTrusted: { true }, windows: { [self] pid in
            onRead?(pid)
            return lock.withLock { lists[pid] ?? .success([]) }
        }, focusedWindow: { [self] pid in pid == 10 ? a : b }, metadata: { [self] _ in lock.withLock { reads += 1; return metadata } })
    }
}
