import AppKit
import Combine
import SwiftUI
import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class StayAwakeTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
    }
    private func directory() -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(value); return value
    }

    func testStartsOffAndNeverEnablesAtLaunchOrRefresh() async {
        let system = PowerFixture()
        let power = StayAwakeController(system: system, directory: directory())
        XCTAssertFalse(power.isEnabled)
        XCTAssertEqual(power.duration, .fourHours)
        power.start(); await power.waitForOperation()
        await power.refresh()
        XCTAssertFalse(power.isEnabled)
        XCTAssertTrue(power.hasReadState)
        let writes = await system.writes
        XCTAssertTrue(writes.isEmpty)
        let canQuit = await power.prepareToQuit()
        XCTAssertTrue(canQuit)
    }

    func testPermissionDeniedDoesNotPretendToEnableOrLeaveASession() async {
        let system = PowerFixture()
        await system.denyWrites(true)
        let directory = directory()
        let power = StayAwakeController(system: system, directory: directory)
        await power.refresh()
        power.setEnabled(true); await power.waitForOperation()
        XCTAssertFalse(power.isEnabled)
        XCTAssertFalse(power.isBusy)
        XCTAssertTrue(power.needsSetup)
        XCTAssertNotNil(power.error)
        XCTAssertFalse(power.ownsSession)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("stay-awake-session.json").path))
    }

    func testFourHourSessionExpiresAndCanBeStartedAgain() async {
        let system = PowerFixture()
        var now = Date(timeIntervalSince1970: 1000)
        let power = StayAwakeController(system: system, directory: directory(), now: { now })
        await power.refresh()
        power.setEnabled(true); await power.waitForOperation()
        XCTAssertTrue(power.isEnabled)
        XCTAssertEqual(power.deadline, now.addingTimeInterval(4 * 3600))
        now.addTimeInterval(4 * 3600 - 1)
        await power.refresh()
        XCTAssertTrue(power.isEnabled)
        now.addTimeInterval(1)
        await power.refresh()
        XCTAssertFalse(power.isEnabled)
        XCTAssertNil(power.deadline)
        XCTAssertEqual(power.notice, "Timer finished · Sleep restored")
        power.setEnabled(true); await power.waitForOperation()
        XCTAssertTrue(power.isEnabled)
        let canQuit = await power.prepareToQuit()
        XCTAssertTrue(canQuit)
        let writes = await system.writes
        XCTAssertEqual(writes, [true, false, true, false])
    }

    func testLowBatteryOnlyStopsOnBatteryPower() async {
        let system = PowerFixture()
        let power = StayAwakeController(system: system, directory: directory())
        await power.refresh()
        power.setEnabled(true); await power.waitForOperation()
        await system.setBattery(onBattery: false, percent: 10)
        await power.refresh()
        XCTAssertTrue(power.isEnabled)
        await system.setBattery(onBattery: true, percent: 20)
        await power.refresh()
        XCTAssertTrue(power.isEnabled)
        await system.setBattery(onBattery: true, percent: 19)
        await power.refresh()
        XCTAssertFalse(power.isEnabled)
        XCTAssertEqual(power.notice, "Low battery · Sleep restored")
        power.setEnabled(true); await power.waitForOperation()
        XCTAssertFalse(power.isEnabled)
        XCTAssertTrue(power.error?.contains("20%") == true)
        let writes = await system.writes
        XCTAssertEqual(writes, [true, false])
    }

    func testQuitWaitsForInFlightEnableThenRestoresSleep() async {
        let system = PowerFixture()
        let power = StayAwakeController(system: system, directory: directory())
        await power.refresh()
        power.setEnabled(true)
        let canQuit = await power.prepareToQuit()
        XCTAssertTrue(canQuit)
        XCTAssertFalse(power.isEnabled)
        XCTAssertFalse(power.ownsSession)
        let writes = await system.writes
        XCTAssertEqual(writes, [true, false])
    }

    func testQuitFailureRetainsOwnershipAndAllowsRetry() async {
        let system = PowerFixture()
        let power = StayAwakeController(system: system, directory: directory())
        await power.refresh()
        power.setEnabled(true); await power.waitForOperation()
        await system.denyWrites(true)
        let firstQuit = await power.prepareToQuit()
        XCTAssertFalse(firstQuit)
        XCTAssertTrue(power.isEnabled)
        XCTAssertTrue(power.ownsSession)
        await system.denyWrites(false)
        let secondQuit = await power.prepareToQuit()
        XCTAssertTrue(secondQuit)
        XCTAssertFalse(power.isEnabled)
    }

    func testRestartCleansUpAnInterruptedOwnedSessionButNotAnotherAppsSetting() async throws {
        let system = PowerFixture()
        let folder = directory()
        let old = StayAwakeController(system: system, directory: folder)
        await old.refresh()
        old.setEnabled(true); await old.waitForOperation()
        let restarted = StayAwakeController(system: system, directory: folder)
        restarted.start(); await restarted.waitForOperation()
        XCTAssertFalse(restarted.isEnabled)
        XCTAssertFalse(restarted.ownsSession)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("stay-awake-session.json").path))
        let other = PowerFixture(enabled: true)
        let observer = StayAwakeController(system: other, directory: directory())
        observer.start(); await observer.waitForOperation()
        XCTAssertTrue(observer.isEnabled, "Reflect a pre-existing system setting rather than showing a false off state")
        XCTAssertFalse(observer.ownsSession)
        let canQuit = await observer.prepareToQuit()
        XCTAssertTrue(canQuit)
        let writes = await other.writes
        XCTAssertTrue(writes.isEmpty, "Normal startup and quit must not overwrite another app's setting")
    }

    func testCommandSuccessStillRequiresSystemReadback() async {
        let system = PowerFixture()
        await system.ignoreWrites()
        let power = StayAwakeController(system: system, directory: directory())
        await power.refresh()
        power.setEnabled(true); await power.waitForOperation()
        XCTAssertFalse(power.isEnabled)
        XCTAssertNotNil(power.error)
        XCTAssertFalse(power.ownsSession)
    }

    func testFailedReadbackKeepsOwnershipUntilTheSettingCanBeVerified() async {
        let system = PowerFixture()
        let folder = directory()
        let power = StayAwakeController(system: system, directory: folder)
        await power.refresh()
        await system.failReadbackAfterWrite()
        power.setEnabled(true); await power.waitForOperation()
        XCTAssertFalse(power.hasReadState, "Do not display a stale off state after an unverified power command")
        XCTAssertTrue(power.ownsSession)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("stay-awake-session.json").path))
        await system.restoreReads()
        await power.refresh()
        XCTAssertTrue(power.isEnabled)
        let canQuit = await power.prepareToQuit()
        XCTAssertTrue(canQuit)
        XCTAssertFalse(power.isEnabled)
        XCTAssertFalse(power.ownsSession)
    }

    func testPowerOutputParsingUsesExactSettingAndRealPowerSource() throws {
        XCTAssertFalse(try NativeStayAwakeSystem.parseSleepDisabled("System-wide power settings:\nCurrently in use:\n sleep 1 (sleep prevented by powerd)"))
        XCTAssertTrue(try NativeStayAwakeSystem.parseSleepDisabled("System-wide power settings:\n SleepDisabled 1\nCurrently in use:\n sleep 1"))
        XCTAssertFalse(try NativeStayAwakeSystem.parseSleepDisabled("SleepDisabled 0"))
        XCTAssertThrowsError(try NativeStayAwakeSystem.parseSleepDisabled("SleepDisabled 11"))
        XCTAssertThrowsError(try NativeStayAwakeSystem.parseSleepDisabled("permission denied"))
        XCTAssertEqual(try NativeStayAwakeSystem.parseBattery("Now drawing from 'AC Power'\n -InternalBattery-0 9%; charging;"), PowerBattery(onBattery: false, percent: 9))
        XCTAssertEqual(try NativeStayAwakeSystem.parseBattery("Now drawing from 'Battery Power'\n -InternalBattery-0 19%; discharging;"), PowerBattery(onBattery: true, percent: 19))
        XCTAssertEqual(try NativeStayAwakeSystem.parseBattery("Now drawing from 'AC Power'"), PowerBattery(onBattery: false, percent: nil))
        XCTAssertThrowsError(try NativeStayAwakeSystem.parseBattery("Now drawing from 'Battery Power'\n unknown"))
    }

    func testNativeReadOnlyQueriesUseTheAsyncRunner() async throws {
        let system = NativeStayAwakeSystem()
        _ = try await system.hasAccess()
        _ = try await system.sleepDisabled()
        _ = try await system.battery()
    }

    func testPopupSizesToItsRowsWithoutGraphOrVerticalSpacers() async throws {
        _ = NSApplication.shared
        let model = AppModel(dataDirectory: directory(), registerShortcuts: false)
        defer { model.shutdown() }
        let power = StayAwakeController(system: PowerFixture(), directory: directory())
        await power.refresh()
        let host = NSHostingView(rootView: FrogStatusMenu(model: model, power: power))
        let size = host.fittingSize
        XCTAssertEqual(size.width, 292, accuracy: 1)
        XCTAssertLessThan(size.height, 275, "The default popup must hug its rows rather than expand into empty gaps")
        XCTAssertGreaterThan(size.height, 150)
    }

    func testNativePopupToggleStartsAndStopsAnExplicitSession() async throws {
        _ = NSApplication.shared
        let model = AppModel(dataDirectory: directory(), registerShortcuts: false)
        defer { model.shutdown() }
        let system = PowerFixture()
        let power = StayAwakeController(system: system, directory: directory())
        await power.refresh()
        let host = NSHostingView(rootView: FrogStatusMenu(model: model, power: power))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let control = try XCTUnwrap(descendants(host).compactMap { $0 as? NSSwitch }.first)
        for expected in [true, false] {
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(control.isEnabled)
            let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: host.superview)
            let hit = host.hitTest(point)
            XCTAssertTrue(hit === control || hit?.isDescendant(of: control) == true, "The popup switch must remain hittable")
            let changed = expectation(description: "Native switch changes the verified power state to \(expected)")
            let observation = power.$isEnabled.dropFirst().filter { $0 == expected }.prefix(1).sink { _ in changed.fulfill() }
            // Exercise the real native control action. A test's borderless window
            // does not have MenuBarExtra's activation/event-tracking lifecycle.
            control.performClick(nil)
            await fulfillment(of: [changed], timeout: 2)
            observation.cancel()
            await power.waitForOperation()
            XCTAssertEqual(power.isEnabled, expected)
        }
        let writes = await system.writes
        XCTAssertEqual(writes, [true, false])
    }

    func testLongErrorKeepsMenuCompactAndRecoversAfterDismissal() async throws {
        _ = NSApplication.shared
        let model = AppModel(dataDirectory: directory(), registerShortcuts: false)
        defer { model.shutdown() }
        let power = StayAwakeController(system: PowerFixture(), directory: directory())
        await power.refresh()
        let initial = NSHostingView(rootView: FrogStatusMenu(model: model, power: power)).fittingSize
        let error = Array(repeating: "Synthetic provider diagnostic with enough words to wrap on the menu.", count: 80).joined(separator: "\n")
        model.report(FrogError.message(error))
        let expanded = NSHostingView(rootView: FrogStatusMenu(model: model, power: power)).fittingSize
        XCTAssertEqual(expanded.width, initial.width, accuracy: 1)
        XCTAssertLessThan(expanded.height, initial.height + 90, "A long diagnostic must not push Open/Quit off the menu")
        XCTAssertEqual(model.recentErrors.first?.message, error, "The full diagnostic must remain available in Logs")
        model.dismissError()
        let recovered = NSHostingView(rootView: FrogStatusMenu(model: model, power: power)).fittingSize
        XCTAssertEqual(recovered.height, initial.height, accuracy: 1)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

private actor PowerFixture: StayAwakeSystem {
    private var enabled: Bool
    private var denied = false
    private var appliesWrites = true
    private var failAfterWrite = false
    private var readsFail = false
    private var currentBattery = PowerBattery(onBattery: false, percent: 80)
    private(set) var writes: [Bool] = []
    init(enabled: Bool = false) { self.enabled = enabled }
    func hasAccess() async throws -> Bool { !denied }
    func denyWrites(_ denied: Bool) { self.denied = denied }
    func ignoreWrites() { appliesWrites = false }
    func failReadbackAfterWrite() { failAfterWrite = true }
    func restoreReads() { failAfterWrite = false; readsFail = false }
    func setBattery(onBattery: Bool, percent: Int) { currentBattery = PowerBattery(onBattery: onBattery, percent: percent) }
    func sleepDisabled() async throws -> Bool {
        if readsFail { throw StayAwakeError.unreadable }
        return enabled
    }
    func battery() async throws -> PowerBattery { currentBattery }
    func setSleepDisabled(_ value: Bool) async throws {
        writes.append(value)
        if denied { throw StayAwakeError.permission }
        if appliesWrites { enabled = value }
        if failAfterWrite { readsFail = true }
    }
}
