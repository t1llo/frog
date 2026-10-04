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

    func testMonitoringHasOneOwnerAndStopsAtShutdown() async throws {
        var permissionReads = 0
        let model = try model(readAccessibility: { permissionReads += 1; return true })
        let initial = permissionReads
        model.startSystemStatusMonitoring()
        model.startSystemStatusMonitoring()
        defer { model.shutdown() }
        try await wait { permissionReads > initial }
        XCTAssertEqual(permissionReads, initial + 1)
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(permissionReads, initial + 2, "Two consumers must not create two polling loops")
        model.shutdown()
        let stopped = permissionReads
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(permissionReads, stopped)
        model.startSystemStatusMonitoring()
        try await wait { permissionReads > stopped }
        XCTAssertEqual(permissionReads, stopped + 1)
    }

    private func model(readAccessibility: @escaping () -> Bool = { true },
                       readLoginStatus: @escaping @Sendable () -> LoginService.Snapshot = { .init(enabled: false, text: "Fixture") }) throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return AppModel(dataDirectory: directory, registerShortcuts: false,
                        readAccessibility: readAccessibility, readLoginStatus: readLoginStatus)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for status refresh")
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
