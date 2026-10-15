import AppKit
import FrogCore

/// Owns what Windows runs: its commands and the panels they show. It creates nothing while it is
/// inactive or Windows is off, so a switched-off feature costs nothing.
@MainActor
final class WindowLayoutController: ObservableObject {
    static let noTarget = "There is no window to arrange. Click a window first."

    let manager: WindowManager
    let access: WindowAccess
    let displays: @MainActor () -> [WindowDisplay]
    let readMacOS: () -> MacWindowManagerSettings
    var onError: ((Error) -> Void)?
    /// Window moves count as `.windowCommand`.
    var onToolUse: ((ActivityToolKind) -> Void)?

    private(set) var configuration = Configuration()
    private(set) var active = false
    private var cheatSheet: WindowCheatSheetPanel?
    private var picker: LayoutPickerPanel?
    private var preview: WindowPreviewPanel?
    private var zoneOverlay: SnapZoneOverlay?
    private let tracker = WindowTargetTracker()
    /// The app whose window the open picker arranges.
    private var pickerTarget: pid_t?
    private var previewTask: Task<Void, Never>?
    private var moveTask: Task<Void, Never>?
    /// Watches window drags while drag to snap or the zone overlay is on; nil otherwise, so no
    /// event monitor exists.
    private var dragMonitor: WindowDragMonitor?

    init(manager: WindowManager, access: WindowAccess = AXWindowAccess(),
         displays: @escaping @MainActor () -> [WindowDisplay] = WindowDisplays.current,
         readMacOS: @escaping () -> MacWindowManagerSettings = MacWindowManagerReader.read) {
        self.manager = manager
        self.access = access
        self.displays = displays
        self.readMacOS = readMacOS
    }

    /// Windows is on and the app registers shortcuts.
    var running: Bool { active && WindowSwitches(configuration.preferences).feature }

    /// The layout picker can be opened: from its shortcut, the Frog menu or the command bar.
    var pickerAvailable: Bool { running && WindowSwitches(configuration.preferences).commandEnabled(.layoutPicker) }

    var pickerVisible: Bool { picker?.isVisible == true }

    /// App activation is watched only while the picker can open.
    var trackingTarget: Bool { tracker.running }

    /// Windows dragged to a screen edge or corner snap: the controller runs and drag to snap is on.
    var dragToSnapActive: Bool { running && WindowSwitches(configuration.preferences).dragToSnap }

    /// Holding Shift during a window drag shows zones: the controller runs and the overlay is on.
    var zoneOverlayActive: Bool { running && WindowSwitches(configuration.preferences).zoneOverlay }

    /// Mouse events are watched for window drags.
    var watchingDrags: Bool { dragMonitor?.running == true }

    /// Shift and Option are watched during window drags, for the zone overlay.
    var watchingModifiers: Bool { dragMonitor?.watchesModifiers == true }

    func configure(_ configuration: Configuration, active: Bool) {
        let previous = WindowSwitches(self.configuration.preferences).shortcutRules
        self.configuration = configuration
        self.active = active
        guard running else { stop(); return }
        // Registering the shortcuts again forgets one that is held, so its release never comes.
        if WindowSwitches(configuration.preferences).shortcutRules != previous { cheatSheet?.hide() }
        if pickerAvailable { tracker.start() } else { hidePicker(); tracker.stop() }
        if dragToSnapActive || zoneOverlayActive { startDragMonitor(modifiers: zoneOverlayActive) } else { stopDragMonitor() }
    }

    func handle(_ command: WindowCommand, pressed: Bool) {
        guard running, WindowSwitches(configuration.preferences).commandEnabled(command) else { return }
        switch command {
        case .cheatSheet: if pressed { showCheatSheet() } else { cheatSheet?.hide() }
        case .layoutPicker: if pressed { togglePicker() }
        }
    }

    /// Hides every panel and ends what runs. Synchronous: it is called while Frog quits and while a
    /// feature is switched off, and neither waits.
    func stop() {
        cheatSheet?.hide()
        hidePicker()
        tracker.stop()
        stopDragMonitor()
    }

    /// Moves the focused window of `pid` the way a layout shortcut does, with the same gaps and
    /// history, so Restore works afterwards. A half is not cycled: only a shortcut pressed again
    /// cycles.
    @discardableResult
    func perform(_ action: WindowAction, pid: pid_t) -> Task<Void, Never> {
        var options = WindowSwitches(configuration.preferences).layoutOptions(readMacOS())
        options.cycleSizes = false
        let displays = displays()
        moveTask?.cancel()
        let task = Task { [weak self, manager] in
            do {
                try await manager.perform(action, pid: pid, displays: displays, options: options)
                try Task.checkCancellation()
                self?.onToolUse?(.windowCommand)
                // Chosen from the Frog menu, Frog is in front: give the moved window back its focus.
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                    NSRunningApplication(processIdentifier: pid)?.activate()
                }
            }
            catch is CancellationError { }
            catch { self?.onError?(error) }
        }
        moveTask = task
        return task
    }

    // MARK: Drag to snap

    private func startDragMonitor(modifiers: Bool) {
        if let dragMonitor, dragMonitor.watchesModifiers == modifiers { return }
        stopDragMonitor()
        let manager = manager, access = access
        let own = ProcessInfo.processInfo.processIdentifier
        let tracker = WindowDragTracker(
            probe: { await WindowDragMonitor.windowUnder($0) },
            frame: { await WindowDragMonitor.readFrame($0, access: access) },
            apply: { [weak self] action, window, display in await self?.snap(action, window: window, display: display) },
            setFrame: { frame, window in await Task.detached { try? access.setFrame(frame, of: window, resize: true) }.value },
            preview: { [weak self] frame in self?.showDragPreview(frame) },
            displays: { [weak self] in self?.displays() ?? [] },
            options: { [weak self] in self?.snapOptions() ?? .legacy },
            macOS: { [weak self] in self?.readMacOS() ?? MacWindowManagerSettings() },
            lastMove: { key in await manager.lastMove(of: key).map { ($0.move.applied, $0.frame.size) } },
            shouldIgnore: { $0.key.pid == own },
            restoreOnDrag: { [weak self] in self.map { WindowSwitches($0.configuration.preferences).restoreOnDrag } ?? false },
            dragToSnap: { [weak self] in self?.dragToSnapActive ?? false },
            zoneGrid: { [weak self] in self.flatMap { $0.zoneOverlayActive ? WindowSwitches($0.configuration.preferences).zoneGrid : nil } },
            modifiers: { WindowDragMonitor.liveModifiers() },
            showZones: { [weak self] layout in self?.showZones(layout) })
        let monitor = WindowDragMonitor(tracker: tracker, watchesModifiers: modifiers)
        monitor.start()
        dragMonitor = monitor
    }

    private func stopDragMonitor() {
        dragMonitor?.stop()
        dragMonitor = nil
        zoneOverlay?.hide()
    }

    /// Layouts from a drag use the same gaps and Stage Manager room as shortcuts, without cycling.
    private func snapOptions() -> WindowLayoutOptions {
        var options = WindowSwitches(configuration.preferences).layoutOptions(readMacOS())
        options.cycleSizes = false
        return options
    }

    /// Moves the dragged window on the display under the pointer, recorded for Restore.
    private func snap(_ action: WindowAction, window: WindowHandle, display: WindowDisplay) async {
        do {
            try await manager.apply(action, to: window, displays: [display], options: snapOptions())
            onToolUse?(.windowCommand)
        }
        catch is CancellationError { }
        catch { onError?(error) }
    }

    private func showZones(_ layout: SnapZoneLayout?) {
        guard let layout else { zoneOverlay?.hide(); return }
        let overlay = zoneOverlay ?? SnapZoneOverlay()
        zoneOverlay = overlay
        overlay.show(layout)
    }

    private func showDragPreview(_ frame: CGRect?) {
        guard let frame else { preview?.hide(); return }
        let preview = self.preview ?? WindowPreviewPanel()
        self.preview = preview
        preview.show(accessibilityFrame: frame)
    }

    // MARK: Layout picker

    private func togglePicker() {
        if pickerVisible { hidePicker(); return }
        let target = tracker.target
        pickerTarget = target
        let panel = picker ?? makePicker()
        let name = target.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        let display = target.flatMap { windowDisplay(pid: $0) }
        panel.show(appName: name, status: target == nil ? Self.noTarget : nil, hotkeys: layoutHotkeys(), target: target, display: display)
    }

    private func hidePicker() {
        previewTask?.cancel(); previewTask = nil
        picker?.hide()
        preview?.hide()
        pickerTarget = nil
    }

    private func makePicker() -> LayoutPickerPanel {
        let panel = LayoutPickerPanel()
        panel.onSelect = { [weak self] in self?.showPreview($0) }
        panel.onApply = { [weak self] in self?.applyPicker($0) }
        panel.onClose = { [weak self] in self?.hidePicker() }
        picker = panel
        return panel
    }

    private func applyPicker(_ action: WindowAction) {
        guard let pid = pickerTarget else { picker?.status = Self.noTarget; return }
        hidePicker()
        perform(action, pid: pid)
    }

    /// Shows where the selected layout puts the target window, or nothing.
    private func showPreview(_ action: WindowAction?) {
        previewTask?.cancel()
        guard let action, let pid = pickerTarget else { preview?.hide(); return }
        var options = WindowSwitches(configuration.preferences).layoutOptions(readMacOS())
        options.cycleSizes = false
        let displays = displays()
        previewTask = Task { [weak self, manager] in
            let frame = await manager.preview(action, pid: pid, displays: displays, options: options)
            guard let self, !Task.isCancelled, self.pickerVisible else { return }
            guard let frame else { self.preview?.hide(); return }
            let preview = self.preview ?? WindowPreviewPanel()
            self.preview = preview
            preview.show(accessibilityFrame: frame, below: self.picker?.window)
        }
    }

    /// The visible frame, in Cocoa coordinates, of the display that holds most of the target's
    /// focused window. One short Accessibility read.
    private func windowDisplay(pid: pid_t) -> CGRect? {
        guard let window = access.focusedWindow(pid: pid), let frame = access.frame(of: window) else { return nil }
        let screens = NSScreen.screens
        let primaryTop = screens.first?.frame.maxY ?? 0
        let cocoa = WindowPreviewPanel.cocoaRect(frame, primaryTop: primaryTop)
        guard let index = WindowGeometry.displayIndex(for: cocoa, displays: screens.map(\.frame)) else { return nil }
        return screens[index].visibleFrame
    }

    /// The shortcuts of the layouts, from the enabled rules that run.
    private func layoutHotkeys() -> [WindowAction: Hotkey] {
        var hotkeys: [WindowAction: Hotkey] = [:]
        for rule in configuration.rules where rule.enabled && rule.category == .window && configuration.preferences.ruleFeatureEnabled(rule) {
            if let action = rule.action?.windowAction, let key = rule.hotkey, hotkeys[action] == nil { hotkeys[action] = key }
        }
        return hotkeys
    }

    private func showCheatSheet() {
        let switches = WindowSwitches(configuration.preferences)
        let commands = switches.shortcutRules.compactMap { rule in
            WindowCommand.command(for: rule.id).flatMap { command in rule.hotkey.map { (command, $0) } }
        }
        let rules = configuration.rules.filter { configuration.preferences.ruleFeatureEnabled($0) }
        let panel = cheatSheet ?? WindowCheatSheetPanel()
        cheatSheet = panel
        panel.show(sections: WindowCheatSheet.sections(rules: rules, commands: commands))
    }
}
