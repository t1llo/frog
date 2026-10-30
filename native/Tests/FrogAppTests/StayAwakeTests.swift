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

    // MARK: A session: assertions only

    func testStartsOffAndHoldsNothingAtLaunchOrRefresh() async {
        let system = PowerFixture()
        let display = DisplayProbe()
        let power = StayAwakeController(system: system, directory: directory(), display: display)
        XCTAssertFalse(power.isEnabled)
        XCTAssertEqual(power.duration, .untilOff)
        XCTAssertEqual(power.statusText, "Off")
        power.start(); await power.waitForLid()
        await power.refresh()
        XCTAssertFalse(power.isEnabled)
        XCTAssertNil(display.held)
        let writes = await system.writes
        XCTAssertTrue(writes.isEmpty)
        let canQuit = await power.prepareToQuit()
        XCTAssertTrue(canQuit)
    }

    func testASessionNeedsNoSetupAndKeepsTheScreenOn() async {
        let system = PowerFixture()
        await system.denyWrites(true)
        let display = DisplayProbe()
        let power = StayAwakeController(system: system, directory: directory(), display: display)
        power.turnOn(); await power.waitForLid()
        XCTAssertTrue(power.isEnabled, "No sudoers rule is needed")
        XCTAssertNil(power.deadline)
        XCTAssertEqual(power.statusText, "On until turned off")
        XCTAssertEqual(display.held, true)
        XCTAssertEqual(display.screen, true)
        power.configure(keepScreenOn: false, lidClosed: false)
        XCTAssertEqual(display.screen, false, "Only the Mac stays awake; the screen may sleep and lock")
        power.turnOff(); await power.waitForLid()
        XCTAssertFalse(power.isEnabled)
        XCTAssertEqual(display.held, false)
        let writes = await system.writes
        XCTAssertTrue(writes.isEmpty, "The sleep setting is never touched")
        XCTAssertNil(power.error)
    }

    func testATimedSessionEndsAtItsDeadlineAndCanBeStartedAgain() async {
        var now = Date(timeIntervalSince1970: 1000)
        let display = DisplayProbe()
        let power = StayAwakeController(system: PowerFixture(), directory: directory(), now: { now }, display: display)
        power.duration = .hour
        power.turnOn()
        XCTAssertEqual(power.startedAt, now)
        XCTAssertEqual(power.deadline, now.addingTimeInterval(3600))
        now.addTimeInterval(3599)
        await power.refresh()
        XCTAssertTrue(power.isEnabled)
        now.addTimeInterval(1)
        await power.refresh()
        XCTAssertFalse(power.isEnabled)
        XCTAssertNil(power.deadline)
        XCTAssertEqual(display.held, false)
        power.turnOn(.minutes(180))
        XCTAssertEqual(power.deadline, now.addingTimeInterval(3 * 3600), "A length given for this session wins over the page's")
        XCTAssertEqual(power.duration, .hour)
        power.toggle()
        XCTAssertFalse(power.isEnabled)
    }

    func testTheDeadlineTimerEndsASessionByItself() async throws {
        let display = DisplayProbe()
        // The session starts at 1000; by the time the timer is set, its minute is already over, so it fires at once.
        var reads = 0
        let power = StayAwakeController(system: PowerFixture(), directory: directory(), now: {
            reads += 1
            return Date(timeIntervalSince1970: reads == 1 ? 1000 : 1120)
        }, display: display)
        let ended = expectation(description: "The session ends")
        let observation = power.$isEnabled.dropFirst().filter { !$0 }.prefix(1).sink { _ in ended.fulfill() }
        defer { observation.cancel() }
        power.turnOn(.minutes(1))
        XCTAssertTrue(power.isEnabled)
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertEqual(display.held, false)
    }

    func testNothingIsReadOrPolledUnlessLidClosedModeNeedsIt() async throws {
        let system = PowerFixture()
        let power = StayAwakeController(system: system, directory: directory(), monitorInterval: .milliseconds(5))
        power.start()
        power.turnOn(); await power.waitForLid()
        try await Task.sleep(for: .milliseconds(60))
        power.turnOff(); await power.waitForLid()
        var reads = await system.reads
        XCTAssertEqual(reads, 0, "A session of assertions reads no power setting and starts no monitor")

        power.configure(keepScreenOn: true, lidClosed: true)
        power.turnOn(); await power.waitForLid()
        try await Task.sleep(for: .milliseconds(60))
        reads = await system.reads
        XCTAssertGreaterThan(reads, 3, "While Frog owns the setting it is watched")
        power.turnOff(); await power.waitForLid()
        power.configure(keepScreenOn: true, lidClosed: false); await power.waitForLid()
        try await Task.sleep(for: .milliseconds(20))
        let settled = await system.reads
        try await Task.sleep(for: .milliseconds(60))
        reads = await system.reads
        XCTAssertEqual(reads, settled, "The monitor stops with lid-closed mode")
    }

    func testLengthsParseMinutesHoursAndClockTimes() {
        XCTAssertEqual(StayAwakeLength(""), .untilOff)
        XCTAssertEqual(StayAwakeLength("until-off"), .untilOff)
        XCTAssertEqual(StayAwakeLength("90"), .minutes(90))
        XCTAssertEqual(StayAwakeLength("45m"), .minutes(45))
        XCTAssertEqual(StayAwakeLength("1h"), .minutes(60))
        XCTAssertEqual(StayAwakeLength("3H"), .minutes(180))
        XCTAssertEqual(StayAwakeLength("1h30m"), .minutes(90))
        XCTAssertEqual(StayAwakeLength("1h30"), .minutes(90))
        XCTAssertEqual(StayAwakeLength("168h"), .minutes(7 * 24 * 60), "A week is the longest")
        XCTAssertEqual(StayAwakeLength("until 17:30"), .until(hour: 17, minute: 30))
        XCTAssertEqual(StayAwakeLength("08:05"), .until(hour: 8, minute: 5))
        for wrong in ["soon", "0", "-5", "25:00", "12:60", "1x", "h", "99999", "168h1m", "999999999999999999h", "999999999999999999m",
                      "9223372036854775807", "99999999999999999999h", "1h999999999999999999"] {
            XCTAssertNil(StayAwakeLength(wrong), wrong)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let evening = Date(timeIntervalSince1970: 18 * 3600) // 1 January 1970, 18:00 UTC
        XCTAssertEqual(StayAwakeLength.until(hour: 17, minute: 30).deadline(from: evening, calendar: calendar),
                       Date(timeIntervalSince1970: 24 * 3600 + 17.5 * 3600), "A time already past is tomorrow's")
        XCTAssertEqual(StayAwakeLength.until(hour: 19, minute: 0).deadline(from: evening, calendar: calendar),
                       Date(timeIntervalSince1970: 19 * 3600))
        XCTAssertNil(StayAwakeLength.untilOff.deadline(from: evening))
    }

    // MARK: With the lid closed: the sleep setting, only in that mode

    func testLidClosedModeSwitchesTheSleepSettingWithTheSession() async {
        let system = PowerFixture()
        let power = StayAwakeController(system: system, directory: directory())
        power.configure(keepScreenOn: true, lidClosed: true)
        power.turnOn(); await power.waitForLid()
        XCTAssertTrue(power.lid.ownsSession)
        XCTAssertTrue(power.lid.isEnabled)
        power.turnOff(); await power.waitForLid()
        XCTAssertFalse(power.lid.ownsSession)
        var writes = await system.writes
        XCTAssertEqual(writes, [true, false])

        // Turning the mode off during a session restores sleep; the session goes on.
        power.turnOn(); await power.waitForLid()
        power.configure(keepScreenOn: true, lidClosed: false); await power.waitForLid()
        XCTAssertTrue(power.isEnabled)
        XCTAssertFalse(power.lid.ownsSession)
        writes = await system.writes
        XCTAssertEqual(writes, [true, false, true, false])
        power.turnOff()
    }

    func testLidClosedModeWithoutSetupStillKeepsTheMacAwake() async {
        let system = PowerFixture()
        await system.denyWrites(true)
        let display = DisplayProbe()
        let power = StayAwakeController(system: system, directory: directory(), display: display)
        power.configure(keepScreenOn: true, lidClosed: true)
        power.turnOn(); await power.waitForLid()
        XCTAssertTrue(power.isEnabled)
        XCTAssertEqual(display.held, true)
        XCTAssertFalse(power.lid.ownsSession)
        XCTAssertEqual(power.notice, "Lid closed needs setup")
        let writes = await system.writes
        XCTAssertTrue(writes.isEmpty, "Without access nothing is tried")
        power.turnOff(); await power.waitForLid()
    }

    // MARK: The lid-closed engine

    func testPermissionDeniedDoesNotPretendToEnableOrLeaveASession() async {
        let system = PowerFixture()
        await system.denyWrites(true)
        let directory = directory()
        let power = LidClosedSleep(system: system, directory: directory)
        await power.refresh()
        power.setEnabled(true); await power.waitForOperation()
        XCTAssertFalse(power.isEnabled)
        XCTAssertFalse(power.isBusy)
        XCTAssertTrue(power.needsSetup)
        XCTAssertNotNil(power.error)
        XCTAssertFalse(power.ownsSession)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("stay-awake-session.json").path))
    }

    func testLowBatteryOnlyStopsOnBatteryPower() async {
        let system = PowerFixture()
        let power = LidClosedSleep(system: system, directory: directory())
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
        let power = LidClosedSleep(system: system, directory: directory())
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
        let power = LidClosedSleep(system: system, directory: directory())
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
        let old = LidClosedSleep(system: system, directory: folder)
        await old.refresh()
        old.setEnabled(true); await old.waitForOperation()
        let restarted = LidClosedSleep(system: system, directory: folder)
        restarted.start(); await restarted.waitForOperation()
        XCTAssertFalse(restarted.isEnabled)
        XCTAssertFalse(restarted.ownsSession)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("stay-awake-session.json").path))
        let other = PowerFixture(enabled: true)
        let observer = LidClosedSleep(system: other, directory: directory())
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
        let power = LidClosedSleep(system: system, directory: directory())
        await power.refresh()
        power.setEnabled(true); await power.waitForOperation()
        XCTAssertFalse(power.isEnabled)
        XCTAssertNotNil(power.error)
        XCTAssertFalse(power.ownsSession)
    }

    func testFailedReadbackKeepsOwnershipUntilTheSettingCanBeVerified() async {
        let system = PowerFixture()
        let folder = directory()
        let power = LidClosedSleep(system: system, directory: folder)
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
        let battery: (Int) -> [String: Any] = { ["Type": "InternalBattery", "Current Capacity": $0, "Max Capacity": 100] }
        XCTAssertEqual(try NativeStayAwakeSystem.battery(PowerSources(providing: "AC Power", descriptions: [battery(9)])), PowerBattery(onBattery: false, percent: 9))
        XCTAssertEqual(try NativeStayAwakeSystem.battery(PowerSources(providing: "Battery Power", descriptions: [battery(19)])), PowerBattery(onBattery: true, percent: 19))
        XCTAssertEqual(try NativeStayAwakeSystem.battery(PowerSources(providing: "AC Power", descriptions: [])), PowerBattery(onBattery: false, percent: nil))
        XCTAssertThrowsError(try NativeStayAwakeSystem.battery(PowerSources(providing: "Battery Power", descriptions: [["Type": "InternalBattery"]])))
    }

    func testNativeReadOnlyQueriesUseTheAsyncRunner() async throws {
        let system = NativeStayAwakeSystem()
        _ = try await system.hasAccess()
        _ = try await system.sleepDisabled()
        _ = try await system.battery()
    }

    func testPopupSizesToItsRowsWithoutGraphOrVerticalSpacers() async throws {
        _ = NSApplication.shared
        let power = StayAwakeController(system: PowerFixture(), directory: directory())
        let model = AppModel(dataDirectory: directory(), registerShortcuts: false, powerController: power)
        defer { model.shutdown() }
        await model.pluginHost.syncAndWait()
        await power.refresh()
        let host = NSHostingView(rootView: FrogStatusMenu(model: model))
        let size = host.fittingSize
        XCTAssertEqual(size.width, 292, accuracy: 1)
        XCTAssertLessThan(size.height, 275, "The default popup must hug its rows rather than expand into empty gaps")
        XCTAssertGreaterThan(size.height, 150)
    }

    func testNativePopupToggleStartsAndStopsAnExplicitSession() async throws {
        _ = NSApplication.shared
        let system = PowerFixture()
        let power = StayAwakeController(system: system, directory: directory())
        let model = AppModel(dataDirectory: directory(), registerShortcuts: false, powerController: power)
        defer { model.shutdown() }
        await model.pluginHost.syncAndWait()
        await power.refresh()
        let host = NSHostingView(rootView: FrogStatusMenu(model: model))
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
            await power.waitForLid()
            XCTAssertEqual(power.isEnabled, expected)
        }
        let writes = await system.writes
        XCTAssertEqual(writes, [], "The popup's switch holds assertions only")
    }

    func testLongErrorKeepsMenuCompactAndRecoversAfterDismissal() async throws {
        _ = NSApplication.shared
        let power = StayAwakeController(system: PowerFixture(), directory: directory())
        let model = AppModel(dataDirectory: directory(), registerShortcuts: false, powerController: power)
        defer { model.shutdown() }
        await model.pluginHost.syncAndWait()
        await power.refresh()
        let initial = NSHostingView(rootView: FrogStatusMenu(model: model)).fittingSize
        let error = Array(repeating: "Synthetic provider diagnostic with enough words to wrap on the menu.", count: 80).joined(separator: "\n")
        model.report(FrogError.message(error))
        let expanded = NSHostingView(rootView: FrogStatusMenu(model: model)).fittingSize
        XCTAssertEqual(expanded.width, initial.width, accuracy: 1)
        XCTAssertLessThan(expanded.height, initial.height + 90, "A long diagnostic must not push Open/Quit off the menu")
        XCTAssertEqual(model.recentErrors.first?.message, error, "The full diagnostic must remain available in Logs")
        model.dismissError()
        let recovered = NSHostingView(rootView: FrogStatusMenu(model: model)).fittingSize
        XCTAssertEqual(recovered.height, initial.height, accuracy: 1)
    }

    /// `stayAwake-on-*.png`: a session until a time, with lid-closed mode waiting for its setup.
    func testPageShotOfARunningSession() async throws {
        guard ProcessInfo.processInfo.environment["FROG_PAGE_SHOTS"] != nil else { throw XCTSkip("Set FROG_PAGE_SHOTS") }
        let system = PowerFixture()
        await system.denyWrites(true)
        let power = StayAwakeController(system: system, directory: directory())
        let model = AppModel(dataDirectory: directory(), registerShortcuts: false, powerController: power)
        defer { model.shutdown() }
        await model.pluginHost.syncAndWait()
        let plugin = try XCTUnwrap(model.pluginHost.running["stay-awake"] as? StayAwakePlugin)
        plugin.update { $0.duration = .untilTime; $0.until = "17:30"; $0.lidClosed = true; $0.menuBarItem = true }
        power.turnOn(); await power.waitForLid()
        await power.lid.refreshAccess(force: true)
        try await savePluginPageShot("stayAwake-on", model: model, height: 900) { plugin.page()! }
        power.turnOff(); await power.waitForLid()
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
    private(set) var reads = 0
    func sleepDisabled() async throws -> Bool {
        reads += 1
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

@MainActor private final class DisplayProbe: DisplayAwakeHolding {
    var held: Bool?
    var screen: Bool?
    func hold(_ on: Bool, screen: Bool) { held = on; self.screen = on ? screen : nil }
}
