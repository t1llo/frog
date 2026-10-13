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

    func testAGuideThatFailsAfterAccessWasGrantedDoesNotAskForAnotherSetup() async throws {
        let system = AccessPowerFixture()
        let closedEarly = try session(.failed)
        // The rule was saved, then the guide ended before it could verify and report it.
        let power = StayAwakeController(system: system, directory: try folder(), openGuide: { _ in
            await system.allowAccess(true)
            return closedEarly
        })
        power.configureAccess(); await power.waitForAccessGuide()
        XCTAssertEqual(power.accessState, .ready)
        XCTAssertEqual(power.accessNotice, "Setup did not finish, but both power commands are allowed. You can use Stay awake from the menu bar.",
            "Settings shows Ready to use, so the notice next to it must not say that setup has to be repeated")

        // A reset that fails has not removed the access it was asked to remove.
        let failedReset = try session(.failed)
        let reset = StayAwakeController(system: AccessPowerFixture(allowed: true), directory: try folder(), openGuide: { _ in failedReset })
        await reset.refresh()
        reset.configureAccess(.reset); await reset.waitForAccessGuide()
        XCTAssertEqual(reset.accessState, .ready)
        XCTAssertEqual(reset.accessNotice, "Setup did not finish. Review the Terminal window and try again.")
    }

    func testCancellingAResetSaysThatSleepWasAlreadyRestored() async throws {
        let system = AccessPowerFixture(allowed: true)
        let declined = try session(.cancelled)
        let power = StayAwakeController(system: system, directory: try folder(), openGuide: { _ in declined })
        await power.refresh()
        power.setEnabled(true); await power.waitForOperation()
        XCTAssertTrue(power.isEnabled)
        power.configureAccess(.reset); await power.waitForAccessGuide()
        XCTAssertFalse(power.isEnabled)
        XCTAssertFalse(power.ownsSession)
        XCTAssertEqual(power.accessState, .ready)
        XCTAssertEqual(power.accessNotice, "Sleep restored. Access guide cancelled.", "Answering no in Terminal does not bring the session back, so Frog says that it ended")

        let idleDeclined = try session(.cancelled)
        let idle = StayAwakeController(system: AccessPowerFixture(allowed: true), directory: try folder(), openGuide: { _ in idleDeclined })
        await idle.refresh()
        idle.configureAccess(.reset); await idle.waitForAccessGuide()
        XCTAssertEqual(idle.accessNotice, "Access guide cancelled.", "Nothing was on, so nothing was restored")

        let setupDeclined = try session(.cancelled)
        let running = StayAwakeController(system: AccessPowerFixture(allowed: true), directory: try folder(), openGuide: { _ in setupDeclined })
        await running.refresh()
        running.setEnabled(true); await running.waitForOperation()
        running.configureAccess(.setup); await running.waitForAccessGuide()
        XCTAssertTrue(running.isEnabled, "The setup guide never touches a running session")
        XCTAssertEqual(running.accessNotice, "Access guide cancelled.")
        let canQuit = await running.prepareToQuit()
        XCTAssertTrue(canQuit)
    }

    func testAGuideThatIsKilledBeforeItReportsEndsTheWait() async throws {
        let session = try StayAwakeSetup.prepare(.setup, directory: try folder())
        // Nobody answers its first question, so the real guide waits there, before any sudo.
        let guide = try runGuide(session, arguments: ["setup", session.resultFile.path], answers: Pipe())
        defer { stop(guide) }
        try await waitUntil { FileManager.default.fileExists(atPath: session.processFile.path) }
        let named = try String(contentsOf: session.processFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(named, String(guide.processIdentifier), "The guide names the process that Frog watches")

        var ended = false
        let wait = Task { let result = try await session.waitForResult(); ended = true; return result }
        let limit = Task { try await Task.sleep(for: .seconds(20)); wait.cancel() }
        defer { limit.cancel() }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(ended, "A guide that still runs is waited for, however long it takes")

        stop(guide)
        let result = try await wait.value
        XCTAssertEqual(result, .failed, "A killed guide writes no result, so nothing else could end the wait")
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.resultFile.path))
    }

    func testAGuideThatEndsInOrderStillReportsItsOwnResult() async throws {
        let session = try StayAwakeSetup.prepare(.reset, directory: try folder())
        // An empty answer declines the reset, so the guide ends before any sudo.
        let guide = try runGuide(session, arguments: ["reset", session.resultFile.path], answers: FileHandle.nullDevice)
        defer { stop(guide) }
        let wait = Task { try await session.waitForResult() }
        let limit = Task { try await Task.sleep(for: .seconds(20)); wait.cancel() }
        defer { limit.cancel() }
        let result = try await wait.value
        XCTAssertEqual(result, .cancelled)

        // A result that was written counts, also when its guide is gone by the time Frog looks.
        let gone = try self.session(.success)
        try "\(Int32.max)\n".write(to: gone.processFile, atomically: true, encoding: .utf8)
        let late = try await gone.waitForResult()
        XCTAssertEqual(late, .success)
        // Without a readable process there is nothing to watch: only a result ends the wait.
        var unknown: [(contents: String, session: StayAwakeSetup.Session, wait: Task<StayAwakeSetup.Result, Error>)] = []
        for contents in ["", "soon\n", "0\n", "-1\n"] {
            let session = StayAwakeSetup.Session(folder: try folder())
            try contents.write(to: session.processFile, atomically: true, encoding: .utf8)
            unknown.append((contents, session, Task { try await session.waitForResult() }))
        }
        try await Task.sleep(for: .milliseconds(300))
        for entry in unknown { try "success\n".write(to: entry.session.resultFile, atomically: true, encoding: .utf8) }
        for entry in unknown {
            let value = try await entry.wait.value
            XCTAssertEqual(value, .success, entry.contents)
        }
    }

    func testTheGuideEndsInOrderAfterFrogStoppedWaitingAndRemovedItsFolder() throws {
        let session = try StayAwakeSetup.prepare(.setup, directory: try folder())
        let script = try folder().appendingPathComponent("StayAwakeSetup.command")
        try FileManager.default.copyItem(at: session.folder.appendingPathComponent("StayAwakeSetup.command"), to: script)
        session.remove()
        let output = Pipe()
        let guide = Process()
        guide.executableURL = URL(fileURLWithPath: "/bin/bash")
        // An unknown mode ends the guide as failed at once, before any question or sudo.
        guide.arguments = [script.path, "neither", session.resultFile.path]
        guide.standardInput = FileHandle.nullDevice
        guide.standardOutput = output; guide.standardError = output
        try guide.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guide.waitUntilExit()
        XCTAssertEqual(guide.terminationStatus, 1)
        XCTAssertTrue(text.contains("Press Enter to close this guide"), "A result that cannot be written must not cut off what the guide still has to say: \(text)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.folder.path))
    }

    func testAGuideThatNeverReportsCanBeCancelledAndStartedAgain() async throws {
        let system = AccessPowerFixture()
        var sessions: [StayAwakeSetup.Session] = []
        for _ in 0..<2 { sessions.append(StayAwakeSetup.Session(folder: try folder())) }
        let pending = sessions
        let power = StayAwakeController(system: system, directory: try folder(), openGuide: { _ in pending[await system.noteGuide()] })
        await power.refresh()
        for (index, session) in sessions.enumerated() {
            power.configureAccess()
            try await waitUntil { await system.guides == index + 1 }
            XCTAssertTrue(power.isConfiguringAccess)
            power.configureAccess()
            await system.allowAccess(index == 1)
            power.cancelAccessGuide()
            await power.waitForAccessGuide()
            XCTAssertFalse(power.isConfiguringAccess, "Setup can be tried again without restarting Frog")
            XCTAssertEqual(power.accessNotice, "Stopped waiting for the guide. Close its Terminal window if it is still open.")
            XCTAssertFalse(FileManager.default.fileExists(atPath: session.folder.path), "The guide's folder goes when nothing waits for it")
            XCTAssertEqual(power.accessState, index == 1 ? .ready : .needsSetup, "What the guide changed before the wait ended is read")
        }
        let guides = await system.guides
        XCTAssertEqual(guides, 2)
        power.cancelAccessGuide()
        XCTAssertFalse(power.isConfiguringAccess)
    }

    func testARunningSessionCanBeSwitchedOffWhileAGuideIsOpen() async throws {
        let system = AccessPowerFixture(allowed: true)
        let pending = StayAwakeSetup.Session(folder: try folder())
        let power = StayAwakeController(system: system, directory: try folder(), openGuide: { _ in _ = await system.noteGuide(); return pending })
        XCTAssertFalse(power.canSwitch, "Nothing is known before the first read")
        await power.refresh()
        XCTAssertTrue(power.canSwitch)
        power.setEnabled(true); await power.waitForOperation()
        XCTAssertTrue(power.isEnabled)
        power.configureAccess()
        try await waitUntil { await system.guides == 1 }
        XCTAssertTrue(power.isConfiguringAccess)
        XCTAssertTrue(power.canSwitch, "An open guide must not keep a running session from being ended")
        power.setEnabled(false); await power.waitForOperation()
        XCTAssertFalse(power.isEnabled)
        XCTAssertFalse(power.canSwitch, "Switching on waits until the guide has finished")
        power.setEnabled(true); await power.waitForOperation()
        XCTAssertFalse(power.isEnabled)
        power.cancelAccessGuide(); await power.waitForAccessGuide()
        XCTAssertTrue(power.canSwitch)
        let writes = await system.writes
        XCTAssertEqual(writes, [true, false])
    }

    func testCancellingAResetBeforeItsGuideOpensOpensNoGuide() async throws {
        let system = AccessPowerFixture(allowed: true)
        let power = StayAwakeController(system: system, directory: try folder(), openGuide: { _ in
            _ = await system.noteGuide()
            throw StayAwakeError.command
        })
        await power.refresh()
        power.setEnabled(true); await power.waitForOperation()
        XCTAssertTrue(power.isEnabled)
        // The reset first restores sleep; Cancel arrives before that task has run at all.
        power.configureAccess(.reset)
        power.cancelAccessGuide()
        await power.waitForAccessGuide()
        XCTAssertFalse(power.isConfiguringAccess)
        XCTAssertFalse(power.isEnabled, "The restore that Reset began is finished, not abandoned half way")
        XCTAssertFalse(power.ownsSession)
        XCTAssertEqual(power.accessNotice, "Sleep restored. Access guide cancelled.")
        let guides = await system.guides
        XCTAssertEqual(guides, 0, "Nothing would wait for a Terminal window that opens after Cancel")
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

    /// Runs the guide as Terminal would, without a window.
    private func runGuide(_ session: StayAwakeSetup.Session, arguments: [String], answers: Any) throws -> Process {
        let guide = Process()
        guide.executableURL = URL(fileURLWithPath: "/bin/bash")
        guide.arguments = [session.folder.appendingPathComponent("StayAwakeSetup.command").path] + arguments
        guide.standardInput = answers
        guide.standardOutput = FileHandle.nullDevice; guide.standardError = FileHandle.nullDevice
        try guide.run()
        return guide
    }

    /// As `kill -9` would. A process that has ended is left alone: its id may be in use again.
    private func stop(_ guide: Process) {
        if guide.isRunning { kill(guide.processIdentifier, SIGKILL) }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<2500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for the access guide")
    }
}

private actor AccessPowerFixture: StayAwakeSystem {
    private var allowed: Bool
    private var enabled = false
    private var writesDenied = false
    private var checksFail = false
    private var nextCheck: AccessCheckGate?
    private(set) var writes: [Bool] = []
    private(set) var guides = 0
    init(allowed: Bool = false) { self.allowed = allowed }
    func allowAccess(_ allowed: Bool) { self.allowed = allowed }
    func denyWrites() { writesDenied = true }
    func failChecks() { checksFail = true }
    func holdNextCheck(_ gate: AccessCheckGate) { nextCheck = gate }
    /// Counts the guides that were opened and returns the index of this one.
    func noteGuide() -> Int { guides += 1; return guides - 1 }
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
