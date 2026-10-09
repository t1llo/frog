import AppKit
import ApplicationServices
import SwiftUI
import Combine
import FrogCore

@MainActor
protocol ClipboardHistoryPasteTarget {
    func paste() throws
}

/// The panel never activates Frog; insertion requires the original app/window/field.
@MainActor
struct NativeClipboardHistoryPasteTarget: ClipboardHistoryPasteTarget {
    let application: AXUIElement
    let window: AXUIElement
    let focused: AXUIElement
    let range: CFRange
    let pid: pid_t

    static func capture() -> Self? {
        guard SelectionService.isTrusted, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.15)
        guard let window = AXRead.element(application, kAXFocusedWindowAttribute),
              let focused = AXRead.element(application, kAXFocusedUIElementAttribute),
              let range = AXRead.range(focused),
              range.location >= 0, range.length >= 0,
              AXRead.string(focused, kAXRoleAttribute) != "AXWebArea",
              AXRead.string(focused, kAXSubroleAttribute) != kAXSecureTextFieldSubrole else { return nil }
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(AXRead.string(focused, kAXRoleAttribute) ?? "") || ClipboardSelection.isEditable(focused) else { return nil }
        return Self(application: application, window: window, focused: focused,
                    range: range, pid: app.processIdentifier)
    }

    func paste() throws {
        guard SelectionService.isTrusted, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let currentWindow = AXRead.element(application, kAXFocusedWindowAttribute), CFEqual(window, currentWindow) else {
            throw FrogError.message("The target app changed. The item is copied; paste it where you want it.")
        }
        guard let current = AXRead.element(application, kAXFocusedUIElementAttribute), CFEqual(focused, current),
              AXRead.string(current, kAXSubroleAttribute) != kAXSecureTextFieldSubrole else {
            throw FrogError.message("The target field changed. The item is copied; paste it where you want it.")
        }
        guard let currentRange = AXRead.range(focused), currentRange.location == range.location, currentRange.length == range.length else {
            throw FrogError.message("The insertion point changed. The item is copied; paste it where you want it.")
        }
        guard ClipboardSelection.isEditable(focused) || ClipboardSelection.menuCommand("v", application: application) != nil else {
            throw FrogError.message("The app does not expose an editable field. The item is copied; paste it manually.")
        }
        try ClipboardSelection.command("v", keyCode: 9, application: application, pid: pid)
    }
}

@MainActor
enum ClipboardHistoryDelivery {
    static func paste(_ entry: ClipboardHistoryEntry, plainText: Bool, pasteboard: NSPasteboard,
                      target: (any ClipboardHistoryPasteTarget)?, isCurrent: () -> Bool,
                      waitForRelease: () async throws -> Void = { try await ClipboardSelection.waitForShortcutRelease() }) async throws {
        try await waitForRelease()
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        guard entry.write(to: pasteboard, plainText: plainText) else { throw FrogError.message("Could not copy the clipboard item.") }
        guard let target else { throw FrogError.message("The item is copied. Focus an editable field and paste, or allow Accessibility for automatic paste.") }
        try target.paste()
    }
}

@MainActor
final class ClipboardHistoryController {
    let history: ClipboardHistoryStore
    var onError: ((Error) -> Void)?
    private var panel: ClipboardPanel?
    let state = ClipboardHistoryPanelState()
    private var target: (any ClipboardHistoryPasteTarget)?
    private var localMonitor: Any?
    private var globalMonitor: Any?
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
            self.state.revealedIDs.formIntersection(entries.map(\.id))
            let visible = self.state.visibleEntries(in: entries)
            self.state.selectedIndex = max(0, min(self.state.selectedIndex, visible.count - 1))
            self.resizePanel(entryCount: visible.count)
        }
    }

    func configure(enabled: Bool) {
        if !enabled { hide(); delivery?.cancel(); delivery = nil; operation = UUID() }
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
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                if event.type != .keyDown {
                    if event.window !== self.panel { self.hide() }
                    return event
                }
                guard event.window === self.panel else { return event }
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
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        workspaceObserver = activationNotifications.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } }
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
        let token = UUID(); operation = token; delivery?.cancel()
        delivery = Task { [weak self] in
            do {
                guard let self else { return }
                try await ClipboardHistoryDelivery.paste(entry, plainText: plainText, pasteboard: self.pasteboard,
                    target: target, isCurrent: { [weak self] in
                        self?.operation == token && self?.history.enabled == true && self?.history.retentionGeneration == retention &&
                        self?.history.entries.contains(where: { $0.id == entry.id }) == true
                    },
                    waitForRelease: self.waitForRelease)
            } catch is CancellationError { }
            catch { self?.onError?(error) }
            if self?.operation == token { self?.removeActivationObserver() }
        }
    }

    func hide(keepingActivationObserver: Bool = false) {
        panel?.orderOut(nil); panel?.contentView = nil; panel = nil; target = nil
        state.revealedIDs = []
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
        if !keepingActivationObserver { removeActivationObserver() }
    }

    private func removeActivationObserver() {
        if let workspaceObserver { activationNotifications.removeObserver(workspaceObserver) }; workspaceObserver = nil
    }

    func cancel() { hide(); operation = UUID(); delivery?.cancel(); delivery = nil }
    func stop() { configure(enabled: false) }
    func waitForDelivery() async { await delivery?.value }
    isolated deinit {
        delivery?.cancel()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
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
