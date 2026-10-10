import XCTest
@testable import FrogUsage

@MainActor final class UsageLifecycleTests: XCTestCase {
    func testConstructionAndStoppedRefreshNeverReadAuthentication() async throws {
        let suite = "frog-usage-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let calls = AuthReads()
        let store = Store(defaults: defaults, readAuth: { _, _ in calls.increment(); return nil })
        store.tick()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(calls.count, 0)
        store.start()
        for _ in 0..<100 where calls.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(calls.count, 1)
        store.stop(); store.tick()
        XCTAssertFalse(store.inFlight)
        XCTAssertEqual(calls.count, 1)
    }
    func testStopRejectsAnUncooperativeLateProviderReply() async throws {
        let suite = "frog-usage-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = UsageReplyGate()
        let store = Store(defaults: defaults, readAuth: { _, _ in
            ClaudeAuth(token: "fixture", source: .claudeCode, identity: "fixture", label: "Fixture", hasAccountMetadata: true)
        }, fetchLimits: { _ in await gate.wait() })
        store.start()
        await gate.waitUntilStarted()
        store.stop()
        await gate.release()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(store.usage)
        XCTAssertFalse(store.inFlight)
    }
    func testSelectedFixtureRootDoesNotFallBackToRealLogs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = await CodexScanner(root: root).scan()
        let opencode = await OpenCodeReader(root: root).scan()
        let pi = await PiScanner(root: root).scan()
        XCTAssertFalse(codex.found); XCTAssertFalse(opencode.found); XCTAssertTrue(pi.isEmpty)
    }
    func testPortableDisplayChoicesSynchronizeWithoutStartingDisabledCollection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "frog-usage-preferences-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = UsageDashboardModel(defaults: defaults, fixtureRoot: root)
        var changes: [UsageDashboardPreferences] = []
        model.onPreferencesChange = { changes.append($0) }
        let imported = UsageDashboardPreferences(provider: "OpenAI", range: "30d", metric: "Output", allDevices: true, loginSource: "Pi")
        model.applyPreferences(imported)
        XCTAssertEqual(model.preferences, imported)
        XCTAssertEqual(model.loginSource, "Pi")
        XCTAssertTrue(changes.isEmpty, "Import must not echo into the configuration writer")
        XCTAssertFalse(model.active)
        XCTAssertFalse(model.loaded)
        var selected = imported; selected.provider = "Claude"
        model.updatePreferences(selected)
        XCTAssertEqual(changes, [selected])
        XCTAssertEqual(UsageDashboardModel(defaults: defaults, fixtureRoot: root).preferences, selected)
        XCTAssertEqual(try JSONDecoder().decode(UsageDashboardPreferences.self, from: JSONEncoder().encode(selected)), selected)
    }
}

private final class AuthReads: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
private actor UsageReplyGate {
    private var started = false
    private var start: CheckedContinuation<Void, Never>?
    private var reply: CheckedContinuation<Usage, Never>?
    func wait() async -> Usage {
        started = true; start?.resume(); start = nil
        return await withCheckedContinuation { reply = $0 }
    }
    func waitUntilStarted() async { if !started { await withCheckedContinuation { start = $0 } } }
    func release() { reply?.resume(returning: Usage(limits: [Limit(id: "test", label: "Test", pct: 42, resetsAt: Date().addingTimeInterval(100), window: 100)])); reply = nil }
}
