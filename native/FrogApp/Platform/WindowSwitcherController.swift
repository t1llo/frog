import AppKit
import ApplicationServices
import SwiftUI
import FrogCore

/// Owns only GUI input eligibility; background jobs and wake-prevention are unrelated.
@MainActor
final class WindowSwitcherInputLifecycle {
    private var enabled = false
    private var suspended = false
    private var active: Bool
    private var running = false
    private let trusted: () -> Bool
    private let healthy: () -> Bool
    private let startInput: () -> Bool
    private let stopInput: () -> Void
    private let statusChanged: (String, Bool) -> Void
    private let readyStatus: () -> String

    init(active: Bool, trusted: @escaping () -> Bool, healthy: @escaping () -> Bool,
         start: @escaping () -> Bool, stop: @escaping () -> Void, statusChanged: @escaping (String, Bool) -> Void,
         readyStatus: @escaping () -> String = { "Ready · ⌘Tab switches windows" }) {
        self.active = active; self.trusted = trusted; self.healthy = healthy
        startInput = start; stopInput = stop; self.statusChanged = statusChanged; self.readyStatus = readyStatus
    }

    func configure(enabled: Bool, suspended: Bool) {
        self.enabled = enabled; self.suspended = suspended
        reconcile()
    }

    func sessionChanged(active: Bool) { self.active = active; reconcile() }
    func wake() { reconcile() }
    func stop() { enabled = false; reconcile() }

    private func reconcile() {
        let reason: String?
        if !enabled { reason = "Off — macOS app switcher" }
        else if suspended { reason = "Paused while recording a shortcut" }
        else if !active { reason = "Paused while this session is inactive or locked" }
        else if !trusted() { reason = "Allow Accessibility to switch windows" }
        else { reason = nil }
        if let reason {
            if running { stopInput(); running = false }
            statusChanged(reason, false)
            return
        }
        if running {
            guard !healthy() else { return }
            stopInput(); running = false
        }
        running = startInput()
        statusChanged(running ? readyStatus() : "Keyboard access unavailable — check Accessibility and reopen Frog", running)
    }
}

@MainActor
final class WindowSwitcherController {
    private var hotkey = WindowSwitchKeyRouter.defaultHotkey
    private let catalog = WindowCatalog()
    private let display = WindowSwitcherDisplay()
    private let cache = WindowSwitcherCache()
    private var iconCache: [pid_t: NSImage] = [:]
    private var iconTask: Task<Void, Never>?
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
    private var activationSpaceTransition: UUID?
    private var activationWindowID: CGWindowID?
    private var eventEpoch = UUID()
    private var focusMonitor: Task<Void, Never>?
    private var workspaceObserver: NSObjectProtocol?
    private var pendingSteps: [Bool] = []
    private var commitOnLoad = false
    private var unfilteredWindows: [SwitcherWindow] = []
    private var pointerPosition = NSPoint.zero
    private var sessionOnConsole = false
    private var screenLocked = false
    private var sessionObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private lazy var inputLifecycle = WindowSwitcherInputLifecycle(
        active: sessionOnConsole && !screenLocked,
        trusted: { SelectionService.isTrusted },
        healthy: { [weak self] in
            guard let tap = self?.tap else { return false }
            return CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap)
        }, start: { [weak self] in self?.startInput() ?? false },
        stop: { [weak self] in self?.stopInput() }, statusChanged: statusChanged,
        readyStatus: { [weak self] in "Ready · \(HotkeyManager.display(self?.hotkey ?? WindowSwitchKeyRouter.defaultHotkey)) switches windows" })

    init(statusChanged: @escaping (String, Bool) -> Void) {
        self.statusChanged = statusChanged
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { controller in
            // Keep all cached rows immediately available; refresh native AX
            // handles and foreground identity now that the visible Space changed.
            controller.cache.invalidate()
            if let token = controller.activationSpaceTransition, token == controller.activationID,
               let windowID = controller.activationWindowID, WindowSpaceBridge.isOnVisibleSpace(windowID) == false {
                // A gesture or another actor selected a different Desktop while
                // our AX handoff was pending. Never travel back on a late retry.
                controller.cancelActivation(token)
            }
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { controller in
            controller.sessionOnConsole = false
            controller.updateSessionEligibility()
        }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { controller in
            controller.readSessionState()
            controller.updateSessionEligibility()
        }
        observe(workspace, NSWorkspace.didWakeNotification) { controller in
            controller.readSessionState()
            controller.updateSessionEligibility()
            controller.inputLifecycle.wake()
        }
        // Session switching and screen locking are distinct on macOS. These
        // notifications gate this GUI input service, never the process's jobs.
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { controller in
            controller.screenLocked = true
            controller.updateSessionEligibility()
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { controller in
            controller.readSessionState()
            controller.screenLocked = false
            controller.updateSessionEligibility()
        }
        readSessionState()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (WindowSwitcherController) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        sessionObservers.append((center, observer))
    }

    private func readSessionState() {
        let state = CGSessionCopyCurrentDictionary() as? [String: Any]
        sessionOnConsole = state?[kCGSessionOnConsoleKey as String] as? Bool == true
        screenLocked = state?["CGSSessionScreenIsLocked"] as? Bool == true
    }

    private func updateSessionEligibility() {
        inputLifecycle.sessionChanged(active: sessionOnConsole && !screenLocked)
    }

    func configure(enabled: Bool, suspended: Bool, hotkey: Hotkey = WindowSwitchKeyRouter.defaultHotkey) {
        if enabled, let issue = HotkeyManager.validationError(hotkey, purpose: .windowSwitcher) {
            inputLifecycle.configure(enabled: false, suspended: suspended)
            statusChanged(issue, false)
            return
        }
        if self.hotkey != hotkey {
            // Retire the complete old input epoch, including pending activation,
            // before installing a router with a different base chord.
            inputLifecycle.configure(enabled: false, suspended: suspended)
            self.hotkey = hotkey
        }
        inputLifecycle.configure(enabled: enabled, suspended: suspended)
    }

    private func startInput() -> Bool {
        let epoch = UUID(); eventEpoch = epoch
        let input = WindowSwitchInput(hotkey: hotkey) { [weak self] message in
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
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(input).toOpaque()) else {
            return false
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            CFMachPortInvalidate(created)
            return false
        }
        tap = created
        self.input = input; input.attach(created)
        inputRunLoop = EventTapRunLoop(source: runLoopSource, lifetime: input)
        CGEvent.tapEnable(tap: created, enable: true)
        preparePanel()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in MainActor.assumeIsolated {
            guard let self else { return }
            if self.activation != nil, self.activationSpaceTransition != self.activationID, let target = self.activationPID,
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
                    self.inputLifecycle.wake(); return
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
        return true
    }

    func stop() {
        inputLifecycle.stop()
    }

    private func stopInput() {
        eventEpoch = UUID()
        input?.stop()
        activation?.cancel(); activation = nil
        activationID = nil
        activationPID = nil
        cancelAll()
        focusMonitor?.cancel(); focusMonitor = nil
        cache.clear(); iconCache = [:]
        iconTask?.cancel(); iconTask = nil
        display.windows = []; display.icons = [:]
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
        inputRunLoop?.stop(); inputRunLoop = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil; input = nil
    }

    isolated deinit {
        discovery?.cancel(); focusMonitor?.cancel(); activation?.cancel(); presentationTask?.cancel()
        iconTask?.cancel()
        cache.cancelRefresh()
        input?.stop()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        for (center, observer) in sessionObservers { center.removeObserver(observer) }
        inputRunLoop?.stop()
        if let tap { CFMachPortInvalidate(tap) }
        panel?.orderOut(nil)
    }

    private func receive(_ event: WindowSwitchInput.Event) {
        switch event {
        case .reset(let session, let activation):
            cancelActivation(activation)
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
        if let previous = generation, previous != token { cancel(session: previous) }
        activation?.cancel(); activation = nil; activationID = nil
        discovery?.cancel()
        generation = token
        pendingSteps = []; commitOnLoad = false
        session.reset()
        display.query = ""; unfilteredWindows = []
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let livePIDs = Set(NSWorkspace.shared.runningApplications.compactMap(SwitcherApplication.running).map(\.pid))
        let cached = cache.readySnapshot(frontPID: front, livePIDs: livePIDs)
        let needsRefresh = cache.needsRefresh()
        presentation.begin(token, ready: cached != nil)
        presentationTask?.cancel()
        // The user asked for immediate presentation. Cached rows and the hosting
        // view are kept warm; there is no artificial hold-to-show delay.
        presentation.elapsed(token)
        if let cached {
            // Interrupt an in-flight background AX scan so activation isn't queued
            // behind discovery. The last complete inventory and its identities stay valid.
            cache.cancelRefresh()
            apply(cached, backwards: backwards, token: token)
            if needsRefresh, generation == token {
                discovery = Task { [weak self] in
                    guard let self, let snapshot = await self.refreshInventory(), !Task.isCancelled,
                          self.generation == token, self.router.sessionID == token else { return }
                    self.reconcile(snapshot)
                }
            }
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
        let applications = NSWorkspace.shared.runningApplications.compactMap(SwitcherApplication.running)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let snapshot = await cache.update { [catalog] in await catalog.snapshot(applications: applications, frontPID: front) }
        guard !Task.isCancelled, eventEpoch == epoch, let snapshot else { return nil }
        refreshShortcuts()
        let pids = Set(snapshot.windows.map(\.pid))
        iconCache = iconCache.filter { pids.contains($0.key) }
        let missing = pids.filter { iconCache[$0] == nil }
        iconTask?.cancel()
        if !missing.isEmpty {
            iconTask = Task { [weak self] in
                let load = Task.detached(priority: .utility) {
                    var icons: [pid_t: NSImage] = [:]
                    for pid in missing {
                        guard !Task.isCancelled else { break }
                        icons[pid] = NSRunningApplication(processIdentifier: pid)?.icon
                    }
                    return icons
                }
                let icons = await withTaskCancellationHandler { await load.value } onCancel: { load.cancel() }
                guard !Task.isCancelled, let self, self.eventEpoch == epoch else { return }
                self.iconCache.merge(icons) { _, new in new }
                self.display.icons = self.iconCache
            }
        }
        if generation == nil, activation == nil { display.preload(snapshot, in: panel) }
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
        if let panel, panel.isVisible {
            let size = WindowSwitcherLayout.size(windowCount: windows.count)
            panel.setFrame(NSRect(x: panel.frame.midX - size.width / 2, y: panel.frame.midY - size.height / 2,
                                  width: size.width, height: size.height), display: true)
        }
    }

    private func reconcile(_ snapshot: WindowCatalog.Snapshot) {
        // Refresh stale rows while held, preserving the user's cycling order and
        // selected identity. Newly discovered windows append rather than jump ahead.
        let byID = Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.id, $0) })
        let oldIDs = Set(unfilteredWindows.map(\.id))
        unfilteredWindows = unfilteredWindows.compactMap { byID[$0.id] }
            + snapshot.windows.filter { !oldIDs.contains($0.id) }
        let windows = WindowSearch.filter(unfilteredWindows, query: display.query)
        session.reconcile(windows: windows.map(\.id))
        let ordered = session.windows.compactMap { byID[$0] }
        if display.windows != ordered { display.windows = ordered }
        display.selected = session.selected
        display.icons = iconCache
        showPanelIfReady()
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
        activationWindowID = selected.windowID
        activation = Task { [weak self, catalog] in
            defer {
                if self?.activationSpaceTransition == activationToken { self?.activationSpaceTransition = nil }
                if self?.activationID == activationToken { self?.activation = nil; self?.activationID = nil; self?.activationPID = nil; self?.activationWindowID = nil }
            }
            guard !Task.isCancelled, self?.input?.isActivationPending(activationToken) == true else { return }
            guard let app = NSRunningApplication(processIdentifier: selected.pid), !app.isTerminated else {
                self?.onError?("That window closed. Open the window switcher again to refresh the list."); return
            }
            guard let input = self?.input else { return }
            let isCurrent: @Sendable () -> Bool = { input.isActivationPending(activationToken) }
            let activated = await WindowActivation.perform(raise: { await catalog.raise(id: selected.id, isCurrent: isCurrent) }, request: {
                guard isCurrent() else { return false }
                if selected.hidden { _ = app.unhide() }
                guard isCurrent() else { return false }
                return app.activate(options: [])
            }, bringForward: { await catalog.bringApplicationForward(id: selected.id, isCurrent: isCurrent) }, isFrontmost: {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == selected.pid
            }, prepare: {
                let ready = await catalog.prepareActivation(id: selected.id, isCurrent: isCurrent, willChangeSpace: { [weak self] in
                    await MainActor.run {
                        if self?.activationID == activationToken { self?.activationSpaceTransition = activationToken }
                    }
                })
                return ready
            }, isCurrent: isCurrent)
            guard activated else {
                guard !Task.isCancelled, isCurrent() else { return }
                self?.onError?("macOS could not bring the selected window to the front. It may have closed or become unavailable."); return
            }
            if !Task.isCancelled, isCurrent() { self?.cache.noteFocused(selected.id) }
        }
    }

    private func cancel(session token: UInt64) {
        input?.finish(session: token)
        guard generation == token else { return }
        generation = nil; discovery?.cancel(); discovery = nil
        cache.cancelRefresh()
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
            let created = WindowSwitcherPanel(contentRect: NSRect(origin: .zero, size: WindowSwitcherLayout.size(windowCount: display.windows.count)),
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
            (created.contentView as? WindowSwitcherHostingView)?.sizingOptions = []
            panel = created
            created.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func showPanelIfReady() {
        guard presentation.shouldShow, router.active, generation == presentation.sessionID else { return }
        preparePanel()
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let size = WindowSwitcherLayout.size(windowCount: display.windows.count)
        if let screen {
            panel.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2,
                                  y: screen.visibleFrame.midY - size.height / 2,
                                  width: size.width, height: size.height), display: true)
        }
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
