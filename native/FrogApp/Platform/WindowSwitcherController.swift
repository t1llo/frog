import AppKit
import ApplicationServices
import SwiftUI
import FrogCore

@MainActor
final class WindowSwitcherController {
    private let catalog = WindowCatalog()
    private let display = WindowSwitcherDisplay()
    private let cache = WindowSwitcherCache()
    private var iconCache: [pid_t: NSImage] = [:]
    private var presentation = WindowSwitchPresentation()
    private var presentationTask: Task<Void, Never>?
    private let statusChanged: (String, Bool) -> Void
    var onError: ((String) -> Void)?
    private var shortcutRules: [Rule] = []
    func updateShortcuts(_ rules: [Rule]) {
        let rules = rules.filter { $0.enabled && $0.category == .application && $0.hotkey != nil }
        guard shortcutRules != rules else { return }
        shortcutRules = rules
        if generation != nil { refreshShortcuts() }
    }
    private func refreshShortcuts() {
        var shortcuts: [pid_t: String] = [:]
        if !shortcutRules.isEmpty {
            for app in NSWorkspace.shared.runningApplications {
                if let rule = shortcutRules.first(where: { $0.action?.applicationBundleID == app.bundleIdentifier }), let key = rule.hotkey {
                    shortcuts[app.processIdentifier] = HotkeyManager.display(key)
                }
            }
        }
        if display.shortcuts != shortcuts { display.shortcuts = shortcuts }
    }
    private var tap: CFMachPort?
    private var inputRunLoop: EventTapRunLoop?
    private var input: WindowSwitchInput?
    private var panel: NSPanel?
    private var router: WindowSwitchKeyRouter { input?.state ?? WindowSwitchKeyRouter() }
    private var session = WindowSwitchSession<UUID>()
    private var generation: UInt64?
    private var discovery: Task<Void, Never>?
    private var activation: Task<Void, Never>?
    private var activationID: UUID? { didSet { if activationID == nil { input?.cancelActivation(oldValue) } } }
    private var activationPID: pid_t?
    private var eventEpoch = UUID()
    private var focusMonitor: Task<Void, Never>?
    private var workspaceObserver: NSObjectProtocol?
    private var pendingSteps: [Bool] = []
    private var commitOnLoad = false
    private var unfilteredWindows: [SwitcherWindow] = []
    private var pointerPosition = NSPoint.zero

    init(statusChanged: @escaping (String, Bool) -> Void) { self.statusChanged = statusChanged }

    func configure(enabled: Bool, suspended: Bool) {
        guard enabled else { stop(); statusChanged("Off — macOS app switcher", false); return }
        guard !suspended else { stop(); statusChanged("Paused while recording a shortcut", false); return }
        guard SelectionService.isTrusted else { stop(); statusChanged("Allow Accessibility to switch windows", false); return }
        guard tap == nil else { return }
        let epoch = UUID(); eventEpoch = epoch
        let input = WindowSwitchInput { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.eventEpoch == epoch, self.tap != nil else { return }
                self.receive(message)
            }
        }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<WindowSwitchInput>.fromOpaque(context).takeUnretainedValue().receive(type: type, event: event)
        }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(input).toOpaque()),
              let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            statusChanged("Keyboard access unavailable — check Accessibility and reopen Frog", false)
            return
        }
        tap = created
        self.input = input; input.attach(created)
        inputRunLoop = EventTapRunLoop(source: runLoopSource, lifetime: input)
        CGEvent.tapEnable(tap: created, enable: true)
        statusChanged("Ready · ⌘Tab switches windows", true)
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in MainActor.assumeIsolated {
            guard let self else { return }
            if self.activation != nil, let target = self.activationPID,
               let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.processIdentifier != target {
                self.activation?.cancel(); self.activation = nil; self.activationID = nil; self.activationPID = nil
            }
            self.cancelAll()
        } }
        focusMonitor = Task { [weak self] in
            var nextRefresh = ContinuousClock.now
            while !Task.isCancelled {
                guard let self else { return }
                guard SelectionService.isTrusted else {
                    self.stop(); self.statusChanged("Allow Accessibility to switch windows", false); return
                }
                if self.generation == nil, self.activation == nil, self.input?.shouldDeferBackgroundWork() == false {
                    if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                       let focused = await self.catalog.noteFocus(pid: pid) {
                        self.cache.noteFocused(focused)
                    }
                    if !Task.isCancelled, self.generation == nil, self.activation == nil,
                       self.cache.snapshot == nil || ContinuousClock.now >= nextRefresh {
                        _ = await self.refreshInventory()
                        nextRefresh = .now.advanced(by: .seconds(2))
                    }
                }
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            }
        }
    }

    func stop() {
        eventEpoch = UUID()
        activation?.cancel(); activation = nil
        activationID = nil
        activationPID = nil
        cancelAll()
        input?.stop()
        focusMonitor?.cancel(); focusMonitor = nil
        cache.clear(); iconCache = [:]
        display.windows = []; display.icons = [:]
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
        inputRunLoop?.stop(); inputRunLoop = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil; input = nil
    }

    isolated deinit {
        discovery?.cancel(); focusMonitor?.cancel(); activation?.cancel(); presentationTask?.cancel()
        cache.cancelRefresh()
        input?.stop()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        inputRunLoop?.stop()
        if let tap { CFMachPortInvalidate(tap) }
        panel?.orderOut(nil)
    }

    private func receive(_ event: WindowSwitchInput.Event) {
        switch event {
        case .reset(let session):
            if let session { cancel(session: session) }
        case .mouse(let point, let session, let activation):
            let cocoaPoint = NSPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
            guard panel?.isVisible != true || panel?.frame.contains(cocoaPoint) != true else { return }
            cancelActivation(activation)
            if let session { cancel(session: session) }
        case .key(let result, let activation):
            cancelActivation(activation)
            if let action = result.action, let session = result.sessionID { handle(action, sessionID: session) }
        }
    }

    private func cancelActivation(_ id: UUID?) {
        guard let id, id == activationID else { return }
        activation?.cancel(); activation = nil; activationID = nil; activationPID = nil
    }

    private func handle(_ action: WindowSwitchKeyRouter.Action, sessionID: UInt64) {
        if action == .cancel { cancel(session: sessionID); return }
        guard router.sessionID == sessionID else { return }
        display.selectionFromPointer = false
        pointerPosition = NSEvent.mouseLocation
        switch action {
        case .begin(let backwards): begin(backwards: backwards, token: sessionID)
        case .step(let backwards):
            guard generation == sessionID else { return }
            if display.loading { pendingSteps.append(backwards) }
            else { session.step(backwards: backwards); display.selected = session.selected }
        case .commit: commit()
        case .cancel: break
        case .search(let text):
            display.query += text
            filterWindows()
        case .deleteSearch:
            if !display.query.isEmpty { display.query.removeLast() }
            filterWindows()
        }
    }

    private func begin(backwards: Bool, token: UInt64) {
        refreshShortcuts()
        if let previous = generation, previous != token { cancel(session: previous) }
        activation?.cancel(); activation = nil; activationID = nil
        discovery?.cancel()
        generation = token
        pendingSteps = []; commitOnLoad = false
        session.reset()
        display.query = ""; unfilteredWindows = []
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let cached = cache.readySnapshot(frontPID: front)
        presentation.begin(token, ready: cached != nil)
        presentationTask?.cancel()
        presentationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let self, self.generation == token else { return }
            self.presentation.elapsed(token)
            self.showPanelIfReady()
        }
        if let cached {
            // Interrupt an in-flight background AX scan so activation isn't queued
            // behind discovery. The last complete inventory and its identities stay valid.
            cache.cancelRefresh()
            apply(cached, backwards: backwards, token: token)
            return
        }
        display.loading = true
        discovery = Task { [weak self] in
            guard let self, let snapshot = await self.refreshInventory(), !Task.isCancelled,
                  self.generation == token, self.router.sessionID == token else { return }
            self.apply(snapshot, backwards: backwards, token: token)
        }
    }

    private func refreshInventory() async -> WindowCatalog.Snapshot? {
        let epoch = eventEpoch
        let applications = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy != .prohibited
        }.map { SwitcherApplication(pid: $0.processIdentifier, name: $0.localizedName ?? "Application", hidden: $0.isHidden) }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let snapshot = await cache.update { [catalog] in await catalog.snapshot(applications: applications, frontPID: front) }
        guard !Task.isCancelled, eventEpoch == epoch, let snapshot else { return nil }
        let pids = Set(snapshot.windows.map(\.pid))
        iconCache = iconCache.filter { pids.contains($0.key) }
        for pid in pids where iconCache[pid] == nil {
            iconCache[pid] = NSRunningApplication(processIdentifier: pid)?.icon
        }
        return snapshot
    }

    private func apply(_ snapshot: WindowCatalog.Snapshot, backwards: Bool, token: UInt64) {
        unfilteredWindows = snapshot.windows
        session.begin(windows: snapshot.windows.map(\.id), current: snapshot.current, backwards: backwards)
        for reverse in pendingSteps { session.step(backwards: reverse) }
        pendingSteps = []
        if display.windows != snapshot.windows { display.windows = snapshot.windows }
        display.selected = session.selected
        display.loading = false
        display.icons = iconCache
        if !display.query.isEmpty { filterWindows() }
        presentation.loaded(token)
        if commitOnLoad { commit() }
        else { showPanelIfReady() }
    }

    private func filterWindows() {
        guard !display.loading else { return }
        let windows = WindowSearch.filter(unfilteredWindows, query: display.query)
        display.windows = windows
        session.begin(windows: windows.map(\.id), current: nil, backwards: false)
        display.selected = session.selected
    }

    private func commit() {
        guard let token = generation, router.sessionID == token else { return }
        presentation.release(token)
        presentationTask?.cancel(); presentationTask = nil
        if display.loading { commitOnLoad = true; panel?.orderOut(nil); return }
        guard let selected = display.windows.first(where: { $0.id == session.selected }) else { cancel(session: token); return }
        let activationToken = UUID()
        guard input?.finish(session: token, activating: activationToken) == true else { cancel(session: token); return }
        cancel(session: token)
        activationID = activationToken
        activationPID = selected.pid
        activation = Task { [weak self, catalog] in
            defer {
                if self?.activationID == activationToken { self?.activation = nil; self?.activationID = nil; self?.activationPID = nil }
            }
            guard !Task.isCancelled, self?.input?.isActivationPending(activationToken) == true else { return }
            guard let app = NSRunningApplication(processIdentifier: selected.pid), !app.isTerminated else {
                self?.onError?("That window closed. Press ⌘Tab to refresh the list."); return
            }
            _ = app.unhide()
            let activated = await WindowActivation.perform(raise: { await catalog.raise(id: selected.id) }, request: { app.activate(options: []) }, bringForward: { await catalog.bringApplicationForward(id: selected.id) }, isFrontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier == selected.pid })
            guard activated else {
                guard !Task.isCancelled else { return }
                self?.onError?("macOS could not bring the selected window to the front. It may have closed or become unavailable."); return
            }
            if !Task.isCancelled { self?.cache.noteFocused(selected.id) }
        }
    }

    private func cancel(session token: UInt64) {
        input?.finish(session: token)
        guard generation == token else { return }
        generation = nil; discovery?.cancel(); discovery = nil
        presentation.cancel(token); presentationTask?.cancel(); presentationTask = nil
        pendingSteps = []; commitOnLoad = false
        session.reset(); panel?.orderOut(nil)
        // Keep the rendered rows and icons warm while the panel is hidden.
    }

    private func cancelAll() {
        if let token = router.sessionID { input?.finish(session: token) }
        if let token = generation { cancel(session: token) }
    }

    private func preparePanel() {
        if panel == nil {
            let created = WindowSwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 480),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            created.level = .popUpMenu
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            created.isOpaque = false; created.backgroundColor = .clear
            created.setAccessibilityIdentifier(SwitcherWindow.overlayIdentifier)
            created.hasShadow = true; created.hidesOnDeactivate = false; created.isReleasedWhenClosed = false
            created.acceptsMouseMovedEvents = true
            created.contentView = WindowSwitcherHostingView(rootView: WindowSwitcherOverlay(model: display, choose: { [weak self] id in
                self?.session.select(id); self?.commit()
            }, hover: { [weak self] id in
                guard let self, self.panel?.isVisible == true, self.router.active, !self.display.loading else { return }
                let point = NSEvent.mouseLocation
                guard point != self.pointerPosition else { return }
                self.pointerPosition = point
                self.display.selectionFromPointer = true
                self.session.select(id); self.display.selected = self.session.selected
            }))
            panel = created
            created.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func showPanelIfReady() {
        guard presentation.shouldShow, router.active, generation == presentation.sessionID else { return }
        preparePanel()
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let screen { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 290, y: screen.visibleFrame.midY - 240)) }
        pointerPosition = NSEvent.mouseLocation
        panel.orderFrontRegardless()
    }
}

private final class WindowSwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class WindowSwitcherHostingView: NSHostingView<WindowSwitcherOverlay> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
