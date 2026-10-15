import AppKit
import Carbon
import FrogCore

/// The selection bubble as `AppModel` starts and stops it.
@MainActor protocol SelectionWatching: AnyObject {
    var isRunning: Bool { get }
    func start()
    func stop()
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
/// presses are watched only while the bubble shows, and then only their key code.
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

        static let live = System(
            frontmost: {
                guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
                return BubbleApplication(pid: app.processIdentifier, bundleID: app.bundleIdentifier, bundleURL: app.bundleURL)
            },
            ownPID: ProcessInfo.processInfo.processIdentifier,
            secureInput: { IsSecureEventInputEnabled() },
            category: { Bundle(url: $0)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String })
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
    private var lastMouseUp: CGPoint?
    private var pending: Task<Void, Never>?
    private var idleCheck: Task<Void, Never>?
    private var hovering = false
    /// Counts inputs and stops, so a read that finishes after a later input or a stop shows nothing.
    private var generation = 0
    /// The selection the bubble shows now.
    private var shown: SelectionSnapshot?
    /// Whether an app is a game, by bundle identifier.
    private var games: [String: Bool] = [:]

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
            let shift = event.flags.contains(.shift)
            let released = shiftDown && !shift && NSEvent.pressedMouseButtons == 0
            shiftDown = shift
            if released { handle(.shiftReleased, now: now) }
        default: break
        }
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
        // Scrolling sends many events; with nothing pending or shown there is nothing to cancel.
        if input == .scroll, shown == nil, core.pendingToken == nil { return }
        generation += 1
        if case let .mouseUp(point, _, _) = input { lastMouseUp = point }
        for effect in core.receive(input, now: now, options: hooks.options()) {
            switch effect {
            case .cancelPending:
                pending?.cancel(); pending = nil
            case let .scheduleRead(token, at, gesture):
                schedule(token: token, delay: max(at.timeIntervalSince(now), 0), gesture: gesture,
                         pointer: gesture == .keyboard ? nil : lastMouseUp)
            case .dismiss:
                hideBubble()
            }
        }
    }

    // MARK: Reading

    private func schedule(token: Int, delay: TimeInterval, gesture: SelectionGesture, pointer: CGPoint?) {
        pending?.cancel()
        pending = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.settle(token: token, gesture: gesture, pointer: pointer)
        }
    }

    /// After the quiet time: checks, reads without context, checks again, shows.
    private func settle(token: Int, gesture: SelectionGesture, pointer: CGPoint?) async {
        guard core.settleFired(token: token) else { return }
        pending = nil
        guard let front = system.frontmost() else { return }
        let options = hooks.options()
        let state = hooks.state()
        let context = BubbleContext(explainEnabled: state.explainEnabled, bubbleEnabled: state.bubbleEnabled,
                                    writingEnabled: state.writingEnabled, accessibilityTrusted: state.accessibilityTrusted,
                                    frogFrontmost: front.pid == system.ownPID, secureInput: system.secureInput(),
                                    bundleID: front.bundleID, isGame: isGame(front), busy: state.busy)
        guard SelectionBubblePolicy.mayRead(context, options: options) == nil else { return }
        let started = generation
        let result = await reader.read(pid: front.pid, maxCharacters: options.maxCharacters, includeContext: false)
        guard started == generation else { return }
        var items: (visible: [BubbleItem], more: [BubbleItem]) = ([], [])
        if case let .selection(snapshot) = result { items = hooks.items(snapshot) }
        guard SelectionBubblePolicy.mayShow(result, dismissed: core.dismissedFingerprint, shown: core.shownFingerprint,
                                            itemCount: items.visible.count + items.more.count) == nil,
              case let .selection(snapshot) = result else { return }
        // At the end of the selection; a mouse gesture without a position uses the mouse-up point.
        let anchor = snapshot.endBounds.map { CGRect(x: $0.maxX, y: $0.minY, width: 0, height: $0.height) }
        guard anchor != nil || pointer != nil else { return }
        shown = snapshot
        hovering = false
        core.shown(snapshot.fingerprint, now: clock())
        presenter.show(visible: items.visible, more: items.more, anchor: anchor,
                       pointer: pointer ?? anchor.map { CGPoint(x: $0.minX, y: $0.minY) } ?? .zero)
        installKeyMonitor()
        startIdleCheck()
    }

    private func isGame(_ app: BubbleApplication) -> Bool {
        guard let id = app.bundleID else { return false }
        if let known = games[id] { return known }
        let game = SelectionBubblePolicy.isGame(applicationCategory: app.bundleURL.flatMap(system.category))
        games[id] = game
        return game
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

    /// Any key hides the bubble, Escape for this selection. Only the key code is read.
    private func installKeyMonitor() {
        guard isRunning, keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handle(.keyDown(keyCode: keyCode), now: self.clock())
            }
        }
    }
}

/// Stands in for the watcher where Frog registers no global shortcuts, such as tests.
@MainActor final class SilentSelectionWatcher: SelectionWatching {
    private(set) var isRunning = false
    func start() { isRunning = true }
    func stop() { isRunning = false }
}
