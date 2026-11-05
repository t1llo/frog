import AppKit
import Carbon
import FrogCore
import os

/// The selection bubble as `AppModel` starts and stops it.
@MainActor protocol SelectionWatching: AnyObject {
    var isRunning: Bool { get }
    func start()
    func stop()
    /// Hides the bubble and drops a pending read, because a rule just ran on the selection.
    func dismiss()
}

/// Shows the bubble next to a selection. It never activates Frog or takes focus.
@MainActor protocol SelectionBubblePresenting: AnyObject {
    var isVisible: Bool { get }
    /// The pointer entered (true) or left (false) the bubble.
    var onHover: ((Bool) -> Void)? { get set }
    var onSelect: ((BubbleItem) -> Void)? { get set }
    /// Below and right of `anchor`, or next to `pointer` without one.
    func show(visible: [BubbleItem], more: [BubbleItem], anchor: CGRect?, pointer: CGPoint)
    func hide()
}

/// The frontmost app, as the bubble checks it before reading.
struct BubbleApplication: Equatable {
    var pid: pid_t
    var bundleID: String?
    var bundleURL: URL?
}

/// What Frog is doing, as the bubble checks it before reading.
struct BubbleState: Equatable {
    var explainEnabled: Bool
    var bubbleEnabled: Bool
    var writingEnabled: Bool
    var accessibilityTrusted: Bool
    /// A rule is processing, dictation is running, a shortcut is being recorded, or the answer panel is key.
    var busy: Bool
}

/// Watches for the end of a selection gesture in another app and offers the bubble. A thin shell around
/// `SelectionWatcherCore`: it turns events into `SelectionInput`s, runs one settle task, reads the selection through
/// Accessibility only and hands the result to the presenter. It shows the bubble only for a text selection it read,
/// that this gesture made, from a gesture that began on text: the element under the pointer at mouse down must not be
/// a scroll bar, slider, button, tab, toolbar, window part or file list. Apps built on Chromium keep their text hidden;
/// only when the user turned on `chromiumApps` does a drag or double click there offer the bubble at the pointer
/// without any text. It never copies and never sees typed characters: key presses are watched only while the bubble
/// shows and while Shift is held, and then only their key code and modifier keys, to tell Shift and the arrow keys
/// from typing a capital letter.
@MainActor final class SelectionWatcher: SelectionWatching {
    struct Hooks {
        var options: @MainActor () -> SelectionBubbleOptions
        var state: @MainActor () -> BubbleState
        var items: @MainActor (SelectionSnapshot) -> (visible: [BubbleItem], more: [BubbleItem])
        var run: @MainActor (BubbleItem, SelectionSnapshot) -> Void
    }

    /// What the watcher asks the Mac.
    struct System {
        var frontmost: @MainActor () -> BubbleApplication?
        var ownPID: pid_t
        var secureInput: @MainActor () -> Bool
        /// The app's `LSApplicationCategoryType`.
        var category: @MainActor (URL) -> String?
        /// Whether the app ships VS Code's product file, as every editor built on VS Code does.
        var builtOnVSCode: @MainActor (URL) -> Bool
        /// Whether the app is built on Chromium, as Chrome, Helium, Arc and Electron apps are: its framework carries
        /// Chromium's helper apps.
        var builtOnChromium: @MainActor (URL) -> Bool = { _ in false }
        /// The frame of the app's frontmost window under the point, in Cocoa coordinates.
        var windowFrame: @MainActor (pid_t, CGPoint) -> CGRect? = { _, _ in nil }
        /// The Accessibility element under a point (Cocoa coordinates), by role only. Runs off the main thread.
        var pointElement: @Sendable (CGPoint) async -> PointElement? = { _ in nil }

        static let live = System(
            frontmost: {
                guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
                return BubbleApplication(pid: app.processIdentifier, bundleID: app.bundleIdentifier, bundleURL: app.bundleURL)
            },
            ownPID: ProcessInfo.processInfo.processIdentifier,
            secureInput: { IsSecureEventInputEnabled() },
            category: { Bundle(url: $0)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String },
            builtOnVSCode: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Resources/app/product.json").path) },
            builtOnChromium: { app in
                let frameworks = app.appendingPathComponent("Contents/Frameworks")
                let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
                return names.contains { name in
                    name.hasSuffix(".framework")
                        && FileManager.default.fileExists(atPath: frameworks.appendingPathComponent(name).appendingPathComponent("Versions/Current/Helpers").path)
                }
            },
            windowFrame: { pid, point in
                // From the window server, so the app itself is not asked anything.
                guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                        as? [[String: Any]] else { return nil }
                let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
                for window in windows where (window[kCGWindowOwnerPID as String] as? pid_t) == pid
                    && (window[kCGWindowLayer as String] as? Int) == 0 {
                    guard let raw = window[kCGWindowBounds as String] as? NSDictionary,
                          let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { continue }
                    let frame = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
                    if frame.contains(point) { return frame }
                }
                return nil
            },
            pointElement: { await PointElementLookup.element(at: $0) })
    }

    private let reader: SelectionReading
    private let presenter: SelectionBubblePresenting
    private let hooks: Hooks
    private let system: System
    private let clock: () -> Date
    private let sleep: (TimeInterval) async throws -> Void
    private var core = SelectionWatcherCore()
    private(set) var isRunning = false
    private var monitor: Any?
    private var keyMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var shiftDown = false
    /// Command or Control went down while Shift was held, so releasing Shift may end a shortcut such as ⇧⌘T, which
    /// leaves the selection as it was, rather than a selection made with Shift and the arrow keys.
    private var shortcutWithShift = false
    private var lastMouseUp: CGPoint?
    private var lastMouseDown: CGPoint?
    /// What was under the pointer when the mouse last went down, looked up off the main thread while the gesture runs,
    /// since a window dragged by its title bar is gone from there by the time the gesture ends.
    private var downElement: Task<PointElement?, Never>?
    /// The keys pressed while Shift is held, by key code only.
    private var shiftKeys = ShiftKeys()
    private var shiftKeyMonitor: Any?
    private var pending: Task<Void, Never>?
    private var idleCheck: Task<Void, Never>?
    private var hovering = false
    /// Counts inputs and stops, so a read that finishes after a later input or a stop shows nothing.
    private var generation = 0
    /// Settles reading the selection now. Scrolling during one moves the text away from where it was read.
    private var reading = 0
    /// The selection the bubble shows now.
    private var shown: SelectionSnapshot?
    /// Whether an app is a game, by bundle identifier.
    private var games: [String: Bool] = [:]
    /// Whether the bubble may appear without the text in an app, by bundle identifier.
    private var withoutText: [String: Bool] = [:]
    /// Why a gesture showed the bubble or not, at debug level for `log stream --level debug --predicate
    /// 'subsystem == "frog" && category == "selection-bubble"'`. Never the selected text.
    private static let log = Logger(subsystem: "frog", category: "selection-bubble")

    init(reader: SelectionReading, presenter: SelectionBubblePresenting, hooks: Hooks, system: System = .live,
         clock: @escaping () -> Date = { Date() },
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.reader = reader
        self.presenter = presenter
        self.hooks = hooks
        self.system = system
        self.clock = clock
        self.sleep = sleep
        presenter.onSelect = { [weak self] in self?.select($0) }
        presenter.onHover = { [weak self] in self?.hover($0) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Self.log.debug("watching selections")
        shiftDown = NSEvent.modifierFlags.contains(.shift)
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .scrollWheel, .flagsChanged]) { [weak self] event in
            let raw = RawEvent(event)
            MainActor.assumeIsolated { self?.receive(raw) }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handle(.applicationChanged, now: self.clock())
            }
        }
    }

    func stop() {
        generation += 1
        pending?.cancel(); pending = nil
        downElement?.cancel(); downElement = nil
        removeShiftKeyMonitor()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        hideBubble()
        core = SelectionWatcherCore()
        isRunning = false
        Self.log.debug("stopped watching selections")
    }

    /// A rule's shortcut is a Carbon hot key, which the key monitor never sees, so the rule tells the watcher
    /// itself. Without this the bubble stayed beside the answer panel, or a read already scheduled showed it there.
    func dismiss() {
        generation += 1
        pending?.cancel(); pending = nil
        core.interrupted()
        hideBubble()
    }

    // MARK: Inputs

    /// The parts of an event the watcher reads. The click count exists only for mouse buttons.
    private struct RawEvent {
        var type: NSEvent.EventType
        var location: CGPoint
        var clickCount = 0
        var flags: NSEvent.ModifierFlags

        init(_ event: NSEvent) {
            type = event.type
            location = NSEvent.mouseLocation
            flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if [.leftMouseDown, .leftMouseUp, .rightMouseDown].contains(event.type) { clickCount = event.clickCount }
        }
    }

    private func receive(_ event: RawEvent) {
        let now = clock()
        switch event.type {
        case .leftMouseDown: handle(.mouseDown(event.location, clickCount: event.clickCount, right: false), now: now)
        case .rightMouseDown: handle(.mouseDown(event.location, clickCount: event.clickCount, right: true), now: now)
        case .leftMouseUp: handle(.mouseUp(event.location, clickCount: event.clickCount, modifiers: Self.modifiers(event.flags)), now: now)
        case .scrollWheel: handle(.scroll, now: now)
        case .flagsChanged:
            modifiersChanged(Self.modifiers(event.flags), mouseButtonDown: NSEvent.pressedMouseButtons != 0, now: now)
        default: break
        }
    }

    /// Shift going up while no mouse button is down ends a keyboard selection, or a shortcut when Command or Control
    /// went down while it was held.
    func modifiersChanged(_ modifiers: BubbleModifiers, mouseButtonDown: Bool, now: Date) {
        let shift = modifiers.contains(.shift)
        if shift, !shiftDown {
            shortcutWithShift = false
            shiftKeys = ShiftKeys()
            installShiftKeyMonitor()
        }
        if shift, !modifiers.isDisjoint(with: [.command, .control]) { shortcutWithShift = true }
        let released = shiftDown && !shift && !mouseButtonDown
        shiftDown = shift
        if !shift { removeShiftKeyMonitor() }
        guard released else { return }
        // Shift after a capital letter, a shortcut or a Shift-click selects nothing, and a field may still show an
        // autocompleted selection then. Only Shift with the arrow keys, Home, End or the page keys does.
        guard shiftKeys.endsSelection else {
            Self.log.debug("shift released without selection keys: navigation \(self.shiftKeys.navigation), other keys \(self.shiftKeys.other)")
            return
        }
        handle(.shiftReleased, now: now)
    }

    /// A key went down while Shift was held. Only its code.
    func shiftKeyPressed(keyCode: UInt16) { shiftKeys.pressed(keyCode: keyCode) }

    private func installShiftKeyMonitor() {
        guard isRunning, shiftKeyMonitor == nil else { return }
        shiftKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            MainActor.assumeIsolated { self?.shiftKeyPressed(keyCode: keyCode) }
        }
    }

    private func removeShiftKeyMonitor() {
        if let shiftKeyMonitor { NSEvent.removeMonitor(shiftKeyMonitor) }
        shiftKeyMonitor = nil
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> BubbleModifiers {
        var modifiers: BubbleModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    /// One input, already reduced to what the bubble decides on.
    func handle(_ input: SelectionInput, now: Date) {
        // Scrolling sends many events; with nothing pending, being read or shown there is nothing to cancel.
        if input == .scroll, shown == nil, core.pendingToken == nil, reading == 0 { return }
        generation += 1
        if case let .mouseUp(point, _, _) = input { lastMouseUp = point }
        if case let .mouseDown(point, _, right) = input { beginGesture(at: point, right: right) }
        let effects = core.receive(input, now: now, options: hooks.options())
        switch input {
        case .mouseDown, .mouseUp, .shiftReleased, .applicationChanged:
            Self.log.debug("\(String(describing: input), privacy: .public) → \(String(describing: effects), privacy: .public)")
        case .scroll, .keyDown:
            if !effects.isEmpty { Self.log.debug("\(input == .scroll ? "scroll" : "key", privacy: .public) → \(String(describing: effects), privacy: .public)") }
        }
        for effect in effects {
            if case let .scheduleRead(_, _, gesture) = effect { Self.log.debug("read scheduled after \(String(describing: gesture), privacy: .public)") }
            switch effect {
            case .cancelPending:
                pending?.cancel(); pending = nil
            case let .scheduleRead(token, at, gesture):
                let keyboard = gesture == .keyboard
                // Command or Control with Shift is a shortcut, unless a navigation key came with it: Shift Command Left
                // selects to the start of the line.
                schedule(token: token, delay: max(at.timeIntervalSince(now), 0), gesture: gesture,
                         pointer: keyboard ? nil : lastMouseUp, start: keyboard ? nil : lastMouseDown,
                         element: keyboard ? nil : downElement,
                         afterShortcut: keyboard && shortcutWithShift && !shiftKeys.navigation)
            case .dismiss:
                hideBubble()
            }
        }
    }

    /// A left mouse down looks up what is under the pointer, once, off the main thread. A right click opens a menu and
    /// selects nothing.
    private func beginGesture(at point: CGPoint, right: Bool) {
        downElement?.cancel()
        downElement = nil
        lastMouseDown = right ? nil : point
        guard !right else { return }
        let state = hooks.state()
        guard state.bubbleEnabled, state.accessibilityTrusted else { return }
        let lookup = system.pointElement
        downElement = Task { await lookup(point) }
    }

    // MARK: Reading

    private func schedule(token: Int, delay: TimeInterval, gesture: SelectionGesture, pointer: CGPoint?, start: CGPoint?,
                          element: Task<PointElement?, Never>?, afterShortcut: Bool) {
        pending?.cancel()
        pending = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.settle(token: token, gesture: gesture, pointer: pointer, start: start, element: element,
                               afterShortcut: afterShortcut)
        }
    }

    /// After the quiet time: checks, reads without context, checks again, shows.
    private func settle(token: Int, gesture: SelectionGesture, pointer: CGPoint?, start: CGPoint?,
                        element: Task<PointElement?, Never>?, afterShortcut: Bool) async {
        guard core.settleFired(token: token) else { return }
        pending = nil
        guard let front = system.frontmost() else { return }
        let options = hooks.options()
        let state = hooks.state()
        let context = BubbleContext(explainEnabled: state.explainEnabled, bubbleEnabled: state.bubbleEnabled,
                                    writingEnabled: state.writingEnabled, accessibilityTrusted: state.accessibilityTrusted,
                                    frogFrontmost: front.pid == system.ownPID, secureInput: system.secureInput(),
                                    bundleID: front.bundleID, isGame: isGame(front), busy: state.busy)
        if let block = SelectionBubblePolicy.mayRead(context, options: options) {
            Self.log.debug("not read in \(front.bundleID ?? "?", privacy: .public): \(String(describing: block), privacy: .public)")
            return
        }
        let started = generation
        // A gesture that began on a control or a window part is not a selection, whatever text is selected elsewhere.
        if let element {
            let found = await element.value
            guard started == generation else {
                Self.log.debug("gesture in \(front.bundleID ?? "?", privacy: .public) dropped by a later input")
                return
            }
            if let block = SelectionBubblePolicy.mayStartSelection(on: found) {
                Self.log.debug("not read in \(front.bundleID ?? "?", privacy: .public): \(String(describing: block), privacy: .public), began on \(found?.role ?? "?", privacy: .public) in \(String(describing: found?.ancestors.first), privacy: .public)")
                return
            }
        }
        reading += 1
        let read = await readSelection(front, options: options, started: started)
        reading -= 1
        guard let result = read else {
            Self.log.debug("read in \(front.bundleID ?? "?", privacy: .public) dropped by a later input")
            return
        }
        if result == .unavailable, options.chromiumApps, offersWithoutText(front) {
            offerWithoutText(in: front, token: token, pointer: pointer, start: start, gesture: gesture)
            return
        }
        var items: (visible: [BubbleItem], more: [BubbleItem]) = ([], [])
        var reselected = false
        if case let .selection(snapshot) = result {
            items = hooks.items(snapshot)
            // Dragging a window or pressing a shortcut with Shift ends like a selection but leaves the old one.
            reselected = SelectionBubblePolicy.reselects(pointer: pointer, start: start, afterShortcut: afterShortcut,
                                                         bounds: snapshot.bounds, endBounds: snapshot.endBounds)
        }
        if let block = SelectionBubblePolicy.mayShow(result, dismissed: core.dismissedFingerprint, shown: core.shownFingerprint,
                                                     offered: core.offeredFingerprint, reselected: reselected,
                                                     itemCount: items.visible.count + items.more.count) {
            Self.log.debug("not shown in \(front.bundleID ?? "?", privacy: .public): \(String(describing: block), privacy: .public) after \(Self.kind(result), privacy: .public)")
            return
        }
        guard case let .selection(snapshot) = result else { return }
        // At the end of the selection and as tall as all of it, so the list never opens over its earlier lines; a
        // mouse gesture without a position uses the mouse-up point.
        let anchor = SelectionAnchor.end(snapshot.endBounds, selection: snapshot.bounds)
        guard anchor != nil || pointer != nil else {
            Self.log.debug("not shown in \(front.bundleID ?? "?", privacy: .public): no position")
            return
        }
        show(snapshot, items: items, anchor: anchor, pointer: pointer ?? anchor.map { CGPoint(x: $0.minX, y: $0.minY) } ?? .zero)
    }

    /// An app built on Chromium keeps its text hidden, so a mouse gesture that ended in its content may have selected
    /// text. The bubble offers answer rules at the pointer; the rule picked copies the selection as its shortcut does.
    private func offerWithoutText(in app: BubbleApplication, token: Int, pointer: CGPoint?, start: CGPoint?,
                                  gesture: SelectionGesture) {
        let window = pointer.flatMap { system.windowFrame(app.pid, $0) }
        if let block = SelectionBubblePolicy.mayOfferWithoutText(pointer: pointer, window: window, start: start, gesture: gesture) {
            Self.log.debug("not shown in \(app.bundleID ?? "?", privacy: .public) without text: \(String(describing: block), privacy: .public)")
            return
        }
        guard let pointer else { return }
        let snapshot = SelectionSnapshot.hidden(pid: app.pid, bundleID: app.bundleID, gesture: token)
        let items = hooks.items(snapshot)
        guard items.visible.count + items.more.count > 0 else {
            Self.log.debug("not shown in \(app.bundleID ?? "?", privacy: .public) without text: noItems")
            return
        }
        show(snapshot, items: items, anchor: nil, pointer: pointer)
    }

    private func show(_ snapshot: SelectionSnapshot, items: (visible: [BubbleItem], more: [BubbleItem]), anchor: CGRect?,
                      pointer: CGPoint) {
        Self.log.debug("shown in \(snapshot.bundleID ?? "?", privacy: .public) with \(items.visible.count + items.more.count) rules\(snapshot.textHidden ? " without text" : "", privacy: .public) at \(String(describing: anchor), privacy: .public), pointer \(String(describing: pointer), privacy: .public)")
        shown = snapshot
        hovering = false
        core.shown(snapshot.fingerprint, now: clock())
        presenter.show(visible: items.visible, more: items.more, anchor: anchor, pointer: pointer)
        installKeyMonitor()
        startIdleCheck()
    }

    /// Reads the selection, and once more when it came back without one: apps sometimes report a fresh selection a
    /// moment late. Nil when a later input or a stop came in between.
    private func readSelection(_ app: BubbleApplication, options: SelectionBubbleOptions, started: Int) async -> SelectionReadResult? {
        let pid = app.pid
        let result = await reader.read(pid: pid, maxCharacters: options.maxCharacters, includeContext: false)
        Self.log.debug("first read: \(Self.kind(result), privacy: .public)")
        guard started == generation else { return nil }
        switch result {
        case .empty, .unavailable: break
        default: return result
        }
        do { try await sleep(Self.retryWait) } catch { return nil }
        guard started == generation, !Task.isCancelled else { return nil }
        let again = await reader.read(pid: pid, maxCharacters: options.maxCharacters, includeContext: false)
        Self.log.debug("second read: \(Self.kind(again), privacy: .public)")
        return started == generation ? again : nil
    }

    /// A read's outcome without its text.
    private static func kind(_ result: SelectionReadResult) -> String {
        switch result {
        case let .selection(snapshot):
            "selection of \((snapshot.text as NSString).length) characters, editable \(snapshot.isEditable), bounds \(snapshot.bounds.map { "\($0)" } ?? "none")"
        case .empty: "empty"
        case .secure: "secure"
        case let .tooLong(length): "too long (\(length))"
        case .unavailable: "unavailable"
        }
    }

    static let retryWait: TimeInterval = 0.15

    private func isGame(_ app: BubbleApplication) -> Bool {
        guard let id = app.bundleID else { return false }
        if let known = games[id] { return known }
        let game = SelectionBubblePolicy.isGame(applicationCategory: app.bundleURL.flatMap(system.category))
        games[id] = game
        return game
    }

    private func offersWithoutText(_ app: BubbleApplication) -> Bool {
        if let id = app.bundleID, let known = withoutText[id] { return known }
        let offers = app.bundleURL.map(system.builtOnChromium) ?? false
            && SelectionBubblePolicy.offersWithoutText(bundleID: app.bundleID,
                                                       builtOnVSCode: app.bundleURL.map(system.builtOnVSCode) ?? false)
        if let id = app.bundleID { withoutText[id] = offers }
        return offers
    }

    // MARK: The bubble

    private func select(_ item: BubbleItem) {
        guard let snapshot = shown else { return }
        core.hidden()
        hideBubble()
        hooks.run(item, snapshot)
    }

    private func hover(_ inside: Bool) {
        hovering = inside
        core.hovered(now: clock())
    }

    /// Hides the bubble after six seconds without the pointer over it.
    func checkIdle() {
        guard shown != nil else { return }
        let now = clock()
        if hovering { core.hovered(now: now) }
        guard core.shouldIdleDismiss(now: now) else { return }
        core.hidden()
        hideBubble()
    }

    private func startIdleCheck() {
        idleCheck?.cancel()
        idleCheck = Task { [weak self, sleep] in
            while !Task.isCancelled {
                do { try await sleep(1) } catch { return }
                guard let self, self.shown != nil else { return }
                self.checkIdle()
            }
        }
    }

    private func hideBubble() {
        shown = nil
        hovering = false
        idleCheck?.cancel(); idleCheck = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if presenter.isVisible { presenter.hide() }
    }

    /// Any key hides the bubble, Escape for this selection. Only the key code and the modifier keys are read.
    private func installKeyMonitor() {
        guard isRunning, keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handle(.keyDown(keyCode: keyCode, modifiers: Self.modifiers(flags)), now: self.clock())
            }
        }
    }
}

/// Looks up the element under a point through Accessibility, by role only, on a background task: the call waits for
/// the other app, so a bound on each call and on the whole walk keeps an app that does not answer from holding it.
enum PointElementLookup {
    static let timeout: Float = 0.2
    static let deadline: TimeInterval = 0.35
    static let maxDepth = 12

    static func element(at point: CGPoint) async -> PointElement? {
        await Task.detached(priority: .userInitiated) { lookup(point) }.value
    }

    private static func lookup(_ point: CGPoint) -> PointElement? {
        let started = Date()
        // No timeout on the system-wide element: set there, it becomes the default for every Accessibility call Frog
        // makes, as WindowDragMonitor notes. Only the element the hit test returns is bounded.
        let system = AXUIElementCreateSystemWide()
        var found: AXUIElement?
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(primaryHeight - point.y), &found) == .success,
              let leaf = found else { return nil }
        AXUIElementSetMessagingTimeout(leaf, timeout)
        let role = AXRead.string(leaf, kAXRoleAttribute)
        let subrole = AXRead.string(leaf, kAXSubroleAttribute)
        var ancestors: [String] = []
        // A text field or a control already decides; anything else is judged by what holds it.
        let decided = role.map { SelectionBubblePolicy.editableRoles.contains($0) || SelectionBubblePolicy.nonTextRoles.contains($0) } ?? false
        if !decided {
            var current = leaf
            while ancestors.count < maxDepth, Date().timeIntervalSince(started) < deadline,
                  let parent = AXRead.element(current, kAXParentAttribute, timeout: timeout),
                  let parentRole = AXRead.string(parent, kAXRoleAttribute) {
                ancestors.append(parentRole)
                if parentRole == "AXWindow" || parentRole == "AXWebArea" { break }
                current = parent
            }
        }
        return PointElement(role: role, subrole: subrole, ancestors: ancestors)
    }
}

/// Stands in for the watcher where Frog registers no global shortcuts, such as tests.
@MainActor final class SilentSelectionWatcher: SelectionWatching {
    private(set) var isRunning = false
    func start() { isRunning = true }
    func stop() { isRunning = false }
    func dismiss() {}
}
