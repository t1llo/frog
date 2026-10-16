import AppKit
import SwiftUI
import FrogCore

/// What the answer panel shows and the actions its controls run.
@MainActor final class AnswerPanelModel: ObservableObject {
    @Published var session: AnswerSession?
    @Published var recovery: AnswerController.Recovery?
    @Published var followUpMessage: String?
    /// Save to note shows while notes are on; it saves once there is an answer.
    @Published var offersNotes = false
    @Published var canSaveNote = false
    @Published var noteState: AnswerController.NoteState?
    @Published var pinned = false
    /// Shows "Copied" in place of Copy for a moment after the answer was copied.
    @Published var copied = false
    @Published var question = ""
    /// The tallest the panel grows before its answer scrolls.
    @Published var maxHeight: CGFloat = 560
    var ask: (String) -> Void = { _ in }
    var stop: () -> Void = {}
    var retry: () -> Void = {}
    var copy: () -> Void = {}
    var editRule: () -> Void = {}
    var allowAccessibility: () -> Void = {}
    var saveNote: () -> Void = {}
    var close: () -> Void = {}
    var togglePin: () -> Void = {}
    /// The height the content asks for, header and footer included.
    var heightChanged: (CGFloat) -> Void = { _ in }
}

/// The answer panel next to the selection. It never activates Frog, so the other app keeps its
/// focused field. While it is open it watches Escape (key code only), clicks and app switches to
/// close itself; a pinned panel stays until it is closed directly.
@MainActor final class AnswerPanelController: AnswerPresenting {
    static let width: CGFloat = 400
    weak var controller: AnswerController?
    let model = AnswerPanelModel()
    private var panel: FrogFloatingPanel?
    private var placement: PanelPlacement.Result?
    private var desiredHeight: CGFloat = 200
    private var sourcePID: pid_t?
    private var openedAt: TimeInterval = 0
    private var localMonitor: Any?
    private var globalKeyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var copiedReset: Task<Void, Never>?

    init() {
        model.ask = { [weak self] question in
            guard let self, let controller = self.controller else { return }
            if controller.ask(question) == nil { self.model.question = "" }
        }
        model.stop = { [weak self] in self?.controller?.stop() }
        model.retry = { [weak self] in self?.controller?.retry() }
        model.copy = { [weak self] in self?.copyLatest() }
        model.editRule = { [weak self] in self?.controller?.editRule() }
        model.allowAccessibility = { [weak self] in self?.controller?.allowAccessibility() }
        model.saveNote = { [weak self] in self?.controller?.saveToNote() }
        model.close = { [weak self] in self?.dismiss(.closeButton) }
        model.togglePin = { [weak self] in self?.model.pinned.toggle() }
        model.heightChanged = { [weak self] in self?.resize(to: $0) }
    }

    var isKey: Bool { panel?.isKeyWindow == true }
    var isPinned: Bool { model.pinned }

    func show(_ session: AnswerSession, anchor: CGRect?, pointer: CGPoint) {
        let panel = makePanel()
        sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        openedAt = ProcessInfo.processInfo.systemUptime
        model.question = ""
        copiedReset?.cancel(); copiedReset = nil
        model.copied = false
        apply(session)
        installMonitors()
        if panel.isVisible, model.pinned { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let screens = panel.screensForPlacement()
        var result = PanelPlacement.place(size: CGSize(width: Self.width, height: desiredHeight), anchor: anchor, pointer: pointer, screens: screens)
        model.maxHeight = Self.maxHeight(on: result.screen)
        if desiredHeight > model.maxHeight {
            result = PanelPlacement.place(size: CGSize(width: Self.width, height: model.maxHeight), anchor: anchor, pointer: pointer, screens: screens)
        }
        placement = result
        panel.show(at: result.frame)
    }

    func update(_ session: AnswerSession) {
        let finished = model.session?.phase.isDone == false && session.phase.isDone && model.session?.id == session.id
        apply(session)
        if finished, let panel {
            NSAccessibility.post(element: panel, notification: .announcementRequested,
                                 userInfo: [.announcement: L10n.text("Answer ready"), .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    func close() {
        removeMonitors()
        panel?.orderOut(nil)
        placement = nil
        model.session = nil
        model.recovery = nil
        model.followUpMessage = nil
        model.noteState = nil
        model.question = ""
        model.pinned = false
        copiedReset?.cancel(); copiedReset = nil
        model.copied = false
    }

    /// The button and ⌘↩ both confirm the copy, since nothing else on screen changes.
    private func copyLatest() {
        guard controller?.copyLatest() == true else { return }
        model.copied = true
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.model.copied = false
        }
    }

    // MARK: Layout

    /// At most 560 points, and at most 60 % of the display's visible height.
    static func maxHeight(on screen: CGRect) -> CGFloat {
        guard screen.height > 0 else { return 560 }
        return min(560, (screen.height * 0.6).rounded(.down))
    }

    private static func moved(_ frame: CGRect, from placed: CGRect) -> Bool {
        abs(frame.minX - placed.minX) > 0.5 || abs(frame.minY - placed.minY) > 0.5
    }

    private func makePanel() -> FrogFloatingPanel {
        if let panel { return panel }
        let panel = FrogFloatingPanel(size: CGSize(width: Self.width, height: 200), allowsKey: true, movable: true)
        panel.title = L10n.text("Explain answer")
        let hosting = FirstMouseHostingView(rootView: AnswerPanelView(model: model))
        // The panel sets its own height, keeping the edge next to the selection in place.
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func apply(_ session: AnswerSession) {
        model.session = session
        model.recovery = controller?.recovery
        model.followUpMessage = controller?.followUpMessage
        model.offersNotes = controller?.offersNotes ?? false
        model.canSaveNote = controller?.canSaveNote ?? false
        model.noteState = controller?.noteState
    }

    /// Below the selection the panel keeps its top edge, above it its bottom edge. One the user
    /// dragged, or pinned, grows from where it is, keeping its top edge.
    private func resize(to height: CGFloat) {
        desiredHeight = height.rounded(.up)
        guard let panel, panel.isVisible, var current = placement else { return }
        let target = min(desiredHeight, model.maxHeight)
        if model.pinned || Self.moved(panel.frame, from: current.frame) {
            current = PanelPlacement.Result(frame: panel.frame, above: false, screen: current.screen)
        }
        guard abs(target - current.frame.height) >= 1 else { return }
        let resized = PanelPlacement.resized(current, height: target)
        placement = resized
        panel.setFrame(resized.frame, display: true)
    }

    // MARK: Closing

    private func dismiss(_ event: PanelEvent) {
        // While a note saves, the folder chooser may be open: the panel stays as if pinned.
        let pinned = model.pinned || model.noteState == .saving
        guard panel?.isVisible == true, AnswerPanelDismissal.shouldClose(event, pinned: pinned) else { return }
        if let controller { controller.close() } else { close() }
    }

    private func installMonitors() {
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated { self?.handleLocalKey(event) ?? event }
            }
        }
        if globalKeyMonitor == nil {
            // Escape typed in another app. Only the key code is read, never the characters.
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return }
                let timestamp = event.timestamp
                MainActor.assumeIsolated {
                    guard let self, timestamp > self.openedAt else { return }
                    self.dismiss(.escapeElsewhere)
                }
            }
        }
        if globalMouseMonitor == nil {
            // A global monitor sees only events for other apps, so every click it sees is outside the panel.
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                let timestamp = event.timestamp
                MainActor.assumeIsolated {
                    guard let self, timestamp > self.openedAt else { return }
                    self.dismiss(.clickOutside)
                }
            }
        }
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                                   object: nil, queue: .main) { [weak self] notification in
                let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.dismiss(.appActivated(isSource: pid != nil && pid == self.sourcePID))
                }
            }
        }
    }

    private func removeMonitors() {
        for monitor in [localMonitor, globalKeyMonitor, globalMouseMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        localMonitor = nil; globalKeyMonitor = nil; globalMouseMonitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    /// Escape and ⌘W close, ⌘↩ copies, ⌘. stops, ⌘S saves a note while notes are on. Every other key
    /// goes on to the follow-up field.
    private func handleLocalKey(_ event: NSEvent) -> NSEvent? {
        guard let panel, event.window === panel else { return event }
        let composing = (panel.firstResponder as? NSTextView)?.hasMarkedText() == true
        if !composing, event.keyCode == 47, event.panelModifiers == .command {
            controller?.stop()
            return nil
        }
        if !composing, event.keyCode == 1, event.panelModifiers == .command, controller?.offersNotes == true {
            controller?.saveToNote()
            return nil
        }
        switch PanelKeyMap.decide(keyCode: event.keyCode, modifiers: event.panelModifiers, state: PanelState(composing: composing)) {
        case .close:
            dismiss(event.keyCode == 53 ? .escapeInPanel : .closeButton)
            return nil
        case .runSecondary:
            copyLatest()
            return nil
        default:
            return event
        }
    }
}

/// Shows nothing. Tests and a model without shortcuts never open a window.
@MainActor final class SilentAnswerPresenter: AnswerPresenting {
    func show(_ session: AnswerSession, anchor: CGRect?, pointer: CGPoint) {}
    func update(_ session: AnswerSession) {}
    func close() {}
    var isKey: Bool { false }
    var isPinned: Bool { false }
}

extension AnswerSession.Phase {
    var isDone: Bool { if case .done = self { true } else { false } }
    /// Waiting for the model's first text.
    var isPending: Bool {
        switch self {
        case .loading, .waiting, .thinking: true
        case .streaming, .done, .stopped, .failed: false
        }
    }
    var isRunning: Bool { isPending || self == .streaming }
}
