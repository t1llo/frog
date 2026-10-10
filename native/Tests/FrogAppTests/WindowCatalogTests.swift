import XCTest
import ApplicationServices
@testable import FrogApp

final class WindowCatalogTests: XCTestCase {
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

private final class CatalogFixture: @unchecked Sendable {
    let a = AXUIElementCreateApplication(1010)
    let b = AXUIElementCreateApplication(1020)
    let apps = [SwitcherApplication(pid: 10, name: "A", hidden: false), SwitcherApplication(pid: 20, name: "B", hidden: false)]
    private let lock = NSLock()
    private var lists: [pid_t: WindowCatalog.Reading<[AXUIElement]>] = [:]
    private var metadata: WindowCatalog.Reading<WindowCatalog.Metadata> = .success(.init(title: "Document"))
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
        }, focusedWindow: { [self] pid in pid == 10 ? a : b }, metadata: { [self] _ in lock.withLock { metadata } })
    }
}
