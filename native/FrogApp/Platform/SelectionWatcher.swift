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
/// Accessibility only and hands the result to the presenter. It never copies and never sees typed characters: key
/// presses are watched only while the bubble shows, and then only their key code and modifier keys.
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

        static let live = System(
            frontmost: {
                guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
                return BubbleApplication(pid: app.processIdentifier, bundleID: app.bundleIdentifier, bundleURL: app.bundleURL)
            },
            ownPID: ProcessInfo.processInfo.processIdentifier,
            secureInput: { IsSecureEventInputEnabled() },
            category: { Bundle(url: $0)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String },
            builtOnVSCode: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Resources/app/product.json").path) })
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
    /// Whether an app may be asked to expose its text, by bundle identifier.
    private var askable: [String: Bool] = [:]
    /// Apps already asked to expose their text, by process.
    private var asked: Set<pid_t> = []
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
        if shift, !shiftDown { shortcutWithShift = false }
        if shift, !modifiers.isDisjoint(with: [.command, .control]) { shortcutWithShift = true }
        let released = shiftDown && !shift && !mouseButtonDown
        shiftDown = shift
        if released { handle(.shiftReleased, now: now) }
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
                schedule(token: token, delay: max(at.timeIntervalSince(now), 0), gesture: gesture,
                         pointer: keyboard ? nil : lastMouseUp, afterShortcut: keyboard && shortcutWithShift)
            case .dismiss:
                hideBubble()
            }
        }
    }

    // MARK: Reading

    private func schedule(token: Int, delay: TimeInterval, gesture: SelectionGesture, pointer: CGPoint?, afterShortcut: Bool) {
        pending?.cancel()
        pending = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.settle(token: token, gesture: gesture, pointer: pointer, afterShortcut: afterShortcut)
        }
    }

    /// After the quiet time: checks, reads without context, checks again, shows.
    private func settle(token: Int, gesture: SelectionGesture, pointer: CGPoint?, afterShortcut: Bool) async {
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
        reading += 1
        let read = await readSelection(front, options: options, started: started)
        reading -= 1
        guard let result = read else {
            Self.log.debug("read in \(front.bundleID ?? "?", privacy: .public) dropped by a later input")
            return
        }
        var items: (visible: [BubbleItem], more: [BubbleItem]) = ([], [])
        var reselected = false
        if case let .selection(snapshot) = result {
            items = hooks.items(snapshot)
            // Dragging a window or pressing a shortcut with Shift ends like a selection but leaves the old one.
            reselected = SelectionBubblePolicy.reselects(pointer: pointer, afterShortcut: afterShortcut,
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
        Self.log.debug("shown in \(front.bundleID ?? "?", privacy: .public) with \(items.visible.count + items.more.count) rules at \(String(describing: anchor), privacy: .public), pointer \(String(describing: pointer), privacy: .public)")
        shown = snapshot
        hovering = false
        core.shown(snapshot.fingerprint, now: clock())
        presenter.show(visible: items.visible, more: items.more, anchor: anchor,
                       pointer: pointer ?? anchor.map { CGPoint(x: $0.minX, y: $0.minY) } ?? .zero)
        installKeyMonitor()
        startIdleCheck()
    }

    /// Reads the selection, and once more when it came back without one: an app that hides its text until asked is
    /// asked first, and other apps sometimes report a fresh selection a moment late. Nil when a later input or a stop
    /// came in between.
    private func readSelection(_ app: BubbleApplication, options: SelectionBubbleOptions, started: Int) async -> SelectionReadResult? {
        let pid = app.pid
        var result = await reader.read(pid: pid, maxCharacters: options.maxCharacters, includeContext: false)
        Self.log.debug("first read: \(Self.kind(result), privacy: .public)")
        guard started == generation else { return nil }
        switch result {
        case .empty, .unavailable: break
        default: return result
        }
        var wait = Self.retryWait
        if options.exposeText, mayAskToExposeText(app), asked.insert(pid).inserted {
            // An app that did not answer in time is asked again with its next selection.
            let answer = await reader.exposeText(pid: pid)
            Self.log.debug("asked to expose text: \(String(describing: answer), privacy: .public)")
            if answer == .noAnswer { asked.remove(pid) }
            // The app builds its accessibility tree after the request. An older Electron app takes it while
            // answering that it refused, so every answer waits as long.
            wait = Self.exposeWait
        }
        do { try await sleep(wait) } catch { return nil }
        guard started == generation, !Task.isCancelled else { return nil }
        result = await reader.read(pid: pid, maxCharacters: options.maxCharacters, includeContext: false)
        Self.log.debug("second read: \(Self.kind(result), privacy: .public)")
        return started == generation ? result : nil
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

    static let exposeWait: TimeInterval = 0.35
    static let retryWait: TimeInterval = 0.15

    private func isGame(_ app: BubbleApplication) -> Bool {
        guard let id = app.bundleID else { return false }
        if let known = games[id] { return known }
        let game = SelectionBubblePolicy.isGame(applicationCategory: app.bundleURL.flatMap(system.category))
        games[id] = game
        return game
    }

    private func mayAskToExposeText(_ app: BubbleApplication) -> Bool {
        if let id = app.bundleID, let known = askable[id] { return known }
        let may = SelectionBubblePolicy.mayAskToExposeText(bundleID: app.bundleID,
                                                           builtOnVSCode: app.bundleURL.map(system.builtOnVSCode) ?? false)
        if let id = app.bundleID { askable[id] = may }
        return may
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

/// Stands in for the watcher where Frog registers no global shortcuts, such as tests.
@MainActor final class SilentSelectionWatcher: SelectionWatching {
    private(set) var isRunning = false
    func start() { isRunning = true }
    func stop() { isRunning = false }
    func dismiss() {}
}
