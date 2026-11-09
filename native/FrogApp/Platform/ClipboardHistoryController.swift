import AppKit
import ApplicationServices
import SwiftUI
import Combine
import FrogCore
import os

@MainActor
protocol ClipboardHistoryPasteTarget {
    var applicationPID: pid_t? { get }
    func prepareForPaste(isCurrent: () -> Bool) async throws
    func paste() throws
}

extension ClipboardHistoryPasteTarget {
    var applicationPID: pid_t? { nil }
    func prepareForPaste(isCurrent: () -> Bool) async throws { }
}

@MainActor
enum ClipboardHistoryDelivery {
    /// `write` puts the item on the pasteboard; by default it is written directly. An item from
    /// clipboard history is written through its store, which then does not read it back as a copy.
    static func paste(_ entry: ClipboardHistoryEntry, plainText: Bool, pasteboard: NSPasteboard,
                      target: (any ClipboardHistoryPasteTarget)?, isCurrent: () -> Bool,
                      write: (() -> Bool)? = nil,
                      waitForRelease: () async throws -> Void = { try await ClipboardSelection.waitForShortcutRelease() }) async throws {
        try await waitForRelease()
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        var preparationError: Error?
        do { try await target?.prepareForPaste(isCurrent: isCurrent) }
        catch is CancellationError { throw CancellationError() }
        catch { preparationError = error }
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        guard write?() ?? entry.write(to: pasteboard, plainText: plainText) else { throw FrogError.message("Could not copy the clipboard item.") }
        if let preparationError { throw preparationError }
        guard let target else {
            throw FrogError.message(copyOnlyMessage(trusted: SelectionService.isTrusted,
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                ownPID: ProcessInfo.processInfo.processIdentifier))
        }
        try target.paste()
    }

    /// Why an item chosen without a captured field is only copied. Accessibility is named
    /// only when it is what is missing; a field in Frog's own windows is never a target.
    static func copyOnlyMessage(trusted: Bool, frontmostPID: pid_t?, ownPID: pid_t) -> String {
        if frontmostPID == ownPID { return "The item is copied. Frog does not paste into its own windows; paste it manually." }
        if !trusted { return "The item is copied. Allow Accessibility for automatic paste, or paste it manually." }
        return "The item is copied. Focus an editable field and paste."
    }
}

@MainActor
final class ClipboardHistoryController {
    /// Why a chosen item was not pasted, without what it holds: `log show --predicate 'subsystem == "frog" && category == "clipboard"'`.
    private static let log = Logger(subsystem: "frog", category: "clipboard")
    let history: ClipboardHistoryStore
    var onError: ((Error) -> Void)?
    var onSuccessfulPaste: (() -> Void)?
    private var panel: ClipboardPanel?
    let state = ClipboardHistoryPanelState()
    private var target: (any ClipboardHistoryPasteTarget)?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var deliveryInputMonitor: Any?
    private var deliveryLocalMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var delivery: Task<Void, Never>?
    private var operation = UUID()
    private var historyObservation: AnyCancellable?
    /// The panel opens wherever the pointer is, so only a pointer moved on purpose selects a row.
    private var pointer = WindowSwitchPointer()
    /// Selects the row a scroll stopped under the pointer, once the list has moved.
    private var scrollSelection: Task<Void, Never>?
    private let pasteboard: NSPasteboard
    private let captureTarget: () -> (any ClipboardHistoryPasteTarget)?
    private let waitForRelease: () async throws -> Void
    private let activationNotifications: NotificationCenter
    /// Places the panel with the command bar and the window switcher, where the family was last dragged to.
    let placement: PanelFamilyPlacer

    init(pasteboard: NSPasteboard = .general, history: ClipboardHistoryStore? = nil,
         captureTarget: (() -> (any ClipboardHistoryPasteTarget)?)? = nil,
         waitForRelease: (() async throws -> Void)? = nil,
         activationNotifications: NotificationCenter? = nil,
         placement: PanelFamilyPlacer? = nil) {
        self.placement = placement ?? PanelFamilyPlacer()
        self.pasteboard = pasteboard
        self.history = history ?? ClipboardHistoryStore(pasteboard: pasteboard)
        self.captureTarget = captureTarget ?? { NativeClipboardHistoryPasteTarget.captureAny() }
        self.waitForRelease = waitForRelease ?? { try await ClipboardSelection.waitForShortcutRelease() }
        self.activationNotifications = activationNotifications ?? NSWorkspace.shared.notificationCenter
        state.update(self.history.entries)
        historyObservation = self.history.$entries.dropFirst().sink { [weak self] entries in
            guard let self else { return }
            // The selection stays on its item when a copy arrives or an item goes.
            self.state.update(entries)
            // Rows that move under a pointer at rest do not take the selection.
            self.pointer.relaid(at: NSEvent.mouseLocation)
            self.resizePanel()
        }
    }

    func configure(enabled: Bool, automaticallyPoll: Bool = true) {
        if !enabled { hide(); panel?.contentView = nil; panel = nil; delivery?.cancel(); delivery = nil; operation = UUID() }
        history.configure(enabled: enabled, automaticallyPoll: automaticallyPoll)
    }

    var isVisible: Bool { panel?.isVisible == true }

    /// Builds the panel and lays it out without showing it, so that the first press of the shortcut is as quick
    /// as every later one. Released again by `stop()`.
    func prepare() {
        guard history.enabled, panel == nil else { return }
        let panel = makePanel()
        panel.contentView?.layoutSubtreeIfNeeded()
        self.panel = panel
    }

    /// Opens the panel at once, with the search focused, or closes it when it is open.
    func show() {
        guard history.enabled else { return }
        if panel?.isVisible == true { hide(); return }
        cancel()
        target = captureTarget()
        state.query = ""
        state.selectFirst()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        resizePanel()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                if event.type == .scrollWheel {
                    // Scrolling elsewhere in Frog leaves the panel open, as it always did.
                    if event.window === self.panel { self.pointerScrolled() }
                    return event
                }
                if event.type != .keyDown {
                    if event.window !== self.panel { self.cancel() }
                    return event
                }
                guard event.window === self.panel else { self.cancel(); return event }
                return self.handleKey(event) ? nil : event
            }
        }
        let openedAt = ProcessInfo.processInfo.systemUptime
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            // A global callback for the invoking shortcut can arrive after show.
            guard event.timestamp > openedAt, Self.isNewInput(event) else { return }
            MainActor.assumeIsolated { self?.cancel() }
        }
        workspaceObserver = activationNotifications.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                    if let pid, pid == self.target?.applicationPID { return }
                    self.cancel("another app became active")
                }
            }
        // On the display under the pointer, where the panel family was last dragged to there.
        placement.place(panel, size: ClipboardHistoryLayout.size(entryCount: state.visible.count))
        panel.makeKeyAndOrderFront(nil)
        pointer.rest(at: NSEvent.mouseLocation)
        state.focusSearch()
    }

    /// The row under a pointer that moved on purpose becomes the selection, so the one highlighted row is
    /// always the one Return pastes.
    private func pointerMoved(over id: UUID) {
        guard panel?.isVisible == true, pointer.selects(at: NSEvent.mouseLocation) else { return }
        state.select(id: id, byPointer: true)
    }

    /// A scroll in the list selects the row it leaves under the pointer: at once, and again once the
    /// scroll view has caught up with the last event of a flick.
    private func pointerScrolled() {
        scrollSelection?.cancel()
        scrollSelection = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.selectRowUnderPointer()
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            self.selectRowUnderPointer()
            self.scrollSelection = nil
        }
    }

    /// Return or Command-C right after a scroll acts on the row the scroll stopped at, not one it has not reached yet.
    private func settleScrollSelection() {
        guard scrollSelection != nil else { return }
        scrollSelection?.cancel(); scrollSelection = nil
        selectRowUnderPointer()
    }

    private func selectRowUnderPointer() {
        guard let panel, panel.isVisible, let content = panel.contentView else { return }
        let location = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard let scroll = Self.scrollViews(in: content).first(where: { $0.convert($0.bounds, to: nil).contains(location) }),
              let document = scroll.documentView else { return }
        let point = document.convert(location, from: nil)
        let fromTop = document.isFlipped ? point.y : document.bounds.height - point.y
        guard let index = ClipboardHistoryLayout.row(at: fromTop, count: state.visible.count) else { return }
        state.select(index: index, byPointer: true)
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    private func makePanel() -> ClipboardPanel {
        let size = ClipboardHistoryLayout.size(entryCount: state.visible.count)
        let panel = ClipboardPanel(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false; panel.level = .floating
        panel.acceptsMouseMovedEvents = true
        // A keyboard surface opens in one frame: no zoom or fade from AppKit.
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = L10n.text("Clipboard history")
        let hosting = ClipboardHistoryHostingView(rootView: ClipboardHistoryView(state: state,
            paste: { [weak self] in self?.choose($0, plainText: $1) },
            copy: { [weak self] in self?.copy($0) },
            close: { [weak self] in self?.hide() },
            resize: { [weak self] in self?.resizePanel() },
            hover: { [weak self] in self?.pointerMoved(over: $0) }, placement: placement))
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }

    /// The keys that act on the list while the search has focus. True when the key was used.
    private func handleKey(_ event: NSEvent) -> Bool {
        if Self.isCopyShortcut(event) {
            // Text selected in the search copies as text does anywhere.
            if let text = panel?.firstResponder as? NSTextView, text.selectedRange().length > 0 { return false }
            settleScrollSelection()
            if let selected = state.selected { copy(selected) }
            return true
        }
        // An input method composing in the search needs Escape, the arrows and Return for its candidates.
        if Self.isComposing(panel?.firstResponder) { return false }
        switch event.keyCode {
        case 53: hide(); return true
        case 125, 126:
            // The keys take the selection back from a scroll still settling and from a resting pointer.
            scrollSelection?.cancel(); scrollSelection = nil
            state.moveSelection(by: event.keyCode == 125 ? 1 : -1)
            pointer.rest(at: NSEvent.mouseLocation)
            return true
        case 36, 76:
            settleScrollSelection()
            if let selected = state.selected { choose(selected, plainText: event.modifierFlags.contains(.shift)) }
            return true
        default: return false
        }
    }

    /// Command-C as the keyboard layout types it while Command is held, which on Dvorak is not
    /// the key at the QWERTY position and on a Cyrillic layout still is. An event that carries
    /// no characters falls back to that position.
    static func isCopyShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command else { return false }
        guard let characters = event.characters, !characters.isEmpty else { return event.keyCode == 8 }
        return characters.lowercased() == "c"
    }

    /// A trackpad flick keeps coasting after the fingers left, and fingers resting on the
    /// trackpad send scrolls that move nothing. A key held a moment too long repeats, such as
    /// the Return that chose the item. None of these is input made after the panel opened or
    /// an item was chosen, so none closes the panel or stops a paste.
    nonisolated static func isNewInput(_ event: NSEvent) -> Bool {
        if event.type == .keyDown { return !event.isARepeat }
        guard event.type == .scrollWheel else { return true }
        return event.momentumPhase.isEmpty && (event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0)
    }

    private func resizePanel() {
        let count = state.visible.count
        state.selectedIndex = max(0, min(state.selectedIndex, count - 1))
        guard let panel else { return }
        placement.resize(panel, to: ClipboardHistoryLayout.size(entryCount: count))
    }

    private func copy(_ entry: ClipboardHistoryEntry) {
        guard history.copy(entry) else { onError?(FrogError.message("Could not copy the clipboard item.")); return }
        cancel()
    }

    private func choose(_ entry: ClipboardHistoryEntry, plainText: Bool) {
        let target = target
        hide(keepingActivationObserver: true)
        self.target = target
        // No range is exposed by some IDEs. Input after choosing is therefore
        // an essential invalidation signal, including during focus restoration.
        deliveryInputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            guard Self.isNewInput(event) else { return }
            MainActor.assumeIsolated { self?.cancel("new input in another app") }
        }
        deliveryLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            guard Self.isNewInput(event) else { return event }
            MainActor.assumeIsolated { self?.cancel("new input in Frog") }
            return event
        }
        deliver(entry, plainText: plainText, to: target)
    }

    /// Pastes a chosen item into the field captured when the panel opened. The store writes it,
    /// so the item keeps its row and is not read back as a new copy.
    func deliver(_ entry: ClipboardHistoryEntry, plainText: Bool, to target: (any ClipboardHistoryPasteTarget)?) {
        let token = UUID(); operation = token; delivery?.cancel()
        delivery = Task { [weak self] in
            do {
                guard let self else { return }
                try await self.paste(entry, plainText: plainText, to: target, token: token, waitForRelease: self.waitForRelease)
                self.onSuccessfulPaste?()
            } catch is CancellationError { }
            catch {
                Self.log.notice("Paste failed: \(error.localizedDescription, privacy: .public)")
                self?.onError?(error)
            }
            if self?.operation == token { self?.hide(); self?.delivery = nil }
        }
    }

    /// `clipboard.paste`: pastes into the field that has focus now, and says why when it only copied.
    func paste(_ entry: ClipboardHistoryEntry, plainText: Bool = false) async throws {
        cancel()
        let token = UUID(); operation = token
        try await paste(entry, plainText: plainText, to: captureTarget(), token: token, waitForRelease: {})
        onSuccessfulPaste?()
    }

    private func paste(_ entry: ClipboardHistoryEntry, plainText: Bool, to target: (any ClipboardHistoryPasteTarget)?,
                       token: UUID, waitForRelease: () async throws -> Void) async throws {
        let retention = history.retentionGeneration
        try await ClipboardHistoryDelivery.paste(entry, plainText: plainText, pasteboard: pasteboard,
            target: target, isCurrent: { [weak self] in
                self?.operation == token && self?.history.enabled == true && self?.history.retentionGeneration == retention &&
                self?.history.entries.contains(where: { $0.id == entry.id }) == true
            },
            write: { [weak self] in self?.history.copy(entry, plainText: plainText) == true },
            waitForRelease: waitForRelease)
    }

    func hide(keepingActivationObserver: Bool = false) {
        panel?.orderOut(nil); target = nil
        scrollSelection?.cancel(); scrollSelection = nil
        state.query = ""
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
        if let deliveryInputMonitor { NSEvent.removeMonitor(deliveryInputMonitor) }; deliveryInputMonitor = nil
        if let deliveryLocalMonitor { NSEvent.removeMonitor(deliveryLocalMonitor) }; deliveryLocalMonitor = nil
        if !keepingActivationObserver { removeActivationObserver() }
    }

    private func removeActivationObserver() {
        if let workspaceObserver { activationNotifications.removeObserver(workspaceObserver) }; workspaceObserver = nil
    }

    func cancel(_ reason: String = "cancelled") {
        if delivery != nil { Self.log.notice("Paste stopped: \(reason, privacy: .public)") }
        hide(); operation = UUID(); delivery?.cancel(); delivery = nil
    }
    func stop() { configure(enabled: false) }
    func waitForDelivery() async { await delivery?.value }
    static func isComposing(_ responder: NSResponder?) -> Bool {
        (responder as? NSTextInputClient)?.hasMarkedText() == true
    }
    isolated deinit {
        panel?.orderOut(nil); panel?.contentView = nil
        delivery?.cancel()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let deliveryInputMonitor { NSEvent.removeMonitor(deliveryInputMonitor) }
        if let deliveryLocalMonitor { NSEvent.removeMonitor(deliveryLocalMonitor) }
        if let workspaceObserver { activationNotifications.removeObserver(workspaceObserver) }
    }
}

private final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Reveal/paste must accept the first click while another app remains active.
private final class ClipboardHistoryHostingView: NSHostingView<ClipboardHistoryView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// What the open panel shows: the search, the items it matches, and which one is selected. The selection is
/// the only highlight, and Return, Command-C and a double click act on exactly that row.
@MainActor @Observable
final class ClipboardHistoryPanelState {
    var query = "" { didSet { if query != oldValue { selectedIndex = 0; selectionFromPointer = false; refresh() } } }
    var selectedIndex = 0
    /// Whether the pointer chose the selected row; the list then does not scroll it out from under the pointer.
    private(set) var selectionFromPointer = false
    private(set) var visible: [ClipboardHistoryEntry] = []
    /// Changes each time the panel opens, which puts the cursor in the search.
    private(set) var focusRequest = 0
    /// When the panel last opened; its rows count their relative times again from then.
    private(set) var openedAt = FrogClock.now
    @ObservationIgnored private var entries: [ClipboardHistoryEntry] = []

    var selected: ClipboardHistoryEntry? { visible.indices.contains(selectedIndex) ? visible[selectedIndex] : nil }
    var total: Int { entries.count }

    /// New entries keep the selection on its item: a copy arriving on top moves it down with its row, and an
    /// item copied again, which comes back as a new entry, stays selected.
    func update(_ entries: [ClipboardHistoryEntry]) {
        let previous = selected
        self.entries = entries; refresh()
        if let previous, let index = visible.firstIndex(where: { $0.id == previous.id })
            ?? visible.firstIndex(where: { $0.text == previous.text && $0.formatting == previous.formatting }) {
            selectedIndex = index
        } else {
            selectedIndex = max(0, min(selectedIndex, visible.count - 1))
        }
    }

    /// The arrow keys: one row down or up, stopping at the ends.
    func moveSelection(by offset: Int) {
        selectionFromPointer = false
        selectedIndex = max(0, min(visible.count - 1, selectedIndex + offset))
    }

    func select(id: UUID, byPointer: Bool = false) {
        guard let index = visible.firstIndex(where: { $0.id == id }) else { return }
        select(index: index, byPointer: byPointer)
    }

    /// The top row, as the panel opens.
    func selectFirst() { selectionFromPointer = false; selectedIndex = 0 }

    func select(index: Int, byPointer: Bool = false) {
        guard visible.indices.contains(index) else { return }
        selectionFromPointer = byPointer
        selectedIndex = index
    }

    func focusSearch() { focusRequest &+= 1; openedAt = FrogClock.now }
    private func refresh() { visible = ClipboardSearch.filter(entries, query: query) }
}
