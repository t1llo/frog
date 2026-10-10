import AppKit
import ApplicationServices
import XCTest
@testable import FrogApp

@MainActor
final class WindowSpacesTests: XCTestCase {
    func testCachedAXTargetAlsoPreparesItsSpaceForCallersWithoutSeparatePreparation() async {
        let trace = SpaceActivationTrace()
        let element = AXUIElementCreateApplication(1010)
        var writer = WindowActivationExecutor.Writer()
        writer.isTrusted = { true }
        writer.reveal = { _, _, _ in trace.append("space"); return true }
        writer.isWindow = { _ in trace.events.contains("space") }
        writer.isMinimized = { _ in false }
        writer.raise = { _ in trace.append("raise"); return true }
        writer.makeMain = { _ in }
        let executor = WindowActivationExecutor(writer: writer)
        let result = await executor.raise(.init(id: UUID(), pid: 10, element: element, windowID: 202), isCurrent: { true })
        XCTAssertTrue(result)
        XCTAssertEqual(trace.events, ["space", "raise"], "A retained AX handle does not prove its Space is visible")
    }

    func testStaleAXReferenceIsResolvedByExactNativeWindowIDBeforeRaising() async {
        let old = AXUIElementCreateApplication(1010), fresh = AXUIElementCreateApplication(1020)
        var writer = WindowActivationExecutor.Writer()
        writer.isTrusted = { true }
        writer.reveal = { _, current, _ in current() }
        writer.isWindow = { $0.element.map { CFEqual($0, fresh) } ?? false }
        writer.isMinimized = { _ in false }
        writer.resolve = { id, pid in
            XCTAssertEqual(id, 202); XCTAssertEqual(pid, 10)
            return fresh
        }
        writer.raise = { target in
            XCTAssertTrue(target.element.map { CFEqual($0, fresh) } ?? false)
            return true
        }
        writer.makeMain = { _ in }
        let executor = WindowActivationExecutor(writer: writer)
        let result = await executor.raise(.init(id: UUID(), pid: 10, element: old, windowID: 202), isCurrent: { true })
        XCTAssertTrue(result)
    }

    func testCancellationDuringSpacePreparationCannotResolveOrRaiseLater() async {
        let gate = SpacePreparationGate()
        var writer = WindowActivationExecutor.Writer()
        writer.isTrusted = { true }
        writer.reveal = { _, _, _ in await gate.wait(); return true }
        writer.resolve = { _, _ in XCTFail("Cancelled Space handoff must not resolve a late AX window"); return nil }
        writer.raise = { _ in XCTFail("Cancelled Space handoff must not steal focus"); return true }
        let executor = WindowActivationExecutor(writer: writer)
        let task = Task { await executor.prepare(.init(id: UUID(), pid: 10, element: nil, windowID: 202), isCurrent: { true }) }
        await gate.started()
        task.cancel()
        await gate.release()
        let result = await task.value
        XCTAssertFalse(result)
    }

    func testSpaceChangeInvalidatesFreshnessWithoutDroppingWarmRows() async {
        let cache = WindowSwitcherCache()
        let window = SwitcherWindow(id: UUID(), pid: 10, appName: "Synthetic", title: "Remote", minimized: false, hidden: false, windowID: 202)
        _ = await cache.update { .init(windows: [window], current: window.id) }
        XCTAssertFalse(cache.needsRefresh())
        cache.invalidate()
        XCTAssertTrue(cache.needsRefresh())
        XCTAssertEqual(cache.readySnapshot(frontPID: 10)?.windows, [window])
    }

    func testNativeSpaceSelectionFocusesExactOwnedWindowThroughActivationPath() async throws {
        guard ProcessInfo.processInfo.environment["FROG_RUN_SPACE_FIXTURE"] == "1" else { throw XCTSkip("Opt-in native Spaces fixture") }
        let spaces = try OwnedSpaceFixture()
        let local = makeWindow("Frog synthetic local")
        let remote = makeWindow("Frog synthetic remote")
        let previous = NSWorkspace.shared.frontmostApplication
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        defer {
            local.close(); remote.close()
            spaces.restore()
            if NSApp.isActive { _ = previous?.activate(options: []) }
            NSApp.setActivationPolicy(policy)
        }
        local.makeKeyAndOrderFront(nil); remote.orderFrontRegardless()
        spaces.putOnSource(CGWindowID(local.windowNumber))
        spaces.putOnSource(CGWindowID(remote.windowNumber))
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(100))
        guard NSApp.isActive, local.isKeyWindow else {
            throw XCTSkip("xctest cannot become a foreground GUI app in this session; use the standalone synthetic .app focus probe")
        }
        spaces.park(CGWindowID(remote.windowNumber))
        try await Task.sleep(for: .milliseconds(100))
        let pid = ProcessInfo.processInfo.processIdentifier
        let id = CGWindowID(remote.windowNumber)
        let token = AXUIElementCreateApplication(pid)
        let reader = WindowCatalog.Reader(isTrusted: { true }, windows: { _ in .success([]) }, focusedWindow: { _ in nil })
        var writer = WindowActivationExecutor.Writer()
        writer.isTrusted = { true }
        writer.resolve = { selected, owner in selected == id && owner == pid ? token : nil }
        writer.isWindow = { $0.windowID == id }
        writer.isMinimized = { _ in false }
        // Only the AX boundary is substituted: the real native NSWindow receives
        // the final focus operation, on the real destination Space.
        writer.raise = { _ in DispatchQueue.main.sync { remote.makeKeyAndOrderFront(nil); return true } }
        writer.makeMain = { _ in }
        let catalog = WindowCatalog(reader: reader, writer: writer)
        let snapshot = await catalog.snapshot(applications: [.init(pid: pid, name: "Synthetic fixture", hidden: false)], frontPID: nil)
        let selected = try XCTUnwrap(snapshot.windows.first { $0.windowID == id })
        let start = ContinuousClock.now
        let result = await WindowActivation.perform(raise: { await catalog.raise(id: selected.id) }, request: {
            NSApp.activate(ignoringOtherApps: true); return true
        }, bringForward: { false }, isFrontmost: { NSApp.isActive }, prepare: {
            let prepared = await catalog.prepareActivation(id: selected.id)
            return prepared
        })
        XCTAssertTrue(result)
        XCTAssertTrue(remote.isOnActiveSpace)
        XCTAssertTrue(remote.isKeyWindow)
        XCTAssertFalse(local.isOnActiveSpace, "Selection must travel to the target, never move it onto the source desktop")
        print("SPACES FIXTURE native destination + exact owned-window focus: \(start.duration(to: .now))")
    }

    func testRemoteInventoryKeepsIdentityAcrossAXOmissionAndReturn() async throws {
        let fixture = SpaceCatalogFixture()
        let catalog = WindowCatalog(reader: fixture.reader)
        let first = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        let remote = try XCTUnwrap(first.windows.first { $0.windowID == 202 })
        fixture.parked = true
        let parked = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertEqual(parked.windows.count, 2)
        XCTAssertEqual(parked.windows.first { $0.windowID == 202 }?.id, remote.id)
        XCTAssertEqual(parked.windows.first { $0.windowID == 202 }?.title, "Synthetic remote", "Unavailable WindowServer titles reuse AX metadata")
        fixture.parked = false
        let returned = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertEqual(returned.windows.first { $0.windowID == 202 }?.id, remote.id)
        fixture.closed = true
        let closed = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertEqual(closed.windows.map(\.windowID), [101])
    }

    func testColdOffSpaceWindowNeedsNeitherPriorAXIdentityNorScreenRecordingTitle() async {
        let fixture = SpaceCatalogFixture()
        fixture.parked = true
        let catalog = WindowCatalog(reader: fixture.reader)
        let result = await catalog.snapshot(applications: fixture.apps, frontPID: nil)
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertEqual(result.windows.first { $0.windowID == 202 }?.title, "Window on another Desktop")
        let absent = await catalog.snapshot(applications: [], frontPID: nil)
        XCTAssertTrue(absent.windows.isEmpty, "Supplemental records cannot resurrect departed owners")
    }

    func testSpacePreparationMustFinishBeforeApplicationActivationAndCannotContinueAfterCancellation() async {
        var events: [String] = []
        var current = true
        let result = await WindowActivation.perform(raise: { events.append("raise"); return true },
            request: { events.append("activate"); return true }, bringForward: { events.append("forward"); return true },
            isFrontmost: { false }, prepare: { events.append("space"); current = false; return true },
            isCurrent: { current }, pause: {})
        XCTAssertFalse(result)
        XCTAssertEqual(events, ["space"], "Input cancellation during a Space transition must prevent late focus changes")
    }

    func testNativeDirectSpaceSelectionCapability() async throws {
        guard ProcessInfo.processInfo.environment["FROG_RUN_SPACE_FIXTURE"] == "1" else { throw XCTSkip("Opt-in native Spaces fixture") }
        let spaces = try OwnedSpaceFixture()
        defer { spaces.restore() }
        try spaces.selectDestination()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(spaces.destinationIsVisible(), "The native API must actually select the requested existing desktop")
    }
    /// Opt-in: uses two existing ordinary desktops and moves only this process's
    /// synthetic window. It never creates desktops or changes Mission Control.
    func testNativeWindowServerSpaceOmissionReachesCatalog() async throws {
        guard ProcessInfo.processInfo.environment["FROG_RUN_SPACE_FIXTURE"] == "1" else {
            throw XCTSkip("Opt-in native Spaces fixture")
        }
        let spaces = try OwnedSpaceFixture()
        let local = makeWindow("Frog synthetic local")
        let remote = makeWindow("Frog synthetic remote")
        defer { local.close(); remote.close() }
        local.orderFrontRegardless(); remote.orderFrontRegardless()
        spaces.putOnSource(CGWindowID(local.windowNumber))
        spaces.putOnSource(CGWindowID(remote.windowNumber))
        try await Task.sleep(for: .milliseconds(100))
        let pid = ProcessInfo.processInfo.processIdentifier
        var reader = WindowCatalog.Reader()
        // XCTest can lack access to its own AX inventory. Replay the local-only
        // AX boundary while keeping real WindowServer windows and actual
        // existing-Space membership; the standalone app exercises native AX.
        let localElement = AXUIElementCreateApplication(pid)
        reader.isTrusted = { true }
        reader.windows = { _ in .success([localElement]) }
        reader.focusedWindow = { _ in nil }
        reader.metadata = { _ in .success(.init(title: "Frog synthetic local")) }
        let catalog = WindowCatalog(reader: reader)
        let apps = [SwitcherApplication(pid: pid, name: "Frog synthetic fixture", hidden: false)]
        let before = await catalog.snapshot(applications: apps, frontPID: nil)
        spaces.park(CGWindowID(remote.windowNumber))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(spaces.isParked(CGWindowID(remote.windowNumber)), "Fixture must really occupy the other existing desktop")
        let server = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let owned = server.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }
        XCTAssertTrue(owned.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == remote.windowNumber },
                      "The remote synthetic window must really remain in WindowServer's inventory")
        let snapshot = await catalog.snapshot(applications: apps, frontPID: nil)
        print("SPACES FIXTURE owned rows before=\(before.windows.count), after parking=\(snapshot.windows.count)")
        XCTAssertTrue(snapshot.windows.contains(where: { $0.title == "Frog synthetic local" }))
        XCTAssertTrue(snapshot.windows.contains(where: { $0.title == "Frog synthetic remote" }),
                      "The real catalog must keep an existing user window on another Space")
    }

    private func makeWindow(_ title: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 220, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed]
        return window
    }
}

private actor SpacePreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func started() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class SpaceActivationTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var events: [String] { lock.withLock { values } }
    func append(_ event: String) { lock.withLock { values.append(event) } }
}

private final class SpaceCatalogFixture: @unchecked Sendable {
    let local = AXUIElementCreateApplication(1010)
    let remote = AXUIElementCreateApplication(1020)
    let apps = [SwitcherApplication(pid: 10, name: "Synthetic fixture", hidden: false)]
    private let lock = NSLock()
    private var isParked = false
    private var isClosed = false
    var parked: Bool { get { lock.withLock { isParked } } set { lock.withLock { isParked = newValue } } }
    var closed: Bool { get { lock.withLock { isClosed } } set { lock.withLock { isClosed = newValue } } }
    var reader: WindowCatalog.Reader {
        .init(isTrusted: { true }, windows: { [self] _ in .success(parked || closed ? [local] : [local, remote]) }, focusedWindow: { _ in nil },
              metadata: { [self] element in .success(.init(title: CFEqual(element, local) ? "Synthetic local" : "Synthetic remote")) },
              windowID: { [self] element in CFEqual(element, local) ? 101 : 202 },
              offSpaceWindows: { [self] _ in parked && !closed ? [.init(id: 202, pid: 10, title: nil)] : [] })
    }
}

private struct OwnedSpaceFixture {
    private typealias Connection = @convention(c) () -> UInt32
    private typealias Displays = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    private typealias Move = @convention(c) (UInt32, CFArray, UInt64) -> Void
    private typealias Membership = @convention(c) (UInt32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias Select = @convention(c) (UInt32, CFString, UInt64) -> Void
    private let connection: UInt32
    private let destination: UInt64
    private let move: Move
    private let membership: Membership
    private let display: CFString
    private let original: UInt64
    private let topology: Displays

    init() throws {
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connectionSymbol = dlsym(handle, "CGSMainConnectionID"),
              let displaysSymbol = dlsym(handle, "CGSCopyManagedDisplaySpaces"),
              let moveSymbol = dlsym(handle, "CGSMoveWindowsToManagedSpace"),
              let membershipSymbol = dlsym(handle, "CGSCopySpacesForWindows") else {
            throw XCTSkip("Native Spaces fixture APIs unavailable")
        }
        connection = unsafeBitCast(connectionSymbol, to: Connection.self)()
        topology = unsafeBitCast(displaysSymbol, to: Displays.self)
        let displays = topology(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
        let visible = Set(displays.compactMap { (($0["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value })
        guard let destination = displays.flatMap({ $0["Spaces"] as? [[String: Any]] ?? [] }).first(where: {
            ($0["type"] as? NSNumber)?.intValue == 0 && ($0["id64"] as? NSNumber).map { !visible.contains($0.uint64Value) } == true
        }).flatMap({ ($0["id64"] as? NSNumber)?.uint64Value }) else {
            throw XCTSkip("Need a second existing ordinary desktop; fixture will not create one")
        }
        self.destination = destination
        let owner = try XCTUnwrap(displays.first { display in
            (display["Spaces"] as? [[String: Any]] ?? []).contains { ($0["id64"] as? NSNumber)?.uint64Value == destination }
        })
        display = try XCTUnwrap(owner["Display Identifier"] as? String) as CFString
        original = try XCTUnwrap((owner["Current Space"] as? [String: Any])?["id64"] as? NSNumber).uint64Value
        move = unsafeBitCast(moveSymbol, to: Move.self)
        membership = unsafeBitCast(membershipSymbol, to: Membership.self)
    }
    func park(_ id: CGWindowID) { move(connection, [NSNumber(value: id)] as CFArray, destination) }
    func putOnSource(_ id: CGWindowID) { move(connection, [NSNumber(value: id)] as CFArray, original) }
    func isParked(_ id: CGWindowID) -> Bool {
        let spaces = membership(connection, 7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber] ?? []
        return spaces.contains { $0.uint64Value == destination }
    }
    func selectDestination() throws {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSManagedDisplaySetCurrentSpace") else { throw XCTSkip("Direct Space selection API unavailable") }
        unsafeBitCast(symbol, to: Select.self)(connection, display, destination)
    }
    func destinationIsVisible() -> Bool {
        let displays = topology(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
        return displays.contains { (($0["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value == destination }
    }
    func restore() {
        guard destinationIsVisible(), let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSManagedDisplaySetCurrentSpace") else { return }
        unsafeBitCast(symbol, to: Select.self)(connection, display, original)
    }
}
