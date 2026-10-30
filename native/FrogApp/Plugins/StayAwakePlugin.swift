import AppKit
import SwiftUI
import FrogCore

/// `[stay-awake]` in config.toml.
struct StayAwakeSettings: ConfigSection {
    var duration: StayAwakeController.DurationChoice = .untilOff
    var until = "18:00"
    var keepScreenOn = true
    var lidClosed = false
    var menuBarItem = false
    var menuBarStyle = "ring"

    static let comments = [
        "duration": "How long a session lasts: until-off, 1h, 3h or until-time",
        "until": "When until-time ends, as HH:MM",
        "keep-screen-on": "Keep the display on too, so the screen does not lock",
        "lid-closed": "Also stay awake with the lid closed; needs a one-time setup",
        "menu-bar-item": "Show a cup in the menu bar while a session runs",
        "menu-bar-style": "icon, ring or time"
    ]

    /// What the old preferences had: only the menu-bar cup.
    init(legacy: StayAwakePreferences) {
        menuBarItem = legacy.menuBarItem; menuBarStyle = legacy.normalized.menuBarStyle
    }
    init() {}

    var normalized: Self {
        var value = self
        if !StayAwakePreferences.menuBarStyles.contains(menuBarStyle) { value.menuBarStyle = "ring" }
        if StayAwakeLength("until \(until)") == nil { value.until = "18:00" }
        return value
    }
}

/// Keeps the Mac awake. The controller lives on the app model, since the app delegate restores sleep at quit;
/// this plugin owns the settings, the menu-bar cup and the actions.
final class StayAwakePlugin: LegacyPlugin, FrogPlugin, ObservableObject {
    static let info = PluginInfo(id: "stay-awake", name: "Stay awake", symbol: "cup.and.saucer", tint: .orange, category: .system,
                                 summary: "Keep the Mac and its screen awake", enabledByDefault: true, recommended: true)
    private var power: StayAwakeController { model.power }
    private var statusItem: StayAwakeStatusItemController?
    @Published private(set) var settings = StayAwakeSettings()

    func start() async {
        settings = MacPluginSettings.load(context, legacy: { StayAwakeSettings(legacy: $0.preferences.toolkitSettings.stayAwake ?? StayAwakePreferences()) }).normalized
        apply()
    }

    func stop() async {
        statusItem?.stop(); statusItem = nil
        power.hasOwnMenuBarIcon = false
        power.turnOff()
        power.configure(keepScreenOn: settings.keepScreenOn, lidClosed: false)
        await power.waitForLid()
    }

    func settingsChanged() {
        settings = context.settings(StayAwakeSettings.self).normalized
        apply()
    }

    func update(_ change: (inout StayAwakeSettings) -> Void) {
        var value = settings
        change(&value)
        value = value.normalized
        guard value != settings else { return }
        settings = value
        do { try context.save(value) } catch { context.report(error) }
        apply()
    }

    private func apply() {
        if power.duration != settings.duration { power.duration = settings.duration }
        if power.untilTime != settings.until { power.untilTime = settings.until }
        power.configure(keepScreenOn: settings.keepScreenOn, lidClosed: settings.lidClosed)
        let shows = settings.menuBarItem && model.registerShortcuts
        if shows {
            if let statusItem { statusItem.apply(style: settings.menuBarStyle) }
            else { statusItem = StayAwakeStatusItemController(power: power, style: settings.menuBarStyle) { [context] in context.openPage() } }
        } else { statusItem?.stop(); statusItem = nil }
        // Frog's own icon leaves out its small cup while the cup has an item of its own.
        if power.hasOwnMenuBarIcon != shows { power.hasOwnMenuBarIcon = shows }
    }

    func page() -> AnyView? { legacyPage(StayAwakePage(power: power, plugin: self)) }

    var menu: [MenuContribution] {
        [MenuContribution(id: "stay-awake.switch", order: 0) { [power, weak self] in
            AnyView(StayAwakePopupRow(power: power) { choice in self?.update { $0.duration = choice } })
        }]
    }

    struct Status: Encodable {
        let on: Bool
        let until: Date?
        let screenOn: Bool
        let lidClosed: Bool
        let lidClosedActive: Bool
        let notice: String?
    }

    private func status() -> ActionResult {
        let status = Status(on: power.isEnabled, until: power.deadline, screenOn: power.keepScreenOn, lidClosed: power.lidClosed,
                            lidClosedActive: power.lid.ownsSession, notice: power.notice ?? power.error)
        var text = power.statusText
        if power.isEnabled, power.lidClosed { text += power.lid.ownsSession ? " · lid closed too" : " · lid closed needs setup" }
        return ActionResult(status, text: text)
    }

    var actions: [PluginAction] {
        [PluginAction(id: "stay-awake.toggle", title: "Stay awake on or off", symbol: "cup.and.saucer", keywords: "caffeinate sleep awake") { [power, weak self] _ in
            power.toggle(); await power.waitForLid()
            return self?.status() ?? .done()
         },
         PluginAction(id: "stay-awake.on", title: "Stay awake", symbol: "cup.and.saucer.fill", keywords: "caffeinate sleep awake",
                      parameters: [ActionParameter(name: "for", help: "Minutes, 1h, 3h or until 17:30; the page's duration when left out")],
                      surfaces: [.agent, .shortcut]) { [power, weak self] input in
            var length: StayAwakeLength?
            if let text = input.value("for"), !text.isEmpty {
                guard let parsed = StayAwakeLength(text) else { throw ActionError.invalid("for", "minutes, 1h, 3h or until HH:MM") }
                length = parsed
            }
            power.turnOn(length); await power.waitForLid()
            return self?.status() ?? .done()
         },
         PluginAction(id: "stay-awake.off", title: "Let the Mac sleep", symbol: "cup.and.saucer", keywords: "caffeinate sleep awake off",
                      surfaces: [.agent, .shortcut]) { [power, weak self] _ in
            power.turnOff(); await power.waitForLid()
            return self?.status() ?? .done()
         },
         PluginAction(id: "stay-awake.status", title: "Stay awake status", symbol: "cup.and.saucer", surfaces: [.agent]) { [weak self] _ in
            self?.status() ?? .done()
         }]
    }
}

/// Settings seeded once from the old preferences: the first start after the update writes the plugin's table,
/// and from then on config.toml alone decides.
enum MacPluginSettings {
    @MainActor static func load<Section: ConfigSection>(_ context: PluginContext, legacy: (Configuration) -> Section) -> Section {
        guard context.legacy.settingsFile.document.value(at: [context.info.id]) == nil else { return context.settings(Section.self) }
        let seeded = legacy(context.legacy.configuration)
        do { try context.save(seeded) } catch { context.report(error) }
        return seeded
    }
}
