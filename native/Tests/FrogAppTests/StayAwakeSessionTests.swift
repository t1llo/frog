import XCTest
@testable import FrogApp

/// Session logic on fixtures only: no window, no status item and no real power command.
@MainActor
final class StayAwakeSessionTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
    }
    private func directory() -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(value); return value
    }

    func testASettingSwitchedOffOutsideFrogIsNoticedWithoutOpeningThePopup() async throws {
        let system = SessionPowerFixture(enabled: true)
        let power = StayAwakeController(system: system, directory: directory(), monitorInterval: .milliseconds(5))
        power.start(); await power.waitForOperation()
        XCTAssertTrue(power.isEnabled)
        XCTAssertFalse(power.ownsSession)
        await system.setOutside(false)
        try await waitUntil { !power.isEnabled }
        XCTAssertFalse(power.isEnabled, "The menu-bar cup must not outlive a setting that another tool switched off")

        let reads = await system.reads
        try await Task.sleep(for: .milliseconds(40))
        let later = await system.reads
        XCTAssertEqual(later, reads, "While the setting is off and Frog owns no session, nothing is read")
        let writes = await system.writes
        XCTAssertTrue(writes.isEmpty)
        let canQuit = await power.prepareToQuit()
        XCTAssertTrue(canQuit)
    }

    func testSwitchingTheFeatureOffDropsAStateThatIsNoLongerRead() async {
        let system = SessionPowerFixture(enabled: true)
        let power = StayAwakeController(system: system, directory: directory())
        power.start(); await power.waitForOperation()
        XCTAssertTrue(power.isEnabled)

        power.configureFeature(enabled: false)
        XCTAssertFalse(power.isEnabled, "With the feature off nothing reads the setting, so the cup must not stay")
        XCTAssertFalse(power.hasReadState)
        await power.refresh()
        XCTAssertFalse(power.isEnabled)

        power.configureFeature(enabled: true); await power.waitForOperation()
        XCTAssertTrue(power.isEnabled, "Switching the feature back on reads the real setting again")
        XCTAssertTrue(power.hasReadState)
        let writes = await system.writes
        XCTAssertTrue(writes.isEmpty, "Frog never changes a setting it did not start")
        let canQuit = await power.prepareToQuit()
        XCTAssertTrue(canQuit)
    }

    func testAReadThatTheFeatureSwitchOvertookIsDropped() async {
        let system = SessionPowerFixture(enabled: true)
        let power = StayAwakeController(system: system, directory: directory())
        let gate = ReadGate()
        await system.holdNextRead(gate)
        let read = Task { await power.refresh() }
        await gate.waitUntilStarted()
        power.configureFeature(enabled: false)
        await gate.release()
        await read.value
        XCTAssertFalse(power.isEnabled)
        XCTAssertFalse(power.hasReadState)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<2500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for stay-awake state")
    }
}

private actor SessionPowerFixture: StayAwakeSystem {
    private var enabled: Bool
    private var held: ReadGate?
    private(set) var reads = 0
    private(set) var writes: [Bool] = []
    init(enabled: Bool = false) { self.enabled = enabled }
    /// Another tool changes the system setting.
    func setOutside(_ value: Bool) { enabled = value }
    func holdNextRead(_ gate: ReadGate) { held = gate }
    func hasAccess() async throws -> Bool { true }
    func sleepDisabled() async throws -> Bool {
        reads += 1
        if let gate = held { held = nil; await gate.wait() }
        return enabled
    }
    func battery() async throws -> PowerBattery { PowerBattery(onBattery: false, percent: 80) }
    func setSleepDisabled(_ value: Bool) async throws { writes.append(value); enabled = value }
}

private actor ReadGate {
    private var started = false
    private var start: CheckedContinuation<Void, Never>?
    private var finish: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true; start?.resume(); start = nil
        await withCheckedContinuation { finish = $0 }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { start = $0 } }
    }
    func release() { finish?.resume(); finish = nil }
}
