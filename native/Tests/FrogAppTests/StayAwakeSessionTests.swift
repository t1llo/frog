import Combine
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

    func testSavingSettingsDuringTheLaunchCleanupDoesNotHideItsRestore() async throws {
        let system = SessionPowerFixture(enabled: true)
        let folder = directory()
        try leaveMarker("{}", in: folder)
        let power = StayAwakeController(system: system, directory: folder)
        let gate = ReadGate()
        await system.holdNextRead(gate)
        power.start()
        await gate.waitUntilStarted()
        // A settings save applies the configuration while the cleanup still reads the setting.
        power.configureFeature(enabled: true)
        let waited = Task { await power.waitForOperation(); return power.ownsSession }
        try await Task.sleep(for: .milliseconds(50))
        await gate.release()
        let ownedWhenTheWaitEnded = await waited.value
        XCTAssertFalse(ownedWhenTheWaitEnded, "Quitting and disabling the feature wait for the restore that launch started")
        XCTAssertFalse(power.isEnabled)
        XCTAssertFalse(power.isBusy)
        XCTAssertTrue(power.hasReadState)
        let writes = await system.writes
        XCTAssertEqual(writes, [false])
        let canQuit = await power.prepareToQuit()
        XCTAssertTrue(canQuit)
    }

    func testQuittingDuringAResetWaitsForItsRestoreAndOpensNoGuide() async throws {
        let system = SessionPowerFixture()
        let power = StayAwakeController(system: system, directory: directory(), openGuide: { _ in
            await system.noteGuide()
            throw StayAwakeError.command
        })
        await power.refresh()
        power.setEnabled(true); await power.waitForOperation()
        XCTAssertTrue(power.ownsSession)
        let gate = ReadGate()
        await system.holdNextRead(gate)
        power.configureAccess(.reset)
        await gate.waitUntilStarted()
        // Quit arrives while the reset is still restoring sleep.
        let quit = Task { await power.prepareToQuit() }
        await Task.yield()
        await gate.release()
        let canQuit = await quit.value
        await power.waitForAccessGuide()
        XCTAssertTrue(canQuit)
        XCTAssertFalse(power.isEnabled)
        XCTAssertFalse(power.ownsSession)
        let guides = await system.guides
        XCTAssertEqual(guides, 0, "Frog must not open the reset guide in Terminal while it quits")
        let writes = await system.writes
        XCTAssertEqual(writes, [true, false], "Quit waits for the restore that is under way instead of starting a second one")
    }

    func testDisablingTheFeatureDuringAResetWaitsForItsRestore() async throws {
        let system = SessionPowerFixture()
        let power = StayAwakeController(system: system, directory: directory(), openGuide: { _ in throw StayAwakeError.command })
        await power.refresh()
        power.setEnabled(true); await power.waitForOperation()
        let gate = ReadGate()
        await system.holdNextRead(gate)
        power.configureAccess(.reset)
        await gate.waitUntilStarted()
        let waited = Task { await power.waitForOperation(); return power.ownsSession }
        try await Task.sleep(for: .milliseconds(50))
        await gate.release()
        let ownedWhenTheWaitEnded = await waited.value
        XCTAssertFalse(ownedWhenTheWaitEnded, "A restore started by Reset access is a change like any other")
        await power.waitForAccessGuide()
        XCTAssertFalse(power.isBusy)
        XCTAssertFalse(power.isConfiguringAccess)
    }

    func testAFrogStartedBesideARunningOneLeavesItsSessionAlone() async throws {
        // The process that launched this test run stands in for the other Frog: it runs, and
        // it is not this process.
        let other = getppid()
        let started = try XCTUnwrap(StayAwakeController.processStart(other))
        let system = SessionPowerFixture(enabled: true)
        let folder = directory()
        try leaveMarker(#"{"pid":\#(other),"started":\#(started)}"#, in: folder)
        let power = StayAwakeController(system: system, directory: folder)
        power.start(); await power.waitForOperation()
        XCTAssertTrue(power.isEnabled, "The session of the other Frog goes on and shows as on outside this one")
        XCTAssertFalse(power.ownsSession)
        let canQuit = await power.prepareToQuit()
        XCTAssertTrue(canQuit)
        let writes = await system.writes
        XCTAssertTrue(writes.isEmpty, "Neither starting nor quitting ends a session that a running Frog owns")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("stay-awake-session.json").path))
    }

    func testAMarkerWhoseOwnerIsNotProvenToRunIsStillCleanedUp() async throws {
        let parent = getppid()
        let parentStart = try XCTUnwrap(StayAwakeController.processStart(parent))
        let ownStart = try XCTUnwrap(StayAwakeController.processStart(getpid()))
        let leftovers = [
            #"{"pid":\#(parent),"started":\#(parentStart + 1)}"#, // the process id was reused, for example after a restart
            #"{"pid":\#(parent)}"#, // no start time that could prove it
            #"{"pid":\#(Int32.max),"started":\#(parentStart)}"#, // no such process
            #"{"pid":\#(getpid()),"started":\#(ownStart)}"#, // this process: nobody else looks after it
            #"{"deadline":0}"# // written by an earlier version
        ]
        for marker in leftovers {
            let system = SessionPowerFixture(enabled: true)
            let folder = directory()
            try leaveMarker(marker, in: folder)
            let power = StayAwakeController(system: system, directory: folder)
            power.start(); await power.waitForOperation()
            XCTAssertFalse(power.isEnabled, marker)
            XCTAssertFalse(power.ownsSession, marker)
            let writes = await system.writes
            XCTAssertEqual(writes, [false], marker)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("stay-awake-session.json").path), marker)
            let canQuit = await power.prepareToQuit()
            XCTAssertTrue(canQuit, marker)
        }
    }

    func testAMarkerThatCannotBeReadStillRestoresSleep() async throws {
        for (contents, awake) in [("", true), ("not a marker", true), ("[]", true), (#"{"deadline":"soon"}"#, true), ("", false)] {
            let system = SessionPowerFixture(enabled: awake)
            let folder = directory()
            try leaveMarker(contents, in: folder)
            let power = StayAwakeController(system: system, directory: folder)
            power.start(); await power.waitForOperation()
            XCTAssertFalse(power.isEnabled, "A marker means that Frog started a session, readable or not: \(contents)")
            XCTAssertTrue(power.hasReadState, contents)
            XCTAssertFalse(power.ownsSession, contents)
            XCTAssertNil(power.error, "Nothing is left to report once sleep is restored: \(contents)")
            let writes = await system.writes
            XCTAssertEqual(writes, awake ? [false] : [], contents)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("stay-awake-session.json").path), "The next launch must not meet the same marker again: \(contents)")
            let canQuit = await power.prepareToQuit()
            XCTAssertTrue(canQuit, contents)
        }
    }

    func testTheMarkerNamesTheProcessThatOwnsTheSession() async throws {
        let ownStart = try XCTUnwrap(StayAwakeController.processStart(getpid()))
        XCTAssertEqual(StayAwakeController.processStart(getpid()), ownStart, "One process has one start time")
        XCTAssertNil(StayAwakeController.processStart(Int32.max))
        let folder = directory()
        let power = StayAwakeController(system: SessionPowerFixture(), directory: folder)
        await power.refresh()
        power.setEnabled(true); await power.waitForOperation()
        XCTAssertTrue(power.ownsSession)
        let data = try Data(contentsOf: folder.appendingPathComponent("stay-awake-session.json"))
        let marker = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((marker["pid"] as? NSNumber)?.int32Value, getpid())
        XCTAssertEqual((marker["started"] as? NSNumber)?.int64Value, ownStart)
        let canQuit = await power.prepareToQuit()
        XCTAssertTrue(canQuit)
    }

    func testAReadErrorLeavesOnceTheSettingCanBeReadAgain() async {
        let system = SessionPowerFixture()
        let power = StayAwakeController(system: system, directory: directory())
        await power.refresh()
        XCTAssertNil(power.error)
        await system.failReads(true)
        await power.refresh()
        XCTAssertEqual(power.error, StayAwakeError.unreadable.localizedDescription)
        XCTAssertFalse(power.hasReadState)
        await system.failReads(false)
        await power.refresh()
        XCTAssertTrue(power.hasReadState)
        XCTAssertNil(power.error, "A read that works again must not leave the earlier failure beside a working switch")

        // The battery is read only during a session of Frog's own.
        power.setEnabled(true); await power.waitForOperation()
        XCTAssertTrue(power.ownsSession)
        await system.failBattery(true)
        await power.refresh()
        XCTAssertEqual(power.error, StayAwakeError.unreadable.localizedDescription)
        var shown: [String?] = []
        let observation = power.$error.dropFirst().sink { shown.append($0) }
        await power.refresh()
        observation.cancel()
        XCTAssertNotNil(power.error)
        XCTAssertFalse(shown.contains(nil), "While the battery still cannot be read, the failure must not blink away and back")
        await system.failBattery(false)
        await power.refresh()
        XCTAssertNil(power.error)
        XCTAssertTrue(power.isEnabled)
        let canQuit = await power.prepareToQuit()
        XCTAssertTrue(canQuit)
    }

    func testAReadErrorDoesNotKeepHidingTheNoticeOfARestoredSession() async {
        let system = SessionPowerFixture()
        var now = Date(timeIntervalSince1970: 1000)
        let power = StayAwakeController(system: system, directory: directory(), now: { now })
        await power.refresh()
        power.setEnabled(true); await power.waitForOperation()
        now.addTimeInterval(4 * 3600)
        await power.refresh()
        XCTAssertFalse(power.isEnabled)
        XCTAssertEqual(power.notice, "Timer finished · Sleep restored")
        await system.failReads(true)
        await power.refresh()
        XCTAssertNotNil(power.error)
        await system.failReads(false)
        await power.refresh()
        XCTAssertNil(power.error, "The views show an error in place of the notice")
        XCTAssertEqual(power.notice, "Timer finished · Sleep restored")
    }

    func testAnErrorFromAChangeStaysAfterASuccessfulRead() async {
        let system = SessionPowerFixture()
        await system.setBattery(PowerBattery(onBattery: true, percent: 10))
        let power = StayAwakeController(system: system, directory: directory())
        await power.refresh()
        power.setEnabled(true); await power.waitForOperation()
        XCTAssertFalse(power.isEnabled)
        XCTAssertEqual(power.error, StayAwakeError.lowBattery.localizedDescription)
        await power.refresh()
        XCTAssertEqual(power.error, StayAwakeError.lowBattery.localizedDescription, "Why switching on failed stays until the switch is used again")

        // A read that fails and then works must not take the reason of a later change with it.
        // During a session a battery that cannot be read leaves the switch usable.
        await system.setBattery(PowerBattery(onBattery: false, percent: 80))
        power.setEnabled(true); await power.waitForOperation()
        XCTAssertTrue(power.ownsSession)
        await system.failBattery(true)
        await power.refresh()
        XCTAssertEqual(power.error, StayAwakeError.unreadable.localizedDescription)
        XCTAssertTrue(power.canSwitch)
        await system.failWrites(true)
        power.setEnabled(false); await power.waitForOperation()
        XCTAssertTrue(power.isEnabled)
        XCTAssertEqual(power.error, StayAwakeError.command.localizedDescription)
        await system.failBattery(false)
        await system.failWrites(false)
        await power.refresh()
        XCTAssertTrue(power.isEnabled)
        XCTAssertEqual(power.error, StayAwakeError.command.localizedDescription, "Why switching off failed stays while the session is still on")
        let canQuit = await power.prepareToQuit()
        XCTAssertTrue(canQuit)
    }

    private func leaveMarker(_ contents: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: folder.appendingPathComponent("stay-awake-session.json"))
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
    private var readsFail = false
    private var batteryFails = false
    private var writesFail = false
    private var currentBattery = PowerBattery(onBattery: false, percent: 80)
    private(set) var reads = 0
    private(set) var writes: [Bool] = []
    private(set) var guides = 0
    init(enabled: Bool = false) { self.enabled = enabled }
    /// Another tool changes the system setting.
    func setOutside(_ value: Bool) { enabled = value }
    func holdNextRead(_ gate: ReadGate) { held = gate }
    func failReads(_ fail: Bool) { readsFail = fail }
    func failBattery(_ fail: Bool) { batteryFails = fail }
    func failWrites(_ fail: Bool) { writesFail = fail }
    func setBattery(_ battery: PowerBattery) { currentBattery = battery }
    func noteGuide() { guides += 1 }
    func hasAccess() async throws -> Bool { true }
    func sleepDisabled() async throws -> Bool {
        reads += 1
        if let gate = held { held = nil; await gate.wait() }
        if readsFail { throw StayAwakeError.unreadable }
        return enabled
    }
    func battery() async throws -> PowerBattery {
        if batteryFails { throw StayAwakeError.unreadable }
        return currentBattery
    }
    func setSleepDisabled(_ value: Bool) async throws {
        if writesFail { throw StayAwakeError.command }
        writes.append(value); enabled = value
    }
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
