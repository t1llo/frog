import AppKit
import Combine
import FrogCore

enum OrganizerItem: String, CaseIterable {
    case toggle, divider, permanentDivider
    var autosaveName: String { "Frog.MenuBarOrganizer.\(rawValue)" }
}

struct OrganizerScreen {
    var frame: CGRect
    /// The notch splits the visible strip; a toggle must fit entirely in one side.
    var menuRegions: [CGRect]
}

struct OrganizerEnvironment {
    var screens: [OrganizerScreen]
    var pointerInMenuBar = false
    var mouseDown = false
    var competingOrganizer = false
    var supportsLengthTechnique = true

    var collapsedLength: CGFloat {
        min(10_000, max(500, (screens.map(\.frame.width).max() ?? 2500) * 2))
    }

    static func live() -> Self {
        let pointer = NSEvent.mouseLocation
        let screens = NSScreen.screens.map { screen in
            let height = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
            let band = CGRect(x: screen.frame.minX, y: screen.frame.maxY - height,
                              width: screen.frame.width, height: height)
            let regions: [CGRect]
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                regions = [left, right]
            } else { regions = [band] }
            return OrganizerScreen(frame: screen.frame, menuRegions: regions)
        }
        return Self(screens: screens, pointerInMenuBar: screens.contains { screen in
            pointer.x >= screen.frame.minX && pointer.x <= screen.frame.maxX &&
            pointer.y >= screen.frame.maxY - max(NSStatusBar.system.thickness, screen.menuRegions.map(\.height).max() ?? 0) &&
            pointer.y <= screen.frame.maxY
        }, mouseDown: NSEvent.pressedMouseButtons != 0,
        competingOrganizer: NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.dwarvesv.minimalbar" },
        supportsLengthTechnique: ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27)
    }
}

/// The adapter observes and changes only Frog's helper items, never another app's items.
@MainActor protocol OrganizerStatusItems: AnyObject {
    func install(_ item: OrganizerItem, action: @escaping () -> Void, settings: @escaping () -> Void)
    func remove(_ item: OrganizerItem)
    func setLength(_ length: CGFloat, for item: OrganizerItem)
    func setExpanded(_ expanded: Bool)
    func frame(of item: OrganizerItem) -> CGRect?
    func updateMenu(_ state: OrganizerMenuState, action: @escaping (OrganizerMenuAction) -> Void)
}

extension OrganizerStatusItems {
    func updateMenu(_ state: OrganizerMenuState, action: @escaping (OrganizerMenuAction) -> Void) {}
}

enum OrganizerMenuAction { case toggle, arrange, autoHide, settings, tracking(Bool) }
struct OrganizerMenuState: Equatable {
    var expanded: Bool
    var arranging: Bool
    var autoHide: Bool
}

@MainActor protocol OrganizerHotkey: AnyObject {
    func register(_ hotkey: Hotkey, action: @escaping () -> Void) -> String?
    func unregister()
}

@MainActor final class MenuBarOrganizer: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isInstalled = false
    @Published private(set) var isExpanded = true
    @Published private(set) var isEditingArrangement = false
    @Published private(set) var issue: String?
    @Published private(set) var hotkeyError: String?
    var onShowSettings: (() -> Void)?
    var onSettingsChange: ((MenuBarPreferences) -> Void)?

    private let items: any OrganizerStatusItems
    private let hotkeys: any OrganizerHotkey
    private let environment: () -> OrganizerEnvironment
    private let now: () -> TimeInterval
    private let automaticTicks: Bool
    private var settings = MenuBarPreferences()
    private var installed = Set<OrganizerItem>()
    private var timer: Timer?
    private var deadline: TimeInterval?
    private var hoverStarted: TimeInterval?
    private var pendingInitialCollapse = false
    private var settingsVisible = false
    private var shortcutsSuspended = false
    private var registeredHotkey: Hotkey?
    private var appliedLengths: [OrganizerItem: CGFloat] = [:]
    private var menuTracking = false
    // AppKit updates width synchronously, but WindowServer moves the spacer later.
    // Do not interpret that intermediate rectangle as a user-reversed arrangement.
    private var layoutSettlesAt: TimeInterval = 0

    init(statusItems: (any OrganizerStatusItems)? = nil, hotkeys: (any OrganizerHotkey)? = nil,
         automaticTicks: Bool = true, environment: (() -> OrganizerEnvironment)? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.items = statusItems ?? NativeOrganizerStatusItems()
        self.hotkeys = hotkeys ?? NativeOrganizerHotkey()
        self.automaticTicks = automaticTicks
        self.environment = environment ?? { OrganizerEnvironment.live() }
        self.now = now
    }

    func configure(enabled: Bool, settings: MenuBarPreferences) {
        guard enabled else { stop(); return }
        let previous = self.settings
        self.settings = settings.normalized
        isEnabled = true
        let env = environment()
        guard checkAvailability(env) else { return }
        let starting = !isInstalled
        if starting {
            // New status items are inserted on the left, so create the recovery arrow first.
            install(.toggle); install(.divider)
            isInstalled = true
            pendingInitialCollapse = settings.startCollapsed
            if automaticTicks {
                let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                timer.tolerance = 0.1
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
        }
        if settings.permanentlyHiddenSection {
            install(.permanentDivider)
            if !starting && !previous.permanentlyHiddenSection { isEditingArrangement = true; isExpanded = true }
        } else {
            remove(.permanentDivider)
        }
        updateHotkey()
        // Install at normal widths first. The first tick validates macOS's restored order.
        if !env.mouseDown {
            if geometryAvailable, let problem = arrangementIssue(env) {
                if now() >= layoutSettlesAt {
                    isExpanded = true
                    issue = problem
                    applyLengths(env, allowPermanentCollapse: false)
                }
            } else {
                applyLengths(env, allowPermanentCollapse: !starting && geometryAvailable)
            }
        }
        if starting || previous != self.settings { resetDeadline() }
    }

    func stop() {
        tearDown()
        isEnabled = false
        issue = nil
    }

    func toggle() {
        guard isInstalled else { return }
        if isEditingArrangement {
            setEditingArrangement(false)
            guard !isEditingArrangement else { return }
        }
        if isExpanded { collapse() } else { reveal() }
    }

    func reveal() {
        guard isInstalled else { return }
        pendingInitialCollapse = false
        isExpanded = true
        applyLengths(environment())
        resetDeadline()
    }

    /// Window-accessible recovery also reveals the permanent section and pauses auto-hide.
    func setEditingArrangement(_ editing: Bool) {
        guard isInstalled else { return }
        pendingInitialCollapse = false
        isExpanded = true
        isEditingArrangement = editing
        if !editing, let problem = arrangementIssue(environment()) {
            isEditingArrangement = true
            issue = problem
        } else { issue = nil }
        applyLengths(environment())
        resetDeadline()
    }

    func setSettingsVisible(_ visible: Bool) {
        settingsVisible = visible
        if visible { pendingInitialCollapse = false }
        if !visible && isEditingArrangement { setEditingArrangement(false) }
        resetDeadline()
    }

    /// Parent calls alongside its other managers when any shortcut recorder is active.
    func setShortcutRecording(_ recording: Bool) {
        guard shortcutsSuspended != recording else { return }
        shortcutsSuspended = recording
        updateHotkey()
    }

    /// One bounded timer drives geometry, display changes, hover and the auto-hide deadline.
    /// Tests call this with an injected clock and status-item adapter; no real bar is changed.
    func tick() {
        guard isInstalled else { return }
        let env = environment()
        guard checkAvailability(env) else { return }
        // A dragged item temporarily crosses its neighbors or loses its window.
        // Resizing here fights macOS's placement gesture and causes visible jumping.
        if env.mouseDown { layoutSettlesAt = 0; resetDeadline(); return }
        guard !menuTracking else { resetDeadline(); return }
        // Auto-hidden menu bars and Space transitions may briefly supply no frames.
        // Preserve intent until we can distinguish that from genuinely unsafe order.
        guard geometryAvailable else { resetDeadline(); return }
        if let problem = arrangementIssue(env) {
            guard now() >= layoutSettlesAt else { return }
            isExpanded = true
            if settings.permanentlyHiddenSection { isEditingArrangement = true }
            issue = problem
            pendingInitialCollapse = false
            applyLengths(env, allowPermanentCollapse: false)
            resetDeadline()
            return
        }
        if issue != nil { issue = nil }
        applyLengths(env)
        if pendingInitialCollapse && !env.pointerInMenuBar && !env.mouseDown {
            pendingInitialCollapse = false
            if !settingsVisible && !isEditingArrangement { collapse() }
        }
        if !isExpanded && settings.hoverToReveal && env.pointerInMenuBar && !env.mouseDown {
            if let start = hoverStarted, now() - start >= 0.5 { reveal(); hoverStarted = nil }
            else if hoverStarted == nil { hoverStarted = now() }
        } else { hoverStarted = nil }
        guard isExpanded, settings.autoHide, !isEditingArrangement else { return }
        if env.pointerInMenuBar || env.mouseDown || settingsVisible { resetDeadline(); return }
        if let deadline, now() >= deadline { collapse() }
    }

    private func collapse() {
        let env = environment()
        guard isInstalled, !isEditingArrangement else { return }
        guard checkAvailability(env) else { return }
        guard !env.mouseDown, geometryAvailable else { return }
        if let problem = arrangementIssue(env) {
            if now() >= layoutSettlesAt { issue = problem }
            return
        }
        issue = nil
        isExpanded = false
        deadline = nil
        applyLengths(env)
    }

    private var geometryAvailable: Bool {
        installed.allSatisfy { role in
            guard let frame = items.frame(of: role) else { return false }
            return frame.width > 0 && frame.height > 0
        }
    }

    private func arrangementIssue(_ env: OrganizerEnvironment) -> String? {
        guard let arrow = items.frame(of: .toggle), let divider = items.frame(of: .divider),
              arrow.width > 0, divider.width > 0 else {
            return "Waiting for the menu bar. If Frog's arrow is missing, quit Hidden Bar, then reopen Frog from Applications."
        }
        guard env.screens.contains(where: { $0.menuRegions.contains(where: { $0.insetBy(dx: -1, dy: -2).contains(arrow) }) }) else {
            return "Frog's arrow is off-screen or behind the notch. Reveal all here, then Command-drag the arrow into the visible right side of the menu bar."
        }
        guard divider.maxX <= arrow.minX + 1, abs(divider.midY - arrow.midY) < 4 else {
            return "Command-drag Frog's divider to the LEFT of its arrow. Frog keeps everything revealed until the arrow is safely on the right."
        }
        if settings.permanentlyHiddenSection {
            guard let permanent = items.frame(of: .permanentDivider), permanent.width > 0,
                  permanent.maxX <= divider.minX + 1, abs(permanent.midY - divider.midY) < 4 else {
                return "Command-drag the double divider to the LEFT of the single divider, then finish arranging."
            }
        }
        return nil
    }

    private func checkAvailability(_ env: OrganizerEnvironment) -> Bool {
        let problem: String?
        if env.competingOrganizer {
            problem = "Hidden Bar is running. Quit it yourself before enabling Frog's organizer, then click Retry."
        } else if !env.supportsLengthTechnique {
            problem = "This macOS version does not support the public status-item spacing technique. Frog has left your menu bar revealed."
        } else { problem = nil }
        guard let problem else { return true }
        tearDown()
        issue = problem
        return false
    }

    private func install(_ item: OrganizerItem) {
        guard installed.insert(item).inserted else { return }
        items.install(item, action: { [weak self] in self?.toggle() }, settings: { [weak self] in self?.onShowSettings?() })
    }

    private func remove(_ item: OrganizerItem) {
        guard installed.remove(item) != nil else { return }
        items.remove(item)
        appliedLengths[item] = nil
    }

    private func applyLengths(_ env: OrganizerEnvironment, allowPermanentCollapse: Bool = true) {
        for item in installed {
            let length: CGFloat
            switch item {
            case .toggle: length = 24
            case .divider: length = isExpanded || isEditingArrangement ? 18 : env.collapsedLength
            case .permanentDivider: length = isEditingArrangement || !allowPermanentCollapse ? 18 : env.collapsedLength
            }
            if appliedLengths[item] != length {
                if appliedLengths[item] != nil { layoutSettlesAt = now() + 1 }
                items.setLength(length, for: item)
                appliedLengths[item] = length
            }
        }
        items.setExpanded(isExpanded)
        items.updateMenu(OrganizerMenuState(expanded: isExpanded, arranging: isEditingArrangement, autoHide: settings.autoHide)) { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggle: self.toggle()
            case .arrange: self.setEditingArrangement(!self.isEditingArrangement)
            case .autoHide:
                var value = self.settings; value.autoHide.toggle()
                self.onSettingsChange?(value)
            case .settings: self.onShowSettings?()
            case .tracking(let tracking): self.menuTracking = tracking; self.resetDeadline()
            }
        }
    }

    private func resetDeadline() {
        deadline = isExpanded && settings.autoHide ? now() + settings.autoHideSeconds : nil
    }

    private func updateHotkey() {
        let desired = isInstalled && !shortcutsSuspended ? settings.hotkey : nil
        guard desired != registeredHotkey || hotkeyError != nil else { return }
        hotkeys.unregister()
        registeredHotkey = nil
        hotkeyError = nil
        if let desired {
            hotkeyError = hotkeys.register(desired) { [weak self] in self?.toggle() }
            if hotkeyError == nil { registeredHotkey = desired }
        }
    }

    private func tearDown() {
        timer?.invalidate(); timer = nil
        hotkeys.unregister(); registeredHotkey = nil; hotkeyError = nil
        // Restore compact widths before removal, keeping any saved placement uninflated.
        for item in installed { items.setLength(item == .toggle ? 24 : 18, for: item) }
        for item in OrganizerItem.allCases.reversed() { remove(item) }
        isInstalled = false; isExpanded = true; isEditingArrangement = false
        deadline = nil; hoverStarted = nil; pendingInitialCollapse = false
        menuTracking = false
        layoutSettlesAt = 0
    }

    isolated deinit {
        timer?.invalidate()
        hotkeys.unregister()
        for item in OrganizerItem.allCases.reversed() where installed.contains(item) { items.remove(item) }
    }
}

@MainActor private final class NativeOrganizerHotkey: OrganizerHotkey {
    private let manager = HotkeyManager()
    private let id = UUID()
    func register(_ hotkey: Hotkey, action: @escaping () -> Void) -> String? {
        manager.register(rules: [Rule(id: id, name: "Menu bar", hotkey: hotkey)], onTrigger: { _ in action() })[id]
    }
    func unregister() { manager.unregister() }
}

@MainActor final class NativeOrganizerStatusItems: NSObject, OrganizerStatusItems, NSMenuDelegate {
    private var items: [OrganizerItem: NSStatusItem] = [:]
    private var toggle: (() -> Void)?
    private var settings: (() -> Void)?
    private var expanded: Bool?
    private(set) var contextMenu = NSMenu()
    private var menuState: OrganizerMenuState?
    private var menuAction: ((OrganizerMenuAction) -> Void)?

    func updateMenu(_ state: OrganizerMenuState, action: @escaping (OrganizerMenuAction) -> Void) {
        menuAction = action
        guard menuState != state else { return }
        menuState = state
        let menu = NSMenu(); menu.delegate = self
        for (title, selector) in [(state.expanded ? "Hide menu bar icons" : "Show hidden icons", #selector(toggleFromMenu)),
                                  (state.arranging ? "Done arranging" : "Show all & arrange…", #selector(arrangeFromMenu))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let autoHide = NSMenuItem(title: "Automatically hide icons", action: #selector(autoHideFromMenu), keyEquivalent: "")
        autoHide.target = self; autoHide.state = state.autoHide ? .on : .off; menu.addItem(autoHide)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Menu bar settings…", action: #selector(settingsFromMenu), keyEquivalent: "")
        settings.target = self; menu.addItem(settings)
        contextMenu = menu
    }

    func menuWillOpen(_ menu: NSMenu) { menuAction?(.tracking(true)) }
    func menuDidClose(_ menu: NSMenu) { menuAction?(.tracking(false)) }
    @objc private func toggleFromMenu() { menuAction?(.toggle) }
    @objc private func arrangeFromMenu() { menuAction?(.arrange) }
    @objc private func autoHideFromMenu() { menuAction?(.autoHide) }
    @objc private func settingsFromMenu() { settings?() }

    func install(_ role: OrganizerItem, action: @escaping () -> Void, settings: @escaping () -> Void) {
        guard items[role] == nil else { return }
        toggle = action; self.settings = settings
        let item = NSStatusBar.system.statusItem(withLength: role == .toggle ? 24 : 18)
        item.autosaveName = role.autosaveName
        item.behavior = [] // Helpers may be rearranged, but not accidentally Command-dragged off the bar.
        item.isVisible = true
        if let button = item.button {
            button.target = self
            button.action = role == .toggle ? #selector(clickedArrow) : #selector(clickedDivider)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            if role != .toggle {
                // NSStatusBarButton centers its image in a huge spacer. Anchor our marker
                // to the TRAILING edge instead, so the boundary remains next to the arrow.
                _ = OrganizerDividerView(button: button, isDouble: role == .permanentDivider)
            }
            let title = role == .toggle ? "Reveal or collapse menu bar items" : role == .divider ? "Frog hidden section divider" : "Frog permanently hidden section divider"
            button.toolTip = title + ". Hold Command and drag to arrange."
            button.setAccessibilityLabel(title)
        }
        items[role] = item
        setExpanded(true)
    }

    func remove(_ role: OrganizerItem) {
        guard let item = items.removeValue(forKey: role) else { return }
        // Keep the identity through removal. Detaching autosaveName first can leave
        // the old remote status-item slot orphaned in macOS Control Center.
        // Installation explicitly restores isVisible without changing saved order.
        NSStatusBar.system.removeStatusItem(item)
        if role == .toggle { expanded = nil }
        if items.isEmpty { toggle = nil; settings = nil; menuAction = nil; menuState = nil; contextMenu = NSMenu() }
    }
    func setLength(_ length: CGFloat, for role: OrganizerItem) { items[role]?.length = length }
    func frame(of role: OrganizerItem) -> CGRect? { items[role]?.button?.window?.frame }
    func setExpanded(_ expanded: Bool) {
        guard self.expanded != expanded, let button = items[.toggle]?.button else { return }
        self.expanded = expanded
        button.image = Self.arrowImage(expanded: expanded)
        button.setAccessibilityValue(expanded ? "Expanded" : "Collapsed")
        button.toolTip = (expanded ? "Hide menu bar icons" : "Show hidden icons") + ". Right-click for options; Option-click to arrange all icons."
    }
    static func arrowImage(expanded: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 18), flipped: false) { _ in
            let path = NSBezierPath(); path.lineWidth = 1.5; path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: NSPoint(x: expanded ? 4 : 8, y: 5))
            path.line(to: NSPoint(x: expanded ? 8 : 4, y: 9))
            path.line(to: NSPoint(x: expanded ? 4 : 8, y: 13))
            NSColor.black.setStroke(); path.stroke(); return true
        }
        image.isTemplate = true
        image.accessibilityDescription = expanded ? "Hide menu bar icons" : "Show hidden icons"
        return image
    }
    private func showMenu(from role: OrganizerItem) {
        guard let button = items[role]?.button else { return }
        // Anchor to the visible trailing marker, including when its spacer is inflated.
        contextMenu.popUp(positioning: nil, at: NSPoint(x: button.bounds.maxX - 18, y: button.bounds.minY), in: button)
    }
    @objc private func clickedArrow() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(from: .toggle) }
        else if NSApp.currentEvent?.modifierFlags.contains(.option) == true { menuAction?(.arrange) }
        else { toggle?() }
    }
    @objc private func clickedDivider(_ sender: NSStatusBarButton) {
        let role = items.first { $0.value.button === sender }?.key ?? .divider
        showMenu(from: role)
    }
}

@MainActor final class OrganizerDividerView: NSView {
    private let isDouble: Bool
    init(button: NSButton, isDouble: Bool) {
        self.isDouble = isDouble
        super.init(frame: NSRect(x: button.bounds.width - 18, y: 0, width: 18, height: button.bounds.height))
        autoresizingMask = [.minXMargin, .height]
        button.addSubview(self)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.8).setFill()
        for x: CGFloat in isDouble ? [7, 11] : [9] {
            NSBezierPath(roundedRect: NSRect(x: x, y: (bounds.height - 14) / 2, width: 1, height: 14), xRadius: 0.5, yRadius: 0.5).fill()
        }
    }
}
