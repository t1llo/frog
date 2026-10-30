import AppKit
import SwiftUI
import FrogCore

/// `[hidden-bar]` in config.toml.
struct HiddenBarSettings: ConfigSection {
    var autoHide = true
    var autoHideSeconds: Double = 10
    var startHidden = false
    var showOnHover = false
    var alwaysHiddenSection = false
    var shortcut: Shortcut?

    static let comments = [
        "auto-hide": "Hide the icons again after a while",
        "auto-hide-seconds": "How long they stay shown, 1 to 3600",
        "start-hidden": "Hide the icons when Frog starts",
        "show-on-hover": "Show them while the pointer rests on the menu bar",
        "always-hidden-section": "A second divider; icons left of it stay hidden",
        "shortcut": "Shows or hides the icons, such as \"ctrl+alt+b\"; leave out for none"
    ]

    init() {}

    init(legacy: MenuBarPreferences) {
        autoHide = legacy.autoHide; autoHideSeconds = legacy.autoHideSeconds; startHidden = legacy.startCollapsed
        showOnHover = legacy.hoverToReveal; alwaysHiddenSection = legacy.permanentlyHiddenSection
        shortcut = legacy.hotkey.flatMap { try? Shortcut($0) }
    }

    /// What the organizer reads.
    var organizer: MenuBarPreferences {
        var value = MenuBarPreferences()
        value.autoHide = autoHide; value.autoHideSeconds = autoHideSeconds; value.startCollapsed = startHidden
        value.hoverToReveal = showOnHover; value.permanentlyHiddenSection = alwaysHiddenSection; value.hotkey = shortcut?.hotkey
        return value.normalized
    }
}

/// Hides menu-bar icons left of Frog's divider behind an arrow. The organizer and its status items exist only
/// while the plugin runs.
final class HiddenBarPlugin: LegacyPlugin, FrogPlugin, ObservableObject {
    static let info = PluginInfo(id: "hidden-bar", name: "Hidden bar", symbol: "menubar.rectangle", tint: .gray, category: .system,
                                 summary: "Tuck menu-bar icons out of sight")
    /// For tests: an organizer with fake status items. Without one, only a model that registers shortcuts gets
    /// a real organizer, so test models never touch the menu bar.
    nonisolated(unsafe) static var makeOrganizer: (@MainActor () -> MenuBarOrganizer)?

    @Published private(set) var organizer: MenuBarOrganizer?
    @Published private(set) var settings = HiddenBarSettings()
    @Published private(set) var shortcutError: String?
    private var termination: NSObjectProtocol?

    func start() async {
        settings = MacPluginSettings.load(context, legacy: { HiddenBarSettings(legacy: $0.preferences.toolkitSettings.menuBar ?? MenuBarPreferences()) })
        let organizer = Self.makeOrganizer?() ?? (model.registerShortcuts ? MenuBarOrganizer() : nil)
        organizer?.onShowSettings = { [context] in context.openPage() }
        organizer?.onSettingsChange = { [weak self] value in self?.update { $0.autoHide = value.autoHide } }
        self.organizer = organizer
        // Quitting does not stop plugins; the helpers give back their room before Frog exits.
        termination = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.organizer?.stop() }
        }
        apply()
    }

    func stop() async {
        if let termination { NotificationCenter.default.removeObserver(termination) }
        termination = nil
        model.setPluginShortcut(AppModel.menuBarID, name: "Hidden bar", hotkey: nil)
        organizer?.stop()
        organizer = nil
        shortcutError = nil
    }

    func settingsChanged() {
        settings = context.settings(HiddenBarSettings.self)
        apply()
    }

    func update(_ change: (inout HiddenBarSettings) -> Void) {
        var value = settings
        change(&value)
        value.autoHideSeconds = value.organizer.autoHideSeconds
        guard value != settings else { return }
        settings = value
        do { try context.save(value) } catch { context.report(error) }
        apply()
    }

    private func apply() {
        guard let organizer else { return }
        organizer.configure(enabled: true, settings: settings.organizer)
        let error = model.setPluginShortcut(AppModel.menuBarID, name: "Hidden bar", hotkey: settings.shortcut?.hotkey) { [weak organizer] in
            organizer?.toggle()
        }
        if shortcutError != error { shortcutError = error }
    }

    func page() -> AnyView? { legacyPage(HiddenBarPage(plugin: self)) }

    var menu: [MenuContribution] {
        [MenuContribution(id: "hidden-bar.notice", order: 50) { [weak self] in
            guard let organizer = self?.organizer else { return AnyView(EmptyView()) }
            return AnyView(MenuBarOrganizerNotice(organizer: organizer))
        }]
    }

    struct Status: Encodable {
        let hidden: Bool
        let arranging: Bool
        let issue: String?
    }

    private func run(_ change: (MenuBarOrganizer) -> Void) throws -> ActionResult {
        guard let organizer, organizer.isInstalled else {
            throw ActionError.failed(organizer?.issue ?? "Hidden bar has no arrow in the menu bar right now.")
        }
        change(organizer)
        let status = Status(hidden: !organizer.isExpanded, arranging: organizer.isEditingArrangement, issue: organizer.issue)
        return ActionResult(status, text: organizer.issue ?? (status.arranging ? "Arranging: every icon is shown." : status.hidden ? "Icons hidden." : "Icons shown."))
    }

    var actions: [PluginAction] {
        [PluginAction(id: "hidden-bar.toggle", title: "Show or hide menu-bar icons", symbol: "menubar.rectangle",
                      keywords: "hidden bar menu bar icons") { [weak self] _ in
            try self?.run { $0.toggle() } ?? .done()
         },
         PluginAction(id: "hidden-bar.show", title: "Show hidden icons", symbol: "menubar.arrow.down.rectangle",
                      keywords: "hidden bar menu bar icons reveal", surfaces: [.agent, .shortcut]) { [weak self] _ in
            try self?.run { $0.reveal() } ?? .done()
         },
         PluginAction(id: "hidden-bar.hide", title: "Hide menu-bar icons", symbol: "menubar.arrow.up.rectangle",
                      keywords: "hidden bar menu bar icons collapse", surfaces: [.agent, .shortcut]) { [weak self] _ in
            try self?.run { $0.hide() } ?? .done()
         },
         PluginAction(id: "hidden-bar.arrange", title: "Arrange menu-bar icons", symbol: "rectangle.and.hand.point.up.left",
                      keywords: "hidden bar menu bar icons arrange", surfaces: [.commandBar, .agent]) { [weak self] _ in
            try self?.run { $0.setEditingArrangement(!$0.isEditingArrangement) } ?? .done()
         }]
    }
}
