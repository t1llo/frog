import XCTest
@testable import FrogApp

@MainActor
final class SystemStatusTests: XCTestCase {
    func testRefreshesSharePendingLookupAndCacheCompletedStatus() async throws {
        let fixture = LoginStatusFixture()
        let model = try model(readLoginStatus: { fixture.read() })
        defer { model.shutdown() }
        for _ in 0..<20 { model.refreshSystemStatus() }
        try await wait { model.loginStatus == "Status 1" }
        XCTAssertEqual(fixture.calls, 1)
        for _ in 0..<20 { model.refreshSystemStatus() }
        await Task.yield()
        XCTAssertEqual(fixture.calls, 1, "Completed status is cached across UI and monitor refreshes")
        model.refreshSystemStatus(forceLoginStatus: true)
        try await wait { model.loginStatus == "Status 2" }
        XCTAssertEqual(fixture.calls, 2, "Changing the login setting must bypass the cache")
    }

    func testSupersededAndShutdownLookupsCannotPublishLateResults() async throws {
        let fixture = LoginStatusFixture(blockFirst: true)
        let model = try model(readLoginStatus: { fixture.read() })
        defer { fixture.releaseFirst(); model.shutdown() }
        try await wait { fixture.calls == 1 }
        model.refreshSystemStatus(forceLoginStatus: true)
        try await wait { model.loginStatus == "Status 2" }
        fixture.releaseFirst()
        try await wait { fixture.firstFinished }
        // Allow the cancelled waiter to resume on the main actor.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.loginStatus, "Status 2")
        model.refreshSystemStatus(forceLoginStatus: true)
        model.shutdown()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.loginStatus, "Status 2", "Shutdown must invalidate queued completions")
    }

    func testLoginItemAwaitingApprovalIsShownUntilAStatusReadSaysOtherwise() async throws {
        let approval = LoginApprovalFixture()
        let model = try model(readLoginStatus: {
            approval.given ? .init(enabled: true, text: "On") : .init(enabled: true, text: "Waiting", needsAttention: true)
        })
        defer { model.shutdown() }
        try await wait { model.loginStatus == "Waiting" }
        XCTAssertTrue(model.startAtLogin)
        XCTAssertTrue(model.loginNeedsAttention, "Settings must say that macOS still waits for approval")
        approval.given = true
        // Settings and returning to Frog both read the status again at once.
        model.refreshSystemStatus(forceLoginStatus: true)
        try await wait { model.loginStatus == "On" }
        XCTAssertFalse(model.loginNeedsAttention, "The warning must not outlive the approval")
    }

    func testMonitoringHasOneOwnerAndStopsAtShutdown() async throws {
        var permissionReads = 0
        let ticks = SystemStatusTicks()
        let model = try model(readAccessibility: { permissionReads += 1; return true }, systemStatusTick: { await ticks.next() })
        let initial = permissionReads
        model.startSystemStatusMonitoring()
        model.startSystemStatusMonitoring()
        defer { model.shutdown(); ticks.fire() }
        try await wait { ticks.waiting > 0 }
        XCTAssertEqual(permissionReads, initial + 1)
        XCTAssertEqual(ticks.waiting, 1, "Two consumers must not create two polling loops")
        ticks.fire()
        try await wait { ticks.waiting > 0 }
        XCTAssertEqual(permissionReads, initial + 2, "Each tick refreshes the status once")
        model.shutdown()
        let stopped = permissionReads
        // The stopped loop wakes first; if it went on, it would refresh before the new loop does.
        ticks.fire()
        model.startSystemStatusMonitoring()
        try await wait { ticks.waiting > 0 }
        XCTAssertEqual(permissionReads, stopped + 1, "A loop stopped at shutdown must not refresh again")
        XCTAssertEqual(ticks.waiting, 1)
    }

    private func model(readAccessibility: @escaping () -> Bool = { true },
                       readLoginStatus: @escaping @Sendable () -> LoginService.Snapshot = { .init(enabled: false, text: "Fixture") },
                       systemStatusTick: (() async throws -> Void)? = nil) throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return AppModel(dataDirectory: directory, registerShortcuts: false,
                        readAccessibility: readAccessibility, readLoginStatus: readLoginStatus, systemStatusTick: systemStatusTick)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for status refresh")
    }
}

/// Stands in for the second between two refreshes of the system status: a refresh loop waits
/// here until the test fires the next tick.
@MainActor final class SystemStatusTicks {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// The refresh loops that wait for the next tick.
    var waiting: Int { waiters.count }
    func next() async { await withCheckedContinuation { waiters.append($0) } }
    func fire() {
        let woken = waiters
        waiters.removeAll()
        woken.forEach { $0.resume() }
    }
}

private final class LoginApprovalFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var approved = false
    var given: Bool {
        get { lock.withLock { approved } }
        set { lock.withLock { approved = newValue } }
    }
}

private final class LoginStatusFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let blockFirst: Bool
    private var count = 0
    private var finished = false
    init(blockFirst: Bool = false) { self.blockFirst = blockFirst }
    var calls: Int { lock.withLock { count } }
    var firstFinished: Bool { lock.withLock { finished } }
    func releaseFirst() { gate.signal() }
    func read() -> LoginService.Snapshot {
        XCTAssertFalse(Thread.isMainThread)
        let number = lock.withLock { count += 1; return count }
        if blockFirst && number == 1 { _ = gate.wait(timeout: .now() + 5) }
        else { Thread.sleep(forTimeInterval: 0.1) }
        if number == 1 { lock.withLock { finished = true } }
        return .init(enabled: number.isMultiple(of: 2), text: "Status \(number)")
    }
}
