import AppKit
import XCTest
@testable import FrogApp

@MainActor
final class StayAwakeAccessTests: XCTestCase {
    private var folders: [URL] = []
    override func tearDown() {
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        folders = []
    }
    private func folder() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        folders.append(value); return value
    }
    private func session(_ result: StayAwakeSetup.Result) throws -> StayAwakeSetup.Session {
        let value = StayAwakeSetup.Session(folder: try folder())
        try result.rawValue.write(to: value.resultFile, atomically: true, encoding: .utf8)
        return value
    }

    func testAccessCheckReflectsPolicyChangesWithoutChangingSleep() async throws {
        let system = AccessPowerFixture()
        let power = StayAwakeController(system: system, directory: try folder())
        await power.refreshAccess()
        XCTAssertEqual(power.accessState, .needsSetup)
        await system.allowAccess(true)
        await power.refreshAccess()
        XCTAssertEqual(power.accessState, .ready)
        await system.allowAccess(false)
        await power.refreshAccess()
        XCTAssertEqual(power.accessState, .needsSetup)
        let writes = await system.writes
        XCTAssertTrue(writes.isEmpty)
        XCTAssertFalse(power.isEnabled)
    }

    func testSuccessfulGuideIsVerifiedAndNeverEnablesStayAwake() async throws {
        let system = AccessPowerFixture()
        let completed = try session(.success)
        let power = StayAwakeController(system: system, directory: try folder(), openGuide: { mode in
            XCTAssertEqual(mode, .setup)
            await system.allowAccess(true)
            return completed
        })
        await power.refresh()
        power.setEnabled(true); await power.waitForOperation()
        XCTAssertNotNil(power.error)
        power.configureAccess()
        XCTAssertTrue(power.isConfiguringAccess)
        power.setEnabled(true)
        await power.waitForAccessGuide()
        XCTAssertFalse(power.isConfiguringAccess)
        XCTAssertEqual(power.accessState, .ready)
        XCTAssertTrue(power.accessNotice?.contains("verified") == true)
        XCTAssertFalse(power.isEnabled)
        XCTAssertNil(power.error, "Verified setup must clear the previous permission error")
        let writes = await system.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testGuideCompletionCannotPretendMissingAccessIsReady() async throws {
        let completed = try session(.success)
        let power = StayAwakeController(system: AccessPowerFixture(), directory: try folder(), openGuide: { _ in completed })
        power.configureAccess(); await power.waitForAccessGuide()
        XCTAssertEqual(power.accessState, .needsSetup)
        XCTAssertTrue(power.accessNotice?.contains("not yet allowed") == true)
        XCTAssertFalse(power.isEnabled)
    }

    func testResetRestoresSleepBeforeTheGuideCanClearPermission() async throws {
        let system = AccessPowerFixture(allowed: true)
        let completed = try session(.success)
        let power = StayAwakeController(system: system, directory: try folder(), openGuide: { mode in
            XCTAssertEqual(mode, .reset)
            let awake = try await system.sleepDisabled()
            XCTAssertFalse(awake, "Existing access must restore sleep before reset removes it")
            await system.allowAccess(false)
            return completed
        })
        await power.refresh()
        power.setEnabled(true); await power.waitForOperation()
        XCTAssertTrue(power.isEnabled)
        power.configureAccess(.reset); await power.waitForAccessGuide()
        XCTAssertFalse(power.isEnabled)
        XCTAssertFalse(power.ownsSession)
        XCTAssertEqual(power.accessState, .needsSetup)
        XCTAssertTrue(power.accessNotice?.contains("Access reset") == true)
        let writes = await system.writes
        XCTAssertEqual(writes, [true, false])
    }

    func testRestoreFailureDoesNotLaunchTheResetGuide() async throws {
        let system = AccessPowerFixture(allowed: true)
        let power = StayAwakeController(system: system, directory: try folder(), openGuide: { _ in
            XCTFail("Must keep permission until sleep can be restored")
            throw StayAwakeError.command
        })
        await power.refresh()
        power.setEnabled(true); await power.waitForOperation()
        await system.denyWrites()
        power.configureAccess(.reset); await power.waitForAccessGuide()
        XCTAssertTrue(power.isEnabled)
        XCTAssertTrue(power.ownsSession)
        XCTAssertFalse(power.isConfiguringAccess)
        XCTAssertNotNil(power.accessNotice)
    }

    func testFailedAndCancelledGuidesCanBeRetried() async throws {
        for result in [StayAwakeSetup.Result.failed, .cancelled] {
            let completed = try session(result)
            let power = StayAwakeController(system: AccessPowerFixture(), directory: try folder(), openGuide: { _ in completed })
            power.configureAccess(); await power.waitForAccessGuide()
            XCTAssertFalse(power.isConfiguringAccess)
            XCTAssertEqual(power.accessState, .needsSetup)
            XCTAssertNotNil(power.accessNotice)
        }
    }

    func testUnavailablePolicyCheckDoesNotShowReady() async throws {
        let system = AccessPowerFixture(allowed: true)
        let power = StayAwakeController(system: system, directory: try folder())
        await power.refreshAccess()
        XCTAssertEqual(power.accessState, .ready)
        await system.failChecks()
        await power.refreshAccess()
        guard case .unavailable = power.accessState else { return XCTFail("An unreadable policy is not verified access") }
    }

    func testPostSetupCheckCannotBeOverwrittenByAnOlderPolicyRead() async throws {
        let system = AccessPowerFixture()
        let gate = AccessCheckGate()
        await system.holdNextCheck(gate)
        let power = StayAwakeController(system: system, directory: try folder())
        let old = Task { await power.refreshAccess() }
        await gate.waitUntilStarted()
        await system.allowAccess(true)
        await power.refreshAccess(force: true)
        XCTAssertEqual(power.accessState, .ready)
        await gate.release()
        await old.value
        XCTAssertEqual(power.accessState, .ready)
    }

    func testEffectivePolicyMustExplicitlyDisableAuthentication() {
        XCTAssertTrue(NativeStayAwakeSystem.allowsWithoutPassword("Sudoers entry:\n    RunAsUsers: root\n    Options: !authenticate\n    Commands:\n /usr/bin/pmset -a disablesleep 0"))
        XCTAssertTrue(NativeStayAwakeSystem.allowsWithoutPassword("Options: !authenticate, !requiretty"))
        XCTAssertFalse(NativeStayAwakeSystem.allowsWithoutPassword("Options: authenticate"))
        XCTAssertFalse(NativeStayAwakeSystem.allowsWithoutPassword("Options: !authenticate_other"))
        XCTAssertFalse(NativeStayAwakeSystem.allowsWithoutPassword("Options: !authenticate, authenticate"))
        XCTAssertFalse(NativeStayAwakeSystem.allowsWithoutPassword("/usr/bin/pmset -a disablesleep 0"))
        XCTAssertFalse(NativeStayAwakeSystem.allowsWithoutPassword("sudo: a password is required"))
    }

    func testDedicatedTerminalSessionParsesQuotedPathsAndReplacesItsShell() throws {
        let parent = try folder().appendingPathComponent("A user's folder")
        let session = try StayAwakeSetup.prepare(.reset, directory: parent)
        let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: session.launcher), format: nil) as? [String: Any])
        XCTAssertEqual(profile["shellExitAction"] as? Int, 0)
        XCTAssertEqual(profile["RunCommandAsShell"] as? Bool, false)
        let command = try XCTUnwrap(profile["CommandString"] as? String)
        XCTAssertTrue(command.hasPrefix("exec "))
        XCTAssertTrue(command.contains("'reset'"))
        XCTAssertTrue(command.contains("user'\\''s folder"))
        XCTAssertFalse(command.contains("sudo"), "Terminal opens the guide; privilege commands require its explanation and confirmation")
    }
}

private actor AccessPowerFixture: StayAwakeSystem {
    private var allowed: Bool
    private var enabled = false
    private var writesDenied = false
    private var checksFail = false
    private var nextCheck: AccessCheckGate?
    private(set) var writes: [Bool] = []
    init(allowed: Bool = false) { self.allowed = allowed }
    func allowAccess(_ allowed: Bool) { self.allowed = allowed }
    func denyWrites() { writesDenied = true }
    func failChecks() { checksFail = true }
    func holdNextCheck(_ gate: AccessCheckGate) { nextCheck = gate }
    func hasAccess() async throws -> Bool {
        if checksFail { throw StayAwakeError.unreadable }
        let value = allowed
        if let gate = nextCheck { nextCheck = nil; await gate.wait() }
        return value
    }
    func sleepDisabled() async throws -> Bool { enabled }
    func battery() async throws -> PowerBattery { PowerBattery(onBattery: false, percent: 80) }
    func setSleepDisabled(_ value: Bool) async throws {
        if writesDenied { throw StayAwakeError.permission }
        writes.append(value); enabled = value
    }
}

private actor AccessCheckGate {
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
