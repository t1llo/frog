import AppKit
import ApplicationServices
import SwiftUI
import Combine
import FrogCore

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
    static func paste(_ entry: ClipboardHistoryEntry, plainText: Bool, pasteboard: NSPasteboard,
                      target: (any ClipboardHistoryPasteTarget)?, isCurrent: () -> Bool,
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
        guard entry.write(to: pasteboard, plainText: plainText) else { throw FrogError.message("Could not copy the clipboard item.") }
        if let preparationError { throw preparationError }
        guard let target else { throw FrogError.message("The item is copied. Focus an editable field and paste, or allow Accessibility for automatic paste.") }
        try target.paste()
    }
}

@MainActor
final class ClipboardHistoryController {
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
    private let pasteboard: NSPasteboard
    private let captureTarget: () -> (any ClipboardHistoryPasteTarget)?
    private let waitForRelease: () async throws -> Void
    private let activationNotifications: NotificationCenter

    init(pasteboard: NSPasteboard = .general, history: ClipboardHistoryStore? = nil,
         captureTarget: (() -> (any ClipboardHistoryPasteTarget)?)? = nil,
         waitForRelease: (() async throws -> Void)? = nil,
         activationNotifications: NotificationCenter? = nil) {
        self.pasteboard = pasteboard
        self.history = history ?? ClipboardHistoryStore(pasteboard: pasteboard)
        self.captureTarget = captureTarget ?? { NativeClipboardHistoryPasteTarget.capture() }
        self.waitForRelease = waitForRelease ?? { try await ClipboardSelection.waitForShortcutRelease() }
        self.activationNotifications = activationNotifications ?? NSWorkspace.shared.notificationCenter
        historyObservation = self.history.$entries.dropFirst().sink { [weak self] entries in
            guard let self else { return }
            // @Published sends before mutation, so resolve the current selection
            // against the old list before an insertion/deletion shifts its index.
            let previous = self.state.visibleEntries(in: self.history.entries)
            let selectedID = previous.indices.contains(self.state.selectedIndex) ? previous[self.state.selectedIndex].id : nil
            self.state.revealedIDs.formIntersection(entries.map(\.id))
            let visible = self.state.visibleEntries(in: entries)
            self.state.selectedIndex = selectedID.flatMap { id in visible.firstIndex { $0.id == id } }
                ?? max(0, min(self.state.selectedIndex, visible.count - 1))
            self.resizePanel(entryCount: visible.count)
        }
    }

    func configure(enabled: Bool) {
        if !enabled { hide(); panel?.contentView = nil; panel = nil; delivery?.cancel(); delivery = nil; operation = UUID() }
        history.configure(enabled: enabled)
    }

    func show() {
        guard history.enabled else { return }
        if panel?.isVisible == true { hide(); return }
        cancel()
        target = captureTarget()
        state.selectedIndex = 0
        state.revealedIDs = []
        state.query = ""
        let size = ClipboardHistoryLayout.size(entryCount: history.entries.count)
        if panel == nil {
        let panel = ClipboardPanel(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = L10n.text("Clipboard history")
        let hosting = ClipboardHistoryHostingView(rootView: ClipboardHistoryView(history: history, state: state,
            paste: { [weak self] in self?.choose($0, plainText: $1) },
            copy: { [weak self] in self?.copy($0) },
            close: { [weak self] in self?.hide() }, clear: { [weak self] in self?.history.clear() },
            resize: { [weak self] in self?.resizePanel(entryCount: $0) }))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        }
        guard let panel else { return }
        resizePanel(entryCount: history.entries.count)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                if event.type != .keyDown {
                    if event.window !== self.panel { self.cancel() }
                    return event
                }
                guard event.window === self.panel else { self.cancel(); return event }
                let entries = self.state.visibleEntries(in: self.history.entries)
                let editingSearch = self.panel?.firstResponder is NSTextView
                if event.keyCode == 8, event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command {
                    if let text = self.panel?.firstResponder as? NSTextView, text.selectedRange().length > 0 { return event }
                    if entries.indices.contains(self.state.selectedIndex) {
                        self.copy(entries[self.state.selectedIndex])
                    }
                    return nil
                }
                switch event.keyCode {
                case 53: self.hide(); return nil
                case 125: self.state.selectedIndex = max(0, min(entries.count - 1, self.state.selectedIndex + 1)); return nil
                case 126: self.state.selectedIndex = max(0, self.state.selectedIndex - 1); return nil
                case 49:
                    if editingSearch { return event }
                    if entries.indices.contains(self.state.selectedIndex), entries[self.state.selectedIndex].isSensitive {
                        self.state.toggleReveal(entries[self.state.selectedIndex].id)
                    }
                    return nil
                case 36, 76:
                    if entries.indices.contains(self.state.selectedIndex) {
                        self.choose(entries[self.state.selectedIndex], plainText: event.modifierFlags.contains(.shift))
                    }
                    return nil
                default: return event
                }
            }
        }
        let openedAt = ProcessInfo.processInfo.systemUptime
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            // A global callback for the invoking shortcut can arrive after show.
            guard event.timestamp > openedAt else { return }
            MainActor.assumeIsolated { self?.cancel() }
        }
        workspaceObserver = activationNotifications.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                    if let pid, pid == self.target?.applicationPID { return }
                    self.cancel()
                }
            }
        panel.center(); panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)
    }

    private func resizePanel(entryCount: Int) {
        guard let panel else { return }
        state.selectedIndex = max(0, min(state.selectedIndex, entryCount - 1))
        let size = ClipboardHistoryLayout.size(entryCount: entryCount)
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    private func copy(_ entry: ClipboardHistoryEntry) {
        guard history.copy(entry) else { onError?(FrogError.message("Could not copy the clipboard item.")); return }
        cancel()
    }

    private func choose(_ entry: ClipboardHistoryEntry, plainText: Bool) {
        let target = target
        let retention = history.retentionGeneration
        hide(keepingActivationObserver: true)
        self.target = target
        let token = UUID(); operation = token; delivery?.cancel()
        // No range is exposed by some IDEs. Input after choosing is therefore
        // an essential invalidation signal, including during focus restoration.
        deliveryInputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        deliveryLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.cancel() }
            return event
        }
        delivery = Task { [weak self] in
            do {
                guard let self else { return }
                try await ClipboardHistoryDelivery.paste(entry, plainText: plainText, pasteboard: self.pasteboard,
                    target: target, isCurrent: { [weak self] in
                        self?.operation == token && self?.history.enabled == true && self?.history.retentionGeneration == retention &&
                        self?.history.entries.contains(where: { $0.id == entry.id }) == true
                    },
                    waitForRelease: self.waitForRelease)
                self.onSuccessfulPaste?()
            } catch is CancellationError { }
            catch { self?.onError?(error) }
            if self?.operation == token { self?.hide() }
        }
    }

    func hide(keepingActivationObserver: Bool = false) {
        panel?.orderOut(nil); target = nil
        state.revealedIDs = []
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
        if let deliveryInputMonitor { NSEvent.removeMonitor(deliveryInputMonitor) }; deliveryInputMonitor = nil
        if let deliveryLocalMonitor { NSEvent.removeMonitor(deliveryLocalMonitor) }; deliveryLocalMonitor = nil
        if !keepingActivationObserver { removeActivationObserver() }
    }

    private func removeActivationObserver() {
        if let workspaceObserver { activationNotifications.removeObserver(workspaceObserver) }; workspaceObserver = nil
    }

    func cancel() { hide(); operation = UUID(); delivery?.cancel(); delivery = nil }
    func stop() { configure(enabled: false) }
    func waitForDelivery() async { await delivery?.value }
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

@MainActor
final class ClipboardHistoryPanelState: ObservableObject {
    @Published var selectedIndex = 0
    @Published var revealedIDs: Set<UUID> = []
    @Published var query = "" { didSet { if query != oldValue { selectedIndex = 0 } } }
    func visibleEntries(in entries: [ClipboardHistoryEntry]) -> [ClipboardHistoryEntry] {
        guard !query.isEmpty else { return entries }
        return entries.filter { (!$0.isSensitive || revealedIDs.contains($0.id)) && $0.text.localizedStandardContains(query) }
    }
    func toggleReveal(_ id: UUID) {
        if revealedIDs.contains(id) { revealedIDs.remove(id) } else { revealedIDs.insert(id) }
    }
}
