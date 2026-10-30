import AppKit
import Combine
import SwiftUI
import FrogCore

/// `[command-bar]` in config.toml.
struct CommandBarSettings: ConfigSection {
    var shortcut = CommandBarSettings.defaultShortcut
    var learnChoices = false

    static let defaultShortcut = try! Shortcut(Hotkey(keyCode: 49, modifiers: 4096 | 2048))
    static let comments = [
        "": "Command bar: apps, files, settings and Frog actions as you type.",
        "shortcut": "Opens and closes the bar, such as \"cmd+space\".",
        "learn-choices": "Rows you pick move up. Kept on this Mac."
    ]

    /// The table as the legacy preferences had it, for a config.toml written before the table existed.
    init(legacy toolkit: ToolkitPreferences) {
        if let key = try? Shortcut(toolkit.effectiveCommandBarHotkey) { shortcut = key }
        learnChoices = toolkit.commandBarSettings.learnChoices
    }
    init() {}
}

/// The command bar. It owns the panel and its global shortcut while it runs; nothing of it stays behind when it
/// stops. Its rows come from providers, the plugins' among them.
final class CommandBarPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "command-bar", name: "Command bar", symbol: "magnifyingglass", tint: .indigo, category: .navigate,
                                 summary: "Find apps, files and actions", recommended: true)

    private(set) var bar: CommandBar?
    private let hotkeys = HotkeyManager()
    private var recording: AnyCancellable?
    private(set) var settings = CommandBarSettings()
    /// Why the shortcut could not be registered, such as another app holding it.
    private(set) var shortcutIssue: String?
    private let hotkeyID = UUID()

    func start() async {
        settings = Self.settings(model)
        mirror()
        let bar = CommandBar(model: model, pasteboard: model.clipboardHistoryStore.pasteboard)
        bar.onToolUse = { [weak model] in model?.statistics.recordToolUse($0) }
        self.bar = bar
        // A shortcut being recorded must reach its recorder, so the bar's own is let go meanwhile.
        recording = model.$isRecordingShortcut.dropFirst().removeDuplicates().sink { [weak self] recording in
            if recording { self?.bar?.hide(); self?.hotkeys.unregister() } else { self?.register() }
        }
        register()
        // Tests make many models; only the app's own builds the panel and reads the apps ahead of the first open.
        if model.registerShortcuts { bar.warm() }
    }

    func stop() async {
        recording = nil
        hotkeys.unregister()
        bar?.stop(); bar = nil
    }

    func settingsChanged() {
        let next = Self.settings(model)
        guard next != settings else { return }
        settings = next
        mirror()
        register()
    }

    func show() {
        guard !model.isRecordingShortcut else { return }
        bar?.show()
    }
    func hide() { bar?.hide() }

    /// Saves a new shortcut and turns the bar on. First-run setup uses it for ⌘Space; saving the same shortcut
    /// again registers it again, since it may just have been freed in System Settings.
    static func useShortcut(_ hotkey: Hotkey, model: AppModel) throws {
        var settings = settings(model)
        settings.shortcut = try Shortcut(hotkey)
        try model.settingsFile.update(info.id, settings)
        var preferences = model.configuration.preferences
        preferences.setFeature(.commandBar, enabled: true)
        preferences.ensureToolkit(); preferences.toolkit?.commandBarHotkey = hotkey
        try model.savePreferences(preferences)
        if let plugin = model.pluginHost.running[info.id] as? CommandBarPlugin { plugin.settings = settings; plugin.register() }
    }

    func save(_ change: (inout CommandBarSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        do {
            try context.save(next)
            settings = next
            mirror(); register()
        } catch { context.report(error) }
    }

    /// The table, seeded once from the legacy preferences when config.toml does not have it yet.
    static func settings(_ model: AppModel) -> CommandBarSettings {
        guard model.settingsFile.document.value(at: [info.id]) != nil else {
            let seeded = CommandBarSettings(legacy: model.configuration.preferences.toolkitSettings)
            try? model.settingsFile.update(info.id, seeded)
            return seeded
        }
        return (try? model.settingsFile.section(info.id, as: CommandBarSettings.self).value) ?? CommandBarSettings()
    }

    /// The rest of Frog still reads the shortcut and the learning switch from the legacy preferences: conflict
    /// checks, the shortcut reference and the choice store.
    private func mirror() {
        let toolkit = model.configuration.preferences.toolkitSettings
        guard toolkit.effectiveCommandBarHotkey != settings.shortcut.hotkey || toolkit.commandBarSettings.learnChoices != settings.learnChoices else { return }
        do {
            try model.updateToolkit { toolkit in
                toolkit.commandBarHotkey = settings.shortcut.hotkey
                var bar = toolkit.commandBarSettings; bar.learnChoices = settings.learnChoices; toolkit.commandBar = bar
            }
        } catch { context.report(error) }
    }

    private func register() {
        guard model.registerShortcuts, !model.isRecordingShortcut else { return }
        let rule = Rule(id: hotkeyID, name: "Command bar", hotkey: settings.shortcut.hotkey)
        let errors = hotkeys.register(rules: [rule], onPress: { [weak self] _ in self?.show() }) { _ in }
        shortcutIssue = errors[hotkeyID]
        model.objectWillChange.send()
    }

    func page() -> AnyView? { legacyPage(CommandBarSettingsView(plugin: self)) }

    var actions: [PluginAction] {
        [PluginAction(id: "command-bar.show", title: "Open the command bar", symbol: "magnifyingglass", surfaces: [.agent, .shortcut]) { [weak self] _ in
            self?.show(); return .done()
        },
         PluginAction(id: "command-bar.search", title: "Search like the command bar", symbol: "text.magnifyingglass",
                      parameters: [ActionParameter(name: "query", required: true, help: "What to type"),
                                   ActionParameter(name: "limit", kind: .integer, help: "At most this many rows, 20 by default")],
                      surfaces: [.agent]) { [weak self] input in
            guard let self else { throw ActionError.failed("The command bar is off.") }
            let rows = await self.search(try input.required("query"), limit: try input.integer("limit") ?? 20)
            return ActionResult(rows, text: rows.isEmpty ? "No results." : rows.map { "\($0.title) · \($0.subtitle)  [\($0.id)]" }.joined(separator: "\n"))
        }]
    }

    struct SearchRow: Encodable, Equatable {
        let id: String, title: String, subtitle: String
    }

    /// The rows the bar would list for `query`, ranked as it ranks them, from a bar of its own that never shows.
    func search(_ query: String, limit: Int) async -> [SearchRow] {
        let headless = CommandBar(model: model, pasteboard: NSPasteboard(name: .init("frog.command-bar.search")), captureTarget: { nil },
                                  fileSearch: NoCommandFileSearch())
        defer { headless.stop() }
        var installed = bar?.applications.installed ?? []
        if installed.isEmpty { installed = await ApplicationCatalogStore.shared.load() }
        headless.cacheApplications(installed)
        headless.prepareResults(model, frontPID: nil)
        headless.query = query
        return headless.results.prefix(max(1, limit)).map { SearchRow(id: $0.id, title: $0.title, subtitle: $0.subtitle) }
    }

    var menu: [MenuContribution] {
        [MenuContribution(id: "command-bar.open", order: 20) { [weak self] in
            AnyView(MenuActionRow(title: "Command bar", symbol: "magnifyingglass",
                                  key: HotkeyManager.display(self?.settings.shortcut.hotkey ?? CommandBarSettings.defaultShortcut.hotkey),
                                  closes: true) {
                self?.show()
            })
        }]
    }
}
