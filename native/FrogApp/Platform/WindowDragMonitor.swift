import AppKit
import ApplicationServices
import FrogCore
import os

/// Where a global left-mouse-up monitor comes from, so tests can release the button themselves.
protocol MouseUpSource {
    /// Installs a global left-mouse-up monitor. The handler gets the release point in
    /// Accessibility's top-left-origin coordinates.
    func addMonitor(_ handler: @escaping (CGPoint) -> Void) -> Any?
    func removeMonitor(_ monitor: Any)
    /// Runs `work` once on the main queue after `delay` seconds.
    func schedule(_ work: DispatchWorkItem, after delay: TimeInterval)
}

/// The real button.
struct LiveMouseUpSource: MouseUpSource {
    func addMonitor(_ handler: @escaping (CGPoint) -> Void) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            handler(WindowDragMonitor.accessibilityPoint(NSEvent.mouseLocation, primaryTop: primaryTop))
        }
    }

    func removeMonitor(_ monitor: Any) { NSEvent.removeMonitor(monitor) }

    func schedule(_ work: DispatchWorkItem, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

extension MouseUpSource where Self == LiveMouseUpSource {
    static var live: LiveMouseUpSource { LiveMouseUpSource() }
}

/// Waits for the next release of the left mouse button, once. The monitor exists only while it
/// waits: it removes itself on the release, on `cancel()`, when the watcher goes away or after
/// the timeout, whichever comes first. Used on the main thread.
final class MouseReleaseWatcher {
    private let source: MouseUpSource
    private let timeout: TimeInterval
    private var monitor: Any?
    private var onRelease: ((CGPoint) -> Void)?
    private var expiry: DispatchWorkItem?

    init(source: MouseUpSource = .live, timeout: TimeInterval = 10) {
        self.source = source
        self.timeout = timeout
    }

    deinit { cancel() }

    var watching: Bool { monitor != nil }

    /// Calls `onRelease` with the release point. A second call while watching replaces the
    /// callback and keeps the monitor and its timeout.
    func watch(_ onRelease: @escaping (CGPoint) -> Void) {
        self.onRelease = onRelease
        guard monitor == nil else { return }
        monitor = source.addMonitor { [weak self] point in self?.released(at: point) }
        let expiry = DispatchWorkItem { [weak self] in self?.cancel() }
        self.expiry = expiry
        source.schedule(expiry, after: timeout)
    }

    /// Removes the monitor without calling back.
    func cancel() {
        expiry?.cancel()
        expiry = nil
        onRelease = nil
        if let monitor { source.removeMonitor(monitor) }
        monitor = nil
    }

    private func released(at point: CGPoint) {
        let onRelease = onRelease
        cancel()
        onRelease?(point)
    }
}

/// Follows one mouse drag at a time and snaps the window it moves. Every click on the Mac
/// reaches it, so a mouse-down only records where and when. Once the pointer has moved 4 pt it
/// looks up the window under the pointer once, then reads its frame again, one read at a time
/// and at most 10 times, until the window is seen moving with the pointer. A drag that never
/// moves a window (a text selection, a slider, a resize) is dropped. After that,
/// drag events only test the pointer against the zones. While the zone overlay is on, holding
/// Shift during the drag shows Frog's zones instead of the edges.
@MainActor
final class WindowDragTracker {
    static let dragThreshold: CGFloat = 4
    static let readLimit = 10

    private let probe: (CGPoint) async -> (WindowHandle, CGRect)?
    private let frame: (WindowHandle) async -> CGRect?
    /// Snaps the window on the display; the frame is where the window was when the drag began,
    /// which Restore returns to.
    private let apply: (WindowAction, WindowHandle, WindowDisplay, CGRect) async -> Void
    private let setFrame: (CGRect, WindowHandle) async -> Void
    /// A drag gave the window its earlier size back and snapped nowhere: Frog no longer holds
    /// it anywhere, so Restore has nothing to return to.
    private let forget: (WindowHandle) async -> Void
    private let preview: (CGRect?) -> Void
    private let displays: () -> [WindowDisplay]
    private let options: () -> WindowLayoutOptions
    private let macOS: () -> MacWindowManagerSettings
    /// Where Frog last put the window, and the size a drag away gives back, if any.
    private let lastMove: (WindowKey) async -> (CGRect, CGSize?)?
    private let shouldIgnore: (WindowHandle) -> Bool
    private let restoreOnDrag: () -> Bool
    private let dragToSnap: () -> Bool
    /// The overlay's zones while the overlay is on; nil while it is off.
    private let zoneGrid: () -> ZoneGrid?
    /// Whether Shift and Option are held now.
    private let modifiers: () -> (shift: Bool, option: Bool)
    private let showZones: (SnapZoneLayout?) -> Void
    private let now: () -> TimeInterval

    /// The release and Escape are wanted or no longer wanted; the monitor installs or removes them.
    var onChange: (() -> Void)?

    private enum Phase { case idle, pressed, probing, reading, confirmed, abandoned }
    private var phase = Phase.idle
    private var down: (point: CGPoint, time: TimeInterval)?
    private var latest: (point: CGPoint, time: TimeInterval) = (.zero, 0)
    /// Advanced by every press and release, so a late answer about an earlier drag is dropped.
    private var generation = 0
    private var window: WindowHandle?
    /// The pointer positions while the window is looked up; its frame is read at one of them.
    private var probePath: [CGPoint] = []
    private var session: SnapDragSession?
    private var dragDisplays: [WindowDisplay] = []
    private var dragOptions = WindowLayoutOptions.legacy
    private var reads = 0
    private var readInFlight = false
    private var previewShown = false
    private var dwell: (deadline: TimeInterval, task: Task<Void, Never>)?
    private var probeTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    /// The modifiers last given to the session, and the zones it shows.
    private var held = (shift: false, option: false)
    private var dragGrid: ZoneGrid?
    private var zoneLayout: SnapZoneLayout?

    init(probe: @escaping (CGPoint) async -> (WindowHandle, CGRect)?,
         frame: @escaping (WindowHandle) async -> CGRect?,
         apply: @escaping (WindowAction, WindowHandle, WindowDisplay, CGRect) async -> Void,
         setFrame: @escaping (CGRect, WindowHandle) async -> Void,
         forget: @escaping (WindowHandle) async -> Void = { _ in },
         preview: @escaping (CGRect?) -> Void,
         displays: @escaping () -> [WindowDisplay],
         options: @escaping () -> WindowLayoutOptions,
         macOS: @escaping () -> MacWindowManagerSettings,
         lastMove: @escaping (WindowKey) async -> (CGRect, CGSize?)?,
         shouldIgnore: @escaping (WindowHandle) -> Bool,
         restoreOnDrag: @escaping () -> Bool = { true },
         dragToSnap: @escaping () -> Bool = { true },
         zoneGrid: @escaping () -> ZoneGrid? = { nil },
         modifiers: @escaping () -> (shift: Bool, option: Bool) = { (false, false) },
         showZones: @escaping (SnapZoneLayout?) -> Void = { _ in },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.probe = probe; self.frame = frame; self.apply = apply; self.setFrame = setFrame; self.forget = forget
        self.preview = preview; self.displays = displays; self.options = options; self.macOS = macOS
        self.lastMove = lastMove; self.shouldIgnore = shouldIgnore; self.restoreOnDrag = restoreOnDrag
        self.dragToSnap = dragToSnap; self.zoneGrid = zoneGrid; self.modifiers = modifiers; self.showZones = showZones; self.now = now
    }

    /// A drag is under way: its release decides what happens.
    var wantsRelease: Bool { [.probing, .reading, .confirmed].contains(phase) }

    /// A window is being dragged and Escape would cancel its snap.
    var wantsEscape: Bool { phase == .confirmed && session?.finished == false }

    /// Only records the point and time: no Accessibility call.
    func mouseDown(at point: CGPoint, time: TimeInterval) {
        if phase != .idle { reset() }
        generation += 1
        down = (point, time)
        phase = .pressed
    }

    func dragged(to point: CGPoint, time: TimeInterval) {
        guard let down else { return }
        latest = (point, time)
        switch phase {
        case .pressed:
            let travel = hypot(point.x - down.point.x, point.y - down.point.y)
            guard travel > Self.dragThreshold else { return }
            phase = .probing
            startProbe(pointer: point, time: time, travel: travel)
            onChange?()
        case .probing:
            probePath.append(point)
            if probePath.count > 64 { probePath.removeFirst(probePath.count - 64) }
        case .reading:
            feed(frame: nil)
            if !readInFlight, reads < Self.readLimit, phase == .reading { startRead() }
        case .confirmed:
            feed(frame: nil)
        case .idle, .abandoned:
            break
        }
    }

    func mouseUp(at point: CGPoint, time: TimeInterval) {
        guard down != nil else { return }
        if phase == .confirmed, let session, let window {
            if let candidate = session.end(at: point, time: time, displays: dragDisplays),
               let display = dragDisplays.first(where: { $0.id == candidate.displayID }) {
                let start = session.frameBeforeDrag
                enqueue { [apply] in await apply(candidate.action, window, display, start) }
            } else if session.restored {
                enqueue { [forget] in await forget(window) }
            }
        } else if phase == .reading, let session, let window {
            // Released before a read showed the window following, as after a quick throw to an
            // edge: one read where the window came to rest decides.
            let displays = dragDisplays
            enqueue { [frame, apply] in
                var session = session
                guard let read = await frame(window) else { return }
                _ = session.move(to: point, time: time, windowFrame: read, displays: displays)
                guard let candidate = session.end(at: point, time: time, displays: displays),
                      let display = displays.first(where: { $0.id == candidate.displayID }) else { return }
                await apply(candidate.action, window, display, session.frameBeforeDrag)
            }
        }
        reset()
    }

    /// Shift or Option went down or up. While the overlay is on and a window is being dragged,
    /// Shift shows its zones; macOS's tiling settings are read again each time they show.
    func modifiersChanged(shift: Bool, option: Bool) {
        guard [.reading, .confirmed].contains(phase), var session, let grid = dragGrid,
              shift != held.shift || (shift && option != held.option) else { return }
        held = (shift, option)
        let effects = session.shiftChanged(shift, pointer: latest.point, time: latest.time, displays: dragDisplays, grid: grid,
                                           options: dragOptions, macOS: shift ? macOS() : MacWindowManagerSettings(), optionDown: option)
        self.session = session
        handle(effects)
        scheduleDwell()
    }

    /// Escape during a window drag: no snap at the release. The drag itself goes on.
    func escape() {
        guard phase == .confirmed, var session else { return }
        handle(session.cancel())
        self.session = session
        cancelDwell()
        onChange?()
    }

    /// Forgets the drag in progress and hides its preview.
    func reset() {
        let wanted = wantsRelease || wantsEscape
        generation += 1
        phase = .idle
        down = nil
        window = nil
        probePath = []
        session = nil
        reads = 0
        readInFlight = false
        held = (false, false)
        dragGrid = nil
        cancelDwell()
        if previewShown { previewShown = false; preview(nil) }
        if zoneLayout != nil { zoneLayout = nil; showZones(nil) }
        if wanted { onChange?() }
    }

    /// Waits until no lookup, read or write of this tracker runs. For tests.
    func settle() async {
        var finished: [Task<Void, Never>] = []
        while true {
            let running = [probeTask, readTask, writeTask, dwell?.task].compactMap { $0 }.filter { !finished.contains($0) }
            if running.isEmpty { return }
            for task in running { await task.value }
            finished += running
        }
    }

    // MARK: Steps

    /// Looks up the window under the pointer: a dragged window moves with the pointer, so the
    /// point it was grabbed at stays under it while the mouse-down point is left behind.
    private func startProbe(pointer: CGPoint, time: TimeInterval, travel: CGFloat) {
        let generation = generation
        probePath = []
        probeTask = Task { [weak self, probe] in
            let result = await probe(pointer)
            guard let self else { return }
            defer { if self.generation == generation { self.probeTask = nil } }
            guard self.generation == generation, self.phase == .probing else { return }
            guard let (window, frame) = result, !self.shouldIgnore(window) else { self.abandon(); return }
            // Where Frog last put the window: Restore returns from a snap to the frame before
            // that, and a drag away gives the size back.
            let move = await self.lastMove(window.key)
            guard self.generation == generation, self.phase == .probing, let down = self.down?.point else { return }
            // The window was read at one of the positions the pointer passed meanwhile.
            let readAt = self.probePath
            let farthest = readAt.map { hypot($0.x - down.x, $0.y - down.y) }.max() ?? 0
            self.window = window
            self.dragDisplays = self.displays()
            self.dragOptions = self.options()
            self.dragGrid = self.zoneGrid()
            self.session = SnapDragSession(window: frame, pointer: pointer, time: time, lastMove: move?.0, sizeBeforeMove: move?.1,
                                           restoreOnDrag: self.restoreOnDrag(), edgesPaused: !self.dragToSnap() || self.macOS().edgeTiling,
                                           travel: max(travel, farthest), readAt: readAt, mouseDown: down)
            self.phase = .reading
            // Shift held from before the drag shows the zones once the window follows.
            let held = self.modifiers()
            self.modifiersChanged(shift: held.shift, option: held.option)
        }
    }

    private func startRead() {
        guard let window else { return }
        reads += 1
        readInFlight = true
        let generation = generation
        readTask = Task { [weak self, frame] in
            let read = await frame(window)
            guard let self, self.generation == generation else { return }
            self.readInFlight = false
            self.readTask = nil
            guard self.phase == .reading else { return }
            self.feed(frame: read)
            if self.phase == .reading, self.reads >= Self.readLimit { self.abandon() }
        }
    }

    /// Hands the latest pointer, and a frame when one was read, to the session.
    private func feed(frame: CGRect?) {
        guard var session else { return }
        let effects = session.move(to: latest.point, time: latest.time, windowFrame: frame, displays: dragDisplays)
        self.session = session
        if session.finished, !session.confirmed { abandon(); return }
        handle(effects)
        scheduleDwell()
    }

    private func handle(_ effects: [SnapDragSession.Effect]) {
        for effect in effects {
            switch effect {
            case .confirmDrag:
                phase = .confirmed
                onChange?()
            case .showPreview(let candidate):
                guard let session, let display = dragDisplays.first(where: { $0.id == candidate.displayID }),
                      let target = WindowGeometry.target(candidate.action, window: session.startFrame, displays: [display.visibleFrame],
                                                         options: dragOptions) else { continue }
                previewShown = true
                preview(target)
            case .hidePreview:
                previewShown = false
                preview(nil)
            case .restoreSize(let frame):
                guard let window else { continue }
                enqueue { [setFrame] in await setFrame(frame, window) }
            case .showOverlay(let displayID):
                guard let grid = dragGrid, let display = dragDisplays.first(where: { $0.id == displayID }) else { continue }
                zoneLayout = SnapZoneLayout(display: display, grid: grid, options: dragOptions)
                showZones(zoneLayout)
            case .highlight(let action):
                guard var layout = zoneLayout else { continue }
                layout.highlight = action
                zoneLayout = layout
                showZones(layout)
            case .hideOverlay:
                zoneLayout = nil
                showZones(nil)
            }
        }
    }

    /// Runs `work` after the writes queued before it, so the window takes its frames in order.
    private func enqueue(_ work: @escaping () async -> Void) {
        let previous = writeTask
        writeTask = Task {
            await previous?.value
            await work()
        }
    }

    /// A pointer resting on a shared edge sends no events, so the preview shows after the wait.
    private func scheduleDwell() {
        guard let deadline = session?.dwellDeadline else { cancelDwell(); return }
        guard dwell?.deadline != deadline else { return }
        cancelDwell()
        let generation = generation
        let task = Task { [weak self] in
            guard let self else { return }
            let wait = max(0, deadline - self.now())
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000) + 1_000_000)
            guard !Task.isCancelled, self.generation == generation, self.phase == .confirmed else { return }
            self.dwell = nil
            self.latest.time = max(self.latest.time, self.now())
            self.feed(frame: nil)
        }
        dwell = (deadline, task)
    }

    private func cancelDwell() {
        dwell?.task.cancel()
        dwell = nil
    }

    private func abandon() {
        phase = .abandoned
        cancelDwell()
        if previewShown { previewShown = false; preview(nil) }
        if zoneLayout != nil { zoneLayout = nil; showZones(nil) }
        #if DEBUG
        Logger(subsystem: "frog", category: "windows").debug("drag abandoned")
        #endif
        onChange?()
    }
}

/// Watches the mouse system-wide while drag to snap or the zone overlay is on, and feeds a
/// `WindowDragTracker`. The press and drag monitors cost a distance test per event; the release
/// monitor exists only during a drag, and the Escape monitor only while a window is being
/// dragged. With `watchesModifiers`, for the overlay, it also notices Shift and Option.
@MainActor
final class WindowDragMonitor {
    let tracker: WindowDragTracker
    let watchesModifiers: Bool
    private let releaseWatcher: MouseReleaseWatcher
    private var mouseMonitor: Any?
    private var escapeMonitor: Any?
    /// The top edge of the primary display in Cocoa coordinates, read at each press.
    private var primaryTop: CGFloat = 0

    init(tracker: WindowDragTracker, watchesModifiers: Bool = false, releaseWatcher: MouseReleaseWatcher = MouseReleaseWatcher()) {
        self.tracker = tracker
        self.watchesModifiers = watchesModifiers
        self.releaseWatcher = releaseWatcher
    }

    var running: Bool { mouseMonitor != nil }

    func start() {
        guard mouseMonitor == nil else { return }
        tracker.onChange = { [weak self] in self?.sync() }
        let mask: NSEvent.EventTypeMask = watchesModifiers ? [.leftMouseDown, .leftMouseDragged, .flagsChanged] : [.leftMouseDown, .leftMouseDragged]
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    func stop() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        tracker.onChange = nil
        tracker.reset()
        releaseWatcher.cancel()
        removeEscape()
    }

    /// A Cocoa screen point (origin bottom left of the primary display) in Accessibility's
    /// coordinates (origin top left), given the top edge of the primary display.
    nonisolated static func accessibilityPoint(_ point: CGPoint, primaryTop: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryTop - point.y)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            tracker.mouseDown(at: Self.accessibilityPoint(NSEvent.mouseLocation, primaryTop: primaryTop), time: event.timestamp)
        case .leftMouseDragged:
            tracker.dragged(to: Self.accessibilityPoint(NSEvent.mouseLocation, primaryTop: primaryTop), time: event.timestamp)
            if watchesModifiers { modifiersChanged(event.modifierFlags) }
            // The release monitor gave up after its timeout during a long drag: watch again.
            if tracker.wantsRelease, !releaseWatcher.watching { sync() }
        case .flagsChanged:
            modifiersChanged(event.modifierFlags)
        default:
            break
        }
    }

    /// Only Shift and Option are looked at.
    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        tracker.modifiersChanged(shift: flags.contains(.shift), option: flags.contains(.option))
    }

    /// Whether Shift and Option are held now, wherever the keyboard focus is.
    static func liveModifiers() -> (shift: Bool, option: Bool) {
        let flags = NSEvent.modifierFlags
        return (flags.contains(.shift), flags.contains(.option))
    }

    private func sync() {
        if tracker.wantsRelease {
            if !releaseWatcher.watching {
                releaseWatcher.watch { [weak self] point in
                    MainActor.assumeIsolated { self?.tracker.mouseUp(at: point, time: ProcessInfo.processInfo.systemUptime) }
                }
            }
        } else {
            releaseWatcher.cancel()
        }
        if tracker.wantsEscape {
            guard escapeMonitor == nil else { return }
            escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return }
                MainActor.assumeIsolated { self?.tracker.escape() }
            }
        } else {
            removeEscape()
        }
    }

    private func removeEscape() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    // MARK: Live lookups

    nonisolated private static let readTimeout: Float = 0.1

    /// The window under a point and its frame, skipping Frog's own and full-screen windows. Runs
    /// off the main actor. The hit test keeps the process-wide timeout, because setting one on
    /// the system-wide element would change it for every Accessibility call Frog makes; the
    /// elements it returns answer within 0.1 s.
    nonisolated static func windowUnder(_ point: CGPoint) async -> (WindowHandle, CGRect)? {
        await Task.detached(priority: .userInitiated) { lookUpWindow(at: point) }.value
    }

    nonisolated private static func lookUpWindow(at point: CGPoint) -> (WindowHandle, CGRect)? {
        guard AXIsProcessTrusted() else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        AXUIElementSetMessagingTimeout(hit, readTimeout)
        let window: AXUIElement
        if AXRead.string(hit, kAXRoleAttribute) == kAXWindowRole { window = hit }
        else if let owner = AXRead.element(hit, kAXWindowAttribute, timeout: readTimeout) { window = owner }
        else { return nil }
        guard AXRead.boolean(window, "AXFullScreen") != true else { return nil }
        let handle = WindowHandle(key: AXWindowAccess.key(of: window, pid: pid), element: window)
        guard let frame = AXWindowAccess().frame(of: handle) else { return nil }
        return (handle, frame)
    }

    /// One frame read, off the main actor.
    nonisolated static func readFrame(_ window: WindowHandle, access: WindowAccess) async -> CGRect? {
        await Task.detached(priority: .userInitiated) { access.frame(of: window) }.value
    }
}
