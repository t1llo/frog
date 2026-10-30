import FrogTestSupport
import XCTest
@testable import FrogUsage

@MainActor final class UsageLifecycleTests: XCTestCase {
    func testConstructionAndStoppedRefreshNeverReadAuthentication() async throws {
        let defaults = temporaryDefaults()
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
        let defaults = temporaryDefaults()
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
        let defaults = temporaryDefaults()
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
        // The owner keeps the choices (LLM usage writes them to config.toml); a new model starts from the defaults.
        XCTAssertEqual(UsageDashboardModel(defaults: defaults, fixtureRoot: root).preferences.range, UsageDashboardPreferences().range)
        XCTAssertEqual(try JSONDecoder().decode(UsageDashboardPreferences.self, from: JSONEncoder().encode(selected)), selected)
    }
    func testVisibleRefreshFollowsWhoIsShowingNotHowOftenTheySaidSo() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = temporaryDefaults()
        let model = UsageDashboardModel(defaults: defaults, fixtureRoot: root)
        model.setAvailable(true)
        defer { model.setAvailable(false) }
        XCTAssertFalse(model.isVisiblePolling)
        // A window that keeps its page after closing reports "hidden" whenever its state changes,
        // also before it was ever shown and while the menu-bar popup is open.
        model.setPresented(false, for: .dashboard)
        model.setPresented(true, for: .popup)
        XCTAssertTrue(model.isVisiblePolling)
        let timer = model.visibleTimer
        model.setPresented(false, for: .dashboard)
        XCTAssertTrue(model.isVisiblePolling, "The open popup keeps refreshing when the dashboard's window reports hidden")
        model.setPresented(true, for: .popup)
        XCTAssertTrue(model.visibleTimer === timer, "A report that changes nothing must not restart the refresh")
        model.setPresented(true, for: .dashboard)
        let shared = model.visibleTimer
        model.setPresented(true, for: .dashboard)
        model.setPresented(false, for: .popup)
        XCTAssertTrue(model.isVisiblePolling, "The dashboard is still showing")
        XCTAssertTrue(model.visibleTimer === shared, "One of two leaving changes nothing for the other")
        model.setPresented(false, for: .dashboard)
        XCTAssertFalse(model.isVisiblePolling, "One hidden report ends what repeated shown reports started")
        model.setPresented(true, for: .dashboard)
        model.setAvailable(false)
        XCTAssertFalse(model.isVisiblePolling, "Nothing refreshes while LLM usage is off")
    }
    func testRepeatingRefreshesLetTheSystemGroupTheirWakeUps() throws {
        let defaults = temporaryDefaults()
        func check(_ timer: Timer?, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
            guard let timer else { return XCTFail("\(name) is not running", file: file, line: line) }
            // NSTimer.h recommends at least ten percent; much more would slow the refresh visibly.
            XCTAssertGreaterThanOrEqual(timer.tolerance, timer.timeInterval / 10, name, file: file, line: line)
            XCTAssertLessThanOrEqual(timer.tolerance, timer.timeInterval / 5, name, file: file, line: line)
        }
        let store = Store(defaults: defaults, readAuth: { _, _ in nil })
        store.start()
        defer { store.stop() }
        check(store.timer, "Claude limits")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tokens = TokenStore(fixtureRoot: root)
        tokens.start()
        defer { tokens.stop() }
        check(tokens.timer, "Local token logs")
        let model = UsageDashboardModel(defaults: defaults, fixtureRoot: root)
        model.setAvailable(true)
        defer { model.setAvailable(false) }
        model.setPresented(true, for: .popup)
        check(model.visibleTimer, "Visible refresh")
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
