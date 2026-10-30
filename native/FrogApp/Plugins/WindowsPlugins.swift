import AppKit
import Observation
import SwiftUI
import FrogCore

// MARK: Windows

/// `[windows]` in config.toml. Layout shortcuts stay on their rules, which Shortcuts lists too.
struct WindowsSettings: ConfigSection {
    enum Zones: String, Codable, CaseIterable, Sendable {
        case halves, thirds, quarters
        case mainSide = "main-side"
    }

    var gap = 0
    var cycleSizes = false
    var portraitThirds = true
    var respectStageManager = true
    var dragToSnap = false
    var restoreOnDrag = true
    var zoneOverlay = false
    var zones = Zones.thirds
    var layoutPicker = false
    var layoutPickerShortcut: Shortcut?
    var cheatSheetShortcut: Shortcut?

    static let comments = [
        "": "Windows: snap and tile windows with keys.",
        "gap": "Points around and between windows, 0 to 40",
        "cycle-sizes": "A half pressed again takes 2/3, then 1/3",
        "portrait-thirds": "Thirds run top to bottom on tall displays",
        "respect-stage-manager": "Keep Stage Manager's strip free",
        "drag-to-snap": "Drop a window on a screen edge or corner to snap it",
        "restore-on-drag": "A snapped window dragged away gets its size back",
        "zone-overlay": "Hold shift while dragging to show zones",
        "zones": "halves, thirds, quarters or main-side",
        "layout-picker": "A panel of every layout, from its shortcut or the command bar",
        "cheat-sheet-shortcut": "Hold to see every window shortcut",
    ]
}

extension WindowsSettings {
    /// The settings Frog kept before config.toml.
    init(legacy: WindowPreferences) {
        let value = legacy.normalized
        gap = value.gap; cycleSizes = value.cycleSizes; portraitThirds = value.portraitThirds
        respectStageManager = value.respectStageManager; dragToSnap = value.dragToSnap; restoreOnDrag = value.restoreOnDrag
        zoneOverlay = value.zoneOverlay; zones = Zones(rawValue: ZoneGrid(rawValue: value.zoneGrid)?.rawValue ?? "") ?? .thirds
        layoutPicker = value.layoutPicker
        layoutPickerShortcut = value.shortcuts[WindowCommand.layoutPicker.rawValue].flatMap { try? Shortcut($0) }
        cheatSheetShortcut = value.shortcuts[WindowCommand.cheatSheet.rawValue].flatMap { try? Shortcut($0) }
    }

    /// The legacy preferences the still-shared code reads (shortcut registration, layout options), with
    /// what config.toml does not hold kept as it was.
    func legacy(from previous: WindowPreferences) -> WindowPreferences {
        var value = previous
        value.gap = gap; value.cycleSizes = cycleSizes; value.portraitThirds = portraitThirds
        value.respectStageManager = respectStageManager; value.dragToSnap = dragToSnap; value.restoreOnDrag = restoreOnDrag
        value.zoneOverlay = zoneOverlay; value.zoneGrid = zones.rawValue; value.layoutPicker = layoutPicker
        value.shortcuts[WindowCommand.layoutPicker.rawValue] = layoutPickerShortcut?.hotkey
        value.shortcuts[WindowCommand.cheatSheet.rawValue] = cheatSheetShortcut?.hotkey
        return value.normalized
    }

    func shortcut(_ command: WindowCommand) -> Shortcut? {
        switch command {
        case .layoutPicker: layoutPickerShortcut
        case .cheatSheet: cheatSheetShortcut
        }
    }

    mutating func setShortcut(_ shortcut: Shortcut?, for command: WindowCommand) {
        switch command {
        case .layoutPicker: layoutPickerShortcut = shortcut
        case .cheatSheet: cheatSheetShortcut = shortcut
        }
    }
}

/// Snaps and tiles windows: layout shortcuts, drag to snap, Shift zones, the layout picker and the cheat
/// sheet. Its panels and drag monitor exist only while it runs; Restore history is Frog's, shared with
/// Shortcuts and `frog`.
@MainActor @Observable final class WindowsPlugin: FrogPlugin {
    static let info = PluginInfo(id: "windows", name: "Windows", symbol: "rectangle.split.2x1", tint: .purple, category: .windows,
                                 summary: "Snap and tile windows with keys", permissions: [.accessibility], recommended: true)

    let context: PluginContext
    /// What config.toml says, as the page shows it.
    private(set) var settings = WindowsSettings()
    @ObservationIgnored private(set) var controller: WindowLayoutController?
    private var model: AppModel { context.legacy }

    init(context: PluginContext) { self.context = context }

    func start() async {
        settings = Self.adoptedSettings(context)
        mirror()
        let model = model
        let controller = WindowLayoutController(manager: model.windowManager)
        controller.onError = { [weak model] in model?.report($0) }
        controller.onToolUse = { [weak model] in model?.statistics.recordToolUse($0) }
        self.controller = controller
        model.windowLayout = controller
        model.configureWindowLayout()
    }

    func stop() async {
        controller?.stop()
        if model.windowLayout === controller { model.windowLayout = nil }
        controller = nil
    }

    func settingsChanged() {
        let read = context.settings(WindowsSettings.self)
        guard read != settings else { return }
        settings = read
        mirror()
    }

    func page() -> AnyView? { AnyView(WindowsView(plugin: self).environmentObject(model)) }

    /// Saves a change from the page into config.toml, and into the preferences the shortcuts still read.
    func update(_ change: (inout WindowsSettings) -> Void) {
        var next = settings
        change(&next)
        next.gap = min(WindowPreferences.gapRange.upperBound, max(WindowPreferences.gapRange.lowerBound, next.gap))
        guard next != settings else { return }
        let previous = settings
        settings = next
        do {
            try mirrorThrowing()
            try context.save(next)
        } catch {
            settings = previous
            context.report(error)
        }
    }

    /// Takes the command shortcuts the suggestions just wrote into the preferences into config.toml.
    func adoptLegacyCommands() {
        let legacy = WindowsSettings(legacy: model.configuration.preferences.toolkitSettings.windows ?? WindowPreferences())
        var next = settings
        for command in WindowCommand.allCases { next.setShortcut(legacy.shortcut(command), for: command) }
        guard next != settings else { return }
        settings = next
        do { try context.save(next) } catch { context.report(error) }
    }

    /// The table, or, when config.toml has none yet, the one Frog kept before.
    static func adoptedSettings(_ context: PluginContext) -> WindowsSettings {
        if context.legacy.settingsFile.document.value(at: [info.id]) != nil { return context.settings(WindowsSettings.self) }
        let seeded = WindowsSettings(legacy: context.legacy.configuration.preferences.toolkitSettings.windows ?? WindowPreferences())
        do { try context.save(seeded) } catch { context.report(error) }
        return seeded
    }

    private func mirror() {
        do { try mirrorThrowing() } catch { context.report(error) }
    }

    private func mirrorThrowing() throws {
        let current = model.configuration.preferences.toolkitSettings.windows ?? WindowPreferences()
        let wanted = settings.legacy(from: current)
        guard wanted != current else { return }
        try model.updateToolkit { $0.windows = wanted }
    }

    // MARK: Actions

    var actions: [PluginAction] {
        var actions = WindowAction.allCases.map { action in
            PluginAction(id: "windows.\(WritingPlugin.slug(action.title))", title: action.title, symbol: "rectangle.split.2x1",
                         keywords: "window layout move resize", surfaces: [.shortcut, .agent]) { [model] _ in
                model.runWindowAction(action); return .done()
            }
        }
        actions += [
            PluginAction(id: "windows.list", title: "List windows", symbol: "macwindow.on.rectangle", keywords: "windows open",
                         parameters: [ActionParameter(name: "app", help: "Only this app's windows")], surfaces: .agent) { input in
                let windows = try await WindowTargets.windows(app: input.value("app"))
                let text = windows.isEmpty ? "No windows are open." : windows.map { "\($0.id)\t\($0.name)" }.joined(separator: "\n")
                return ActionResult(windows, text: text)
            },
            PluginAction(id: "windows.focus", title: "Focus window", symbol: "macwindow", keywords: "bring front switch",
                         parameters: WindowTargets.parameters, surfaces: .agent) { input in
                let window = try await WindowTargets.window(input, includingMinimized: true)
                guard await AgentCommands.desktop.focus(window) else {
                    throw ActionError.failed("macOS could not bring \(window.name) to the front. It may have closed.")
                }
                return ActionResult(window, text: "Brought \(window.name) to the front.")
            },
            PluginAction(id: "windows.move", title: "Move window", symbol: "rectangle.split.2x1", keywords: "layout snap",
                         parameters: [ActionParameter(name: "to", kind: .choice(WindowAction.allCases.map(\.agentName)), required: true,
                                                      help: "The layout, such as left-half or next-display")] + WindowTargets.parameters,
                         surfaces: .agent) { [model] input in
                guard let action = WindowAction.agentNamed(try input.required("to")) else { throw ActionError.invalid("to", "a layout") }
                let window = try await WindowTargets.window(input)
                var options = WindowSwitches(model.configuration.preferences).layoutOptions(AgentCommands.desktop.macOS())
                // An agent asking twice wants the same layout twice, not the next size of a cycle.
                options.cycleSizes = false
                let manager = AgentCommands.desktop.manager ?? model.windowManager
                try await manager.apply(action, to: window.handle, displays: AgentCommands.desktop.displays(), options: options)
                return ActionResult(window, text: AgentCommands.sentence(action, window.name))
            }
        ]
        if controller?.pickerAvailable == true {
            actions.append(PluginAction(id: "windows.arrange", title: "Arrange window…", symbol: "rectangle.split.2x1",
                                        keywords: "layout picker", surfaces: [.commandBar, .agent]) { [weak self] _ in
                self?.controller?.handle(.layoutPicker, pressed: true)
                return .done("Showing the layout picker.")
            })
        }
        return actions
    }

    var menu: [MenuContribution] {
        guard let controller, controller.pickerAvailable else { return [] }
        return [MenuContribution(id: "windows.arrange", order: 40) { [weak controller] in
            AnyView(MenuActionRow(title: "Arrange window…", symbol: "rectangle.split.2x1", closes: true) {
                controller?.handle(.layoutPicker, pressed: true)
            })
        }]
    }
}

/// Which window an action means: `--id` from `windows.list`, `--app` for that app's focused window, `--title`
/// for the first window whose title holds the text, or the focused window of the app in front.
enum WindowTargets {
    static let parameters = [
        ActionParameter(name: "app", help: "The app's focused window"),
        ActionParameter(name: "title", help: "A window whose title holds this text"),
        ActionParameter(name: "id", kind: .integer, help: "A window id from windows.list"),
    ]

    @MainActor static func windows(app: String? = nil) async throws -> [AgentWindow] {
        let desktop = AgentCommands.desktop
        guard desktop.isTrusted() else { throw ActionError.failed(AgentCommands.accessibilityNeeded) }
        var apps = desktop.apps()
        if let app { apps = [try AgentCommands.runningApp(app, in: apps)] }
        return await AgentCommands.scan(apps)
    }

    @MainActor static func window(_ input: ActionInput, includingMinimized: Bool = false) async throws -> AgentWindow {
        let id = try input.integer("id"), app = input.value("app"), title = input.value("title")?.lowercased()
        let windows = try await windows(app: app)
        if let id {
            guard let window = windows.first(where: { Int($0.id) == id }) else {
                throw ActionError.failed("No open window has id \(id). Run `frog run windows.list` for the ids.")
            }
            return window
        }
        if let title, !title.isEmpty {
            guard let window = windows.first(where: { $0.title.lowercased().contains(title) }) else {
                throw ActionError.failed("No open window's title holds “\(title)”.")
            }
            return window
        }
        let shown = windows.filter { includingMinimized || !$0.minimized }
        let front = app == nil ? AgentCommands.desktop.frontmost() : nil
        let candidates = front.map { pid in shown.filter { $0.pid == pid } }.flatMap { $0.isEmpty ? nil : $0 } ?? shown
        guard let window = candidates.first(where: \.appFocused) ?? candidates.first(where: { !$0.hidden }) ?? candidates.first else {
            throw ActionError.failed(app.map { "\($0) has no window open on this Desktop." } ?? "There is no window to arrange.")
        }
        return window
    }
}

// MARK: Window switcher

/// `[window-switcher]` in config.toml.
struct WindowSwitcherSettings: ConfigSection {
    var shortcut = try! Shortcut(WindowSwitchKeyRouter.defaultHotkey)

    static let comments = [
        "": "Window switcher: switch between windows, not apps.",
        "shortcut": "Hold its modifiers to keep switching; add shift to go back",
    ]
}

/// Switches between windows rather than apps. While it runs it holds one event tap and a small cache of the
/// window list and app icons; turned off, it holds nothing.
@MainActor @Observable final class WindowSwitcherPlugin: FrogPlugin {
    static let info = PluginInfo(id: "window-switcher", name: "Window switcher", symbol: "macwindow.on.rectangle", tint: .indigo,
                                 category: .windows, summary: "Switch between windows, not apps", enabledByDefault: true,
                                 permissions: [.accessibility], recommended: true)

    let context: PluginContext
    private(set) var status = WindowSwitcherStatus.notStarted
    private(set) var settings = WindowSwitcherSettings()
    @ObservationIgnored private(set) var controller: WindowSwitcherController?
    private var model: AppModel { context.legacy }

    init(context: PluginContext) { self.context = context }

    func start() async {
        settings = Self.adoptedSettings(context)
        mirror()
        model.windowSwitcher = self
        model.configureWindowSwitcher()
    }

    func stop() async {
        halt()
        if model.windowSwitcher === self { model.windowSwitcher = nil }
        controller = nil
        status = .off
    }

    /// Removes the event tap and empties the caches, at once; Frog quitting does not wait.
    func halt() { controller?.stop() }

    func settingsChanged() {
        let read = context.settings(WindowSwitcherSettings.self)
        guard read != settings else { return }
        settings = read
        mirror()
    }

    func page() -> AnyView? { AnyView(WindowSwitcherView(plugin: self).environmentObject(model)) }

    var actions: [PluginAction] {
        [PluginAction(id: "window-switcher.show", title: "Switch windows", symbol: "macwindow.on.rectangle",
                      keywords: "window switcher list", surfaces: .all) { [weak self] _ in
            guard let self else { throw ActionError.pluginOff(Self.info.name) }
            guard self.controller?.showList() == true else { throw ActionError.failed(self.status.text) }
            return .done("Showing the window switcher.")
        }]
    }

    /// A new shortcut from the page: checked and applied first, then written to config.toml.
    func setShortcut(_ hotkey: Hotkey) throws {
        if let issue = HotkeyManager.validationError(hotkey, purpose: .windowSwitcher) { throw FrogError.message(issue) }
        let next = WindowSwitcherSettings(shortcut: try Shortcut(hotkey))
        let previous = settings
        settings = next
        do { try mirrorThrowing(); try context.save(next) } catch { settings = previous; throw error }
    }

    /// Follows the configuration: the chord, a conflict with another shortcut, a shortcut being recorded and
    /// Accessibility. Called by the app model after each change and once a second.
    func refresh() {
        let configuration = model.configuration
        switch Self.step(configuration, status: status) {
        case .none: return
        case .stop(let reason):
            controller?.stop()
            publish(reason)
        case .configure:
            let preferences = configuration.preferences
            let controller = self.controller ?? makeController()
            controller.configure(enabled: preferences.featureEnabled(.windowSwitcher), suspended: model.isRecordingShortcut,
                                 hotkey: preferences.toolkitSettings.effectiveWindowSwitcherHotkey)
            controller.updateShortcuts(configuration.rules.filter { model.ruleFeatureEnabled($0) && model.hotkeyErrors[$0.id] == nil })
        }
    }

    private func makeController() -> WindowSwitcherController {
        let controller = WindowSwitcherController { [weak self] status in self?.publish(status) }
        controller.onError = { [weak model] in model?.report(FrogError.message($0)) }
        self.controller = controller
        return controller
    }

    private func publish(_ status: WindowSwitcherStatus) {
        if self.status != status { self.status = status }
    }

    static func adoptedSettings(_ context: PluginContext) -> WindowSwitcherSettings {
        if context.legacy.settingsFile.document.value(at: [info.id]) != nil { return context.settings(WindowSwitcherSettings.self) }
        let hotkey = context.legacy.configuration.preferences.toolkitSettings.effectiveWindowSwitcherHotkey
        let seeded = (try? Shortcut(hotkey)).map { WindowSwitcherSettings(shortcut: $0) } ?? WindowSwitcherSettings()
        do { try context.save(seeded) } catch { context.report(error) }
        return seeded
    }

    private func mirror() {
        do { try mirrorThrowing() } catch { context.report(error) }
    }

    private func mirrorThrowing() throws {
        guard model.configuration.preferences.toolkitSettings.effectiveWindowSwitcherHotkey != settings.shortcut.hotkey else { return }
        try model.updateToolkit { $0.windowSwitcherHotkey = settings.shortcut.hotkey }
    }

    // MARK: Conflicts

    /// What refreshing comes to.
    enum Step: Equatable {
        /// Configure it from the preferences.
        case configure
        /// Stop it and say why: another shortcut takes its chord.
        case stop(WindowSwitcherStatus)
        /// Nothing: it is stopped for that conflict, and the page says so already.
        case none
    }

    static func step(_ configuration: Configuration, status: WindowSwitcherStatus) -> Step {
        let preferences = configuration.preferences
        let switcherHotkey = preferences.toolkitSettings.effectiveWindowSwitcherHotkey
        func conflicts(_ hotkey: Hotkey) -> Bool {
            hotkey.keyCode == switcherHotkey.keyCode &&
                (hotkey.modifiers == switcherHotkey.modifiers || hotkey.modifiers == (switcherHotkey.modifiers | 512))
        }
        // Existing shortcuts keep their keys, including the reverse-cycling combination.
        let ruleConflict = configuration.rules.contains { rule in
            guard rule.enabled, preferences.ruleFeatureEnabled(rule), let hotkey = rule.hotkey else { return false }
            return conflicts(hotkey)
        }
        let workflow = preferences.workflowSettings
        let frogKeys = [workflow.shortcutPanelHotkey,
                        preferences.featureEnabled(.dictation) ? workflow.cancelRecordingHotkey : nil,
                        workflow.clipboardHistoryEnabled == true ? workflow.effectiveClipboardHistoryHotkey : nil,
                        preferences.featureEnabled(.commandBar) ? preferences.toolkitSettings.effectiveCommandBarHotkey : nil,
                        preferences.featureEnabled(.menuBar) ? preferences.toolkitSettings.menuBar?.hotkey : nil].compactMap { $0 }
            + WindowSwitches(preferences).shortcutRules.compactMap(\.hotkey)
        guard preferences.windowSwitcherEnabled && (ruleConflict || frogKeys.contains(where: conflicts)) else { return .configure }
        let reason = WindowSwitcherStatus.conflict(switcherHotkey)
        // Stopping again would publish Off and then the conflict, redrawing the page each second.
        return status == reason ? .none : .stop(reason)
    }

    /// The switcher's chord and the same with Shift, which cycles backward, while the switcher is on:
    /// what `step` treats as a conflict, and validation cannot see.
    static func chords(_ preferences: Preferences) -> Set<Hotkey> {
        guard preferences.windowSwitcherEnabled else { return [] }
        let key = preferences.toolkitSettings.effectiveWindowSwitcherHotkey
        return [key, Hotkey(keyCode: key.keyCode, modifiers: key.modifiers | 512)]
    }
}
