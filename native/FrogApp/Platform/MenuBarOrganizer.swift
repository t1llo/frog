import AppKit
import Combine
import FrogCore

enum OrganizerItem: String, CaseIterable {
    case toggle, divider, permanentDivider
    var autosaveName: String { "Frog.MenuBarOrganizer.\(rawValue)" }

    /// Width while revealed. Where the system pads every status item itself,
    /// the helper gives that much back so it takes no more room than before.
    func revealedLength(padding: CGFloat) -> CGFloat {
        self == .toggle ? max(12, 24 - padding) : max(8, 18 - padding)
    }
}

struct OrganizerScreen {
    var frame: CGRect
    /// The notch splits the visible strip; a toggle must fit entirely in one side.
    var menuRegions: [CGRect]
}

extension OrganizerScreen {
    /// The bar is as tall as the space the screen reserves for it: 30 points on an
    /// external display in macOS 26, more than the status-bar thickness.
    init(frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat, thickness: CGFloat, notchSides: (CGRect, CGRect)?) {
        let height = max(thickness, safeAreaTop, frame.maxY - visibleFrame.maxY)
        let band = CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
        self.init(frame: frame, menuRegions: notchSides.map { [$0.0, $0.1] } ?? [band])
    }

    func menuBarContains(_ point: CGPoint, thickness: CGFloat) -> Bool {
        point.x >= frame.minX && point.x <= frame.maxX && point.y <= frame.maxY &&
            point.y >= frame.maxY - max(thickness, menuRegions.map(\.height).max() ?? 0)
    }
}

struct OrganizerEnvironment {
    var screens: [OrganizerScreen]
    var pointerInMenuBar = false
    var mouseDown = false
    var competingOrganizer = false
    var supportsLengthTechnique = true
    /// What the system adds around each status item's own length.
    var statusItemPadding: CGFloat = 0

    /// macOS 26 surrounds every status item with 8 points on each side.
    static let systemStatusItemPadding: CGFloat = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? 16 : 0

    var collapsedLength: CGFloat {
        min(10_000, max(500, (screens.map(\.frame.width).max() ?? 2500) * 2))
    }

    static func live() -> Self {
        let pointer = NSEvent.mouseLocation
        let thickness = NSStatusBar.system.thickness
        let screens = NSScreen.screens.map { screen in
            var notchSides: (CGRect, CGRect)?
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea { notchSides = (left, right) }
            return OrganizerScreen(frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top,
                                   thickness: thickness, notchSides: notchSides)
        }
        return Self(screens: screens, pointerInMenuBar: screens.contains { $0.menuBarContains(pointer, thickness: thickness) },
        mouseDown: NSEvent.pressedMouseButtons != 0,
        competingOrganizer: NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.dwarvesv.minimalbar" },
        supportsLengthTechnique: ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27,
        statusItemPadding: systemStatusItemPadding)
    }
}

/// The adapter observes and changes only Frog's helper items, never another app's items.
@MainActor protocol OrganizerStatusItems: AnyObject {
    /// Handed over once. The arrow and the helpers' menu report through it what was chosen.
    func setMenuAction(_ action: @escaping (OrganizerMenuAction) -> Void)
    func install(_ item: OrganizerItem)
    func remove(_ item: OrganizerItem)
    func setLength(_ length: CGFloat, for item: OrganizerItem)
    func setExpanded(_ expanded: Bool)
    func frame(of item: OrganizerItem) -> CGRect?
    func updateMenu(_ state: OrganizerMenuState)
}

enum OrganizerMenuAction { case toggle, arrange, autoHide, settings, tracking(Bool) }
struct OrganizerMenuState: Equatable {
    var expanded: Bool
    var arranging: Bool
    var autoHide: Bool
    /// Why the icons stay shown, while an arrangement problem lasts.
    var issue: String?
}

/// Hidden Bar is an agent app, and the workspace announces neither the launch nor the
/// exit of one. The list of running applications is the only place that shows it leave.
@MainActor protocol OrganizerApplications: AnyObject {
    func watch(_ changed: @escaping () -> Void)
    func stopWatching()
}

@MainActor final class MenuBarOrganizer: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isInstalled = false
    @Published private(set) var isExpanded = true
    @Published private(set) var isEditingArrangement = false
    @Published private(set) var issue: String?
    var onShowSettings: (() -> Void)?
    var onSettingsChange: ((MenuBarPreferences) -> Void)?
    /// What Frog's own menu says while the organizer is switched on but has taken its arrow away.
    /// With the arrow gone, nothing else in the menu bar tells why every icon is shown again.
    var menuNotice: String? { isEnabled && !isInstalled ? issue : nil }
    /// How often the timer looks at the bar right now; nil while no timer runs.
    var scheduledTickInterval: TimeInterval? { timer?.timeInterval }

    private let items: any OrganizerStatusItems
    private let applications: any OrganizerApplications
    private let environment: () -> OrganizerEnvironment
    private let now: () -> TimeInterval
    private let automaticTicks: Bool
    private var settings = MenuBarPreferences()
    private var installed = Set<OrganizerItem>()
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var deadline: TimeInterval?
    private var hoverStarted: TimeInterval?
    // A hide that waits for a tick that can judge the bar: at start when the icons are to
    // start hidden, and when the arrow or the shortcut asked while the bar gave no frames.
    private var pendingCollapse = false
    // Only the hide at start yields to an open settings page; one that was asked for does not.
    private var pendingCollapseAsked = false
    private var settingsVisible = false
    private var appliedLengths: [OrganizerItem: CGFloat] = [:]
    /// From the last layout, for a release that can no longer ask the environment.
    private var statusItemPadding = OrganizerEnvironment.systemStatusItemPadding
    private var menuTracking = false
    private var awaitingCompetitorQuit = false
    // AppKit updates width synchronously, but WindowServer moves the spacer later.
    // Do not interpret that intermediate rectangle as a user-reversed arrangement.
    private var layoutSettlesAt: TimeInterval = 0
    // Something may have changed the bar since the last tick that could judge it:
    // a start, new settings, another display, a drag.
    private var validationDue = false

    init(statusItems: (any OrganizerStatusItems)? = nil,
         applications: (any OrganizerApplications)? = nil,
         automaticTicks: Bool = true, environment: (() -> OrganizerEnvironment)? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.items = statusItems ?? NativeOrganizerStatusItems()
        self.applications = applications ?? NativeOrganizerApplications()
        self.automaticTicks = automaticTicks
        self.environment = environment ?? { OrganizerEnvironment.live() }
        self.now = now
        items.setMenuAction { [weak self] in self?.perform($0) }
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
            // Whatever kept the helpers away is over.
            if issue != nil { issue = nil }
            // New status items are inserted on the left, so create the recovery arrow first.
            install(.toggle); install(.divider)
            isInstalled = true
            pendingCollapse = settings.startCollapsed; pendingCollapseAsked = false
            if automaticTicks {
                screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                        object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.screensChanged() }
                }
            }
        }
        if settings.permanentlyHiddenSection {
            install(.permanentDivider)
            if !starting && !previous.permanentlyHiddenSection { isEditingArrangement = true; isExpanded = true }
        } else {
            remove(.permanentDivider)
        }
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
        validationDue = true
        scheduleTicks()
    }

    func stop() {
        tearDown()
        awaitCompetitorQuit(false)
        isEnabled = false
        issue = nil
    }

    func toggle() {
        guard isInstalled else { return }
        defer { scheduleTicks() }
        if isEditingArrangement {
            guard arrangementIssue(environment()) == nil else {
                // A spacer that is still settling or a bar without frames is not yet a problem to explain.
                let judged = geometryAvailable && now() >= layoutSettlesAt
                setEditingArrangement(false)
                if judged { onShowSettings?() }
                return
            }
            // End arranging and hide with one resize. Hiding after the second divider has been
            // resized would judge a spacer that has its new width but not yet its new place.
            pendingCollapse = false
            isEditingArrangement = false
            collapse()
            // A held mouse button keeps the icons shown; arranging ends all the same.
            if isExpanded { setEditingArrangement(false) }
            return
        }
        guard isExpanded else { reveal(); return }
        collapse()
        guard isExpanded else { return }
        // Nothing was hidden. An arrangement problem is explained on the page that tells how
        // to repair it; a bar that gives no frames for a moment is asked again by the timer.
        if issue != nil { onShowSettings?() } else if !geometryAvailable { pendingCollapse = true; pendingCollapseAsked = true }
    }

    /// Hides the icons, as the arrow does, unless they are hidden already.
    func hide() {
        guard isInstalled, isExpanded || isEditingArrangement else { return }
        toggle()
    }

    func reveal() {
        guard isInstalled else { return }
        pendingCollapse = false
        isExpanded = true
        applyLengths(environment())
        resetDeadline()
        scheduleTicks()
    }

    /// Window-accessible recovery also reveals the permanent section and pauses auto-hide.
    func setEditingArrangement(_ editing: Bool) {
        guard isInstalled else { return }
        pendingCollapse = false
        isExpanded = true
        isEditingArrangement = editing
        let env = environment()
        if !editing, let problem = arrangementIssue(env) {
            isEditingArrangement = true
            issue = problem
        } else { issue = nil }
        applyLengths(env)
        resetDeadline()
        scheduleTicks()
    }

    /// Whether the settings page can be seen. The page says "no" each time it is put into its window,
    /// which must not end an arrangement that was started from the arrow.
    func setSettingsVisible(_ visible: Bool) {
        guard settingsVisible != visible else { return }
        settingsVisible = visible
        if visible { pendingCollapse = false }
        if !visible && isEditingArrangement { setEditingArrangement(false) }
        resetDeadline()
        scheduleTicks()
    }

    /// A display was connected, removed or resized. The helpers' windows follow the screens a
    /// moment later, so this only brings the next tick forward instead of judging the old frames.
    func screensChanged() {
        guard isInstalled else { return }
        validationDue = true
        scheduleTicks()
    }

    /// One bounded timer drives geometry, display changes, hover and the auto-hide deadline.
    /// Tests call this with an injected clock and status-item adapter; no real bar is changed.
    func tick() {
        guard isInstalled else { return }
        defer { scheduleTicks() }
        let env = environment()
        guard checkAvailability(env) else { return }
        // A dragged item temporarily crosses its neighbors or loses its window.
        // Resizing here fights macOS's placement gesture and causes visible jumping.
        if env.mouseDown { layoutSettlesAt = 0; validationDue = true; resetDeadline(); return }
        guard !menuTracking else { resetDeadline(); return }
        // Auto-hidden menu bars and Space transitions may briefly supply no frames.
        // Preserve intent until we can distinguish that from genuinely unsafe order.
        guard geometryAvailable else { resetDeadline(); return }
        validationDue = false
        if let problem = arrangementIssue(env) {
            guard now() >= layoutSettlesAt else { return }
            isExpanded = true
            issue = problem
            pendingCollapse = false
            applyLengths(env, allowPermanentCollapse: false)
            resetDeadline()
            return
        }
        if issue != nil { issue = nil }
        // Hide at start before anything else is resized: the order was judged just now, and
        // the second divider at its new width would still be at its old place for collapse().
        if pendingCollapse && !env.pointerInMenuBar && !env.mouseDown {
            pendingCollapse = false
            if (pendingCollapseAsked || !settingsVisible) && !isEditingArrangement { collapse() }
        }
        applyLengths(env)
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
            if now() >= layoutSettlesAt { issue = problem; updateMenu() }
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
        // The arrow's window fills the bar, which may be taller than the band known here;
        // what must hold is that it sits in the bar and clears the notch sideways.
        let center = CGPoint(x: arrow.midX, y: arrow.midY)
        guard env.screens.contains(where: { $0.menuRegions.contains(where: { region in
            arrow.minX >= region.minX - 1 && arrow.maxX <= region.maxX + 1 && region.insetBy(dx: 0, dy: -2).contains(center)
        }) }) else {
            return "Frog's arrow is off-screen or behind the notch. Reveal all here, then Command-drag the arrow into the visible right side of the menu bar."
        }
        guard divider.maxX <= arrow.minX + 1, abs(divider.midY - arrow.midY) < 4 else {
            return "Command-drag Frog's divider to the LEFT of its arrow. Frog keeps everything revealed until the arrow is safely on the right."
        }
        if settings.permanentlyHiddenSection {
            guard let permanent = items.frame(of: .permanentDivider), permanent.width > 0,
                  permanent.maxX <= divider.minX + 1, abs(permanent.midY - divider.midY) < 4 else {
                return "Command-drag the double divider to the LEFT of the single divider. Frog keeps everything revealed until it is there."
            }
        }
        return nil
    }

    private func checkAvailability(_ env: OrganizerEnvironment) -> Bool {
        let problem: String?
        if env.competingOrganizer {
            problem = "The Hidden Bar app is running. Quit it to use Frog's hidden bar."
        } else if !env.supportsLengthTechnique {
            problem = "This macOS version does not support the public status-item spacing technique. Frog has left your menu bar revealed."
        } else { problem = nil }
        // No timer runs while the helpers are removed, so the quit has to be noticed apart from it.
        awaitCompetitorQuit(env.competingOrganizer)
        guard let problem else { return true }
        tearDown()
        issue = problem
        return false
    }

    private func awaitCompetitorQuit(_ waiting: Bool) {
        guard waiting != awaitingCompetitorQuit else { return }
        awaitingCompetitorQuit = waiting
        guard waiting else { applications.stopWatching(); return }
        applications.watch { [weak self] in
            guard let self, self.isEnabled, !self.isInstalled, !self.environment().competingOrganizer else { return }
            self.configure(enabled: true, settings: self.settings)
        }
    }

    private func install(_ item: OrganizerItem) {
        guard installed.insert(item).inserted else { return }
        items.install(item)
    }

    private func remove(_ item: OrganizerItem) {
        guard installed.remove(item) != nil else { return }
        items.remove(item)
        appliedLengths[item] = nil
    }

    private func applyLengths(_ env: OrganizerEnvironment, allowPermanentCollapse: Bool = true) {
        statusItemPadding = env.statusItemPadding
        for item in installed {
            let revealed: Bool
            switch item {
            case .toggle: revealed = true
            case .divider: revealed = isExpanded || isEditingArrangement
            case .permanentDivider: revealed = isEditingArrangement || !allowPermanentCollapse
            }
            let length = revealed ? item.revealedLength(padding: env.statusItemPadding) : env.collapsedLength
            if appliedLengths[item] != length {
                if appliedLengths[item] != nil { layoutSettlesAt = now() + 1 }
                items.setLength(length, for: item)
                appliedLengths[item] = length
            }
        }
        items.setExpanded(isExpanded)
        updateMenu()
    }

    private func updateMenu() {
        items.updateMenu(OrganizerMenuState(expanded: isExpanded, arranging: isEditingArrangement, autoHide: settings.autoHide,
                                            issue: issue))
    }

    private func perform(_ action: OrganizerMenuAction) {
        switch action {
        case .toggle: toggle()
        case .arrange: setEditingArrangement(!isEditingArrangement)
        case .autoHide:
            var value = settings; value.autoHide.toggle()
            onSettingsChange?(value)
        case .settings: onShowSettings?()
        case .tracking(let tracking): menuTracking = tracking; resetDeadline()
        }
    }

    private func resetDeadline() {
        deadline = isExpanded && settings.autoHide ? now() + settings.autoHideSeconds : nil
    }

    /// Half a second while something waits on the clock or the pointer. At rest only a
    /// rearranged bar or a second organizer is left to notice, and that may take longer.
    private var tickInterval: TimeInterval? {
        guard isInstalled else { return nil }
        let waiting = validationDue || pendingCollapse || issue != nil || isEditingArrangement
            || now() < layoutSettlesAt || (isExpanded ? settings.autoHide : settings.hoverToReveal)
        return waiting ? 0.5 : 2
    }

    private func scheduleTicks() {
        guard automaticTicks else { return }
        let interval = tickInterval
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate(); timer = nil
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval < 1 ? 0.1 : 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tearDown() {
        timer?.invalidate(); timer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        restoreCompactLengths(padding: environment().statusItemPadding)
        for item in OrganizerItem.allCases.reversed() { remove(item) }
        isInstalled = false; isExpanded = true; isEditingArrangement = false
        deadline = nil; hoverStarted = nil; pendingCollapse = false
        menuTracking = false
        layoutSettlesAt = 0
        validationDue = false
    }

    isolated deinit {
        timer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        applications.stopWatching()
        restoreCompactLengths(padding: statusItemPadding)
        for item in OrganizerItem.allCases.reversed() where installed.contains(item) { items.remove(item) }
    }

    /// Restore compact widths before removal, keeping any saved placement uninflated.
    private func restoreCompactLengths(padding: CGFloat) {
        for item in installed { items.setLength(item.revealedLength(padding: padding), for: item) }
    }
}

@MainActor private final class NativeOrganizerApplications: OrganizerApplications {
    private var observation: NSKeyValueObservation?
    func watch(_ changed: @escaping () -> Void) {
        guard observation == nil else { return }
        observation = NSWorkspace.shared.observe(\.runningApplications) { _, _ in
            // Decide after the workspace has finished updating its list.
            DispatchQueue.main.async { MainActor.assumeIsolated { changed() } }
        }
    }
    func stopWatching() { observation = nil }
}

@MainActor final class NativeOrganizerStatusItems: NSObject, OrganizerStatusItems, NSMenuDelegate {
    private var items: [OrganizerItem: NSStatusItem] = [:]
    private var expanded: Bool?
    private(set) var contextMenu = NSMenu()
    private var menuState: OrganizerMenuState?
    private var menuAction: ((OrganizerMenuAction) -> Void)?

    func setMenuAction(_ action: @escaping (OrganizerMenuAction) -> Void) { menuAction = action }

    func updateMenu(_ state: OrganizerMenuState) {
        guard menuState != state else { return }
        menuState = state
        items[.toggle]?.button?.toolTip = Self.arrowToolTip(expanded: state.expanded, issue: state.issue)
        let menu = NSMenu(); menu.delegate = self
        if let issue = state.issue {
            // A menu does not wrap, so each sentence gets its own line.
            let sentences = issue.components(separatedBy: ". ")
            for (index, sentence) in sentences.enumerated() {
                let item = NSMenuItem(title: index < sentences.count - 1 ? sentence + "." : sentence, action: nil, keyEquivalent: "")
                item.isEnabled = false; menu.addItem(item)
            }
        }
        for (title, selector) in [(state.expanded ? "Hide menu bar icons" : "Show hidden icons", #selector(toggleFromMenu)),
                                  (state.arranging ? "Done arranging" : "Show all & arrange…", #selector(arrangeFromMenu))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        let autoHide = NSMenuItem(title: "Automatically hide icons", action: #selector(autoHideFromMenu), keyEquivalent: "")
        autoHide.target = self; autoHide.state = state.autoHide ? .on : .off; menu.addItem(autoHide)
        let settings = NSMenuItem(title: "Hidden bar settings…", action: #selector(settingsFromMenu), keyEquivalent: "")
        settings.target = self; menu.addItem(settings)
        contextMenu = menu
    }

    func menuWillOpen(_ menu: NSMenu) { menuAction?(.tracking(true)) }
    func menuDidClose(_ menu: NSMenu) { menuAction?(.tracking(false)) }
    @objc private func toggleFromMenu() { menuAction?(.toggle) }
    @objc private func arrangeFromMenu() { menuAction?(.arrange) }
    @objc private func autoHideFromMenu() { menuAction?(.autoHide) }
    @objc private func settingsFromMenu() { menuAction?(.settings) }

    func install(_ role: OrganizerItem) {
        guard items[role] == nil else { return }
        let length = role.revealedLength(padding: OrganizerEnvironment.systemStatusItemPadding)
        let item = NSStatusBar.system.statusItem(withLength: length)
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
                _ = OrganizerDividerView(button: button, isDouble: role == .permanentDivider, width: length)
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
        if items.isEmpty { menuState = nil; contextMenu = NSMenu() }
    }
    func setLength(_ length: CGFloat, for role: OrganizerItem) { items[role]?.length = length }
    func frame(of role: OrganizerItem) -> CGRect? { items[role]?.button?.window?.frame }
    func setExpanded(_ expanded: Bool) {
        guard self.expanded != expanded, let button = items[.toggle]?.button else { return }
        self.expanded = expanded
        button.image = Self.arrowImage(expanded: expanded)
        button.setAccessibilityValue(expanded ? "Expanded" : "Collapsed")
        button.toolTip = Self.arrowToolTip(expanded: expanded, issue: menuState?.issue)
    }
    /// While an arrangement problem keeps the icons shown, the arrow says so instead of offering to hide them.
    static func arrowToolTip(expanded: Bool, issue: String?) -> String {
        issue ?? (expanded ? "Hide menu bar icons" : "Show hidden icons") + ". Right-click for options; Option-click to arrange all icons."
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
        let marker = OrganizerItem.divider.revealedLength(padding: OrganizerEnvironment.systemStatusItemPadding)
        contextMenu.popUp(positioning: nil, at: NSPoint(x: button.bounds.maxX - marker, y: button.bounds.minY), in: button)
    }
    @objc private func clickedArrow() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(from: .toggle) }
        else if NSApp.currentEvent?.modifierFlags.contains(.option) == true { menuAction?(.arrange) }
        else { menuAction?(.toggle) }
    }
    @objc private func clickedDivider(_ sender: NSStatusBarButton) {
        let role = items.first { $0.value.button === sender }?.key ?? .divider
        showMenu(from: role)
    }
}

@MainActor final class OrganizerDividerView: NSView {
    private let isDouble: Bool
    init(button: NSButton, isDouble: Bool, width: CGFloat = 18) {
        self.isDouble = isDouble
        super.init(frame: NSRect(x: button.bounds.width - width, y: 0, width: width, height: button.bounds.height))
        autoresizingMask = [.minXMargin, .height]
        button.addSubview(self)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var lineOrigins: [CGFloat] {
        let center = (bounds.width / 2).rounded(.down)
        return isDouble ? [center - 2, center + 2] : [center]
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.8).setFill()
        for x in lineOrigins {
            NSBezierPath(roundedRect: NSRect(x: x, y: (bounds.height - 14) / 2, width: 1, height: 14), xRadius: 0.5, yRadius: 0.5).fill()
        }
    }
}
