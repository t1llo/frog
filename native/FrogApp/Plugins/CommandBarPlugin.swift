import AppKit
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
/// stops. Its rows come from providers, the plugins' among them. The shortcut registers through Frog's own, so
/// recording a shortcut anywhere lets it go and the end of recording registers the latest one.
final class CommandBarPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "command-bar", name: "Command bar", symbol: "magnifyingglass", tint: .indigo, category: .navigate,
                                 summary: "Find apps, files and actions", recommended: true)
    static let shortcutID = UUID(uuidString: "76B6A364-18CC-4779-9552-9885FCE778B8")!

    private(set) var bar: CommandBar?
    private(set) var settings = CommandBarSettings()
    /// Set when `[command-bar]` could not be read: the settings are the last good ones, and nothing is mirrored.
    private(set) var unreadable: String?
    /// Why the shortcut could not be registered, such as another app holding it.
    var shortcutIssue: String? { model.hotkeyErrors[Self.shortcutID] }

    func start() async {
        load()
        let bar = CommandBar(model: model, pasteboard: model.clipboardHistoryStore.pasteboard)
        bar.onToolUse = { [weak model] in model?.statistics.recordToolUse($0) }
        self.bar = bar
        register()
        // Tests make many models; only the app's own builds the panel and reads the apps ahead of the first open.
        if model.registerShortcuts { bar.warm() }
    }

    func stop() async {
        model.setPluginShortcut(Self.shortcutID, name: info.name, hotkey: nil)
        bar?.stop(); bar = nil
    }

    func settingsChanged() {
        let previous = settings
        load()
        if settings != previous { register() }
    }

    func show() {
        guard !model.isRecordingShortcut else { return }
        bar?.show()
    }
    func hide() { bar?.hide() }

    /// Saves a new shortcut and turns the bar on. First-run setup uses it for ⌘Space; saving the same shortcut
    /// again registers it again, since it may just have been freed in System Settings.
    static func useShortcut(_ hotkey: Hotkey, model: AppModel) throws {
        let running = model.pluginHost.running[info.id] as? CommandBarPlugin
        try model.checkShortcutFree(hotkey, except: [shortcutID])
        var settings = running?.settings ?? read(model) ?? CommandBarSettings(legacy: model.configuration.preferences.toolkitSettings)
        settings.shortcut = try Shortcut(hotkey)
        try model.settingsFile.update(info.id, settings)
        try model.settingsFile.setPlugin(info.id, enabled: true)
        var preferences = model.configuration.preferences
        preferences.setFeature(.commandBar, enabled: true)
        preferences.ensureToolkit(); preferences.toolkit?.commandBarHotkey = hotkey
        try model.savePreferences(preferences)
        if let running { running.settings = settings; running.unreadable = nil; running.register() }
    }

    func save(_ change: (inout CommandBarSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        do {
            if next.shortcut != settings.shortcut {
                if let issue = HotkeyManager.validationError(next.shortcut.hotkey) { throw FrogError.message(issue) }
                try model.checkShortcutFree(next.shortcut.hotkey, except: [Self.shortcutID])
            }
            try context.save(next)
            settings = next; unreadable = nil
            mirror(); register()
        } catch { context.report(error) }
    }

    private func load() {
        if let next = Self.read(model) {
            settings = next; unreadable = nil
            mirror()
        } else if bar == nil {
            // Nothing was read yet: the legacy preferences hold the shortcut the bar last mirrored.
            settings = CommandBarSettings(legacy: model.configuration.preferences.toolkitSettings)
            unreadable = Self.unreadableNote
        } else {
            unreadable = Self.unreadableNote
        }
    }
    private static let unreadableNote = "config.toml [command-bar] could not be read, so the bar keeps its last settings."

    /// The table, or nil when it does not decode (the error is reported). A config.toml without the table is seeded
    /// from the legacy preferences, but not while Frog's settings could not be loaded, when those are only defaults.
    static func read(_ model: AppModel) -> CommandBarSettings? {
        guard model.settingsFile.document.value(at: [info.id]) != nil else {
            let seeded = CommandBarSettings(legacy: model.configuration.preferences.toolkitSettings)
            if model.configurationLoaded {
                do { try model.settingsFile.update(info.id, seeded) } catch { model.report(error) }
            }
            return seeded
        }
        do {
            let result = try model.settingsFile.section(info.id, as: CommandBarSettings.self)
            for warning in result.warnings { model.report(FrogError.message("config.toml line \(warning.line): \(warning.message)")) }
            return result.value
        } catch {
            model.report(error)
            return nil
        }
    }

    /// The old preferences are still written by `frog config set shortcut.command-bar`, `command-bar.learn-choices`
    /// and imports. What changed there goes into `[command-bar]`, which the bar reads.
    static func adoptLegacy(_ model: AppModel, previous: Preferences) {
        let before = CommandBarSettings(legacy: previous.toolkitSettings)
        let after = CommandBarSettings(legacy: model.configuration.preferences.toolkitSettings)
        guard before != after else { return }
        let running = model.pluginHost.running[info.id] as? CommandBarPlugin
        guard let current = running?.settings ?? read(model) else { return }
        var settings = current
        if before.shortcut != after.shortcut { settings.shortcut = after.shortcut }
        if before.learnChoices != after.learnChoices { settings.learnChoices = after.learnChoices }
        // The bar's own mirror writes what it already has.
        guard settings != current else { return }
        do { try model.settingsFile.update(info.id, settings) } catch { model.report(error); return }
        if let running { running.settings = settings; running.unreadable = nil; running.register() }
    }

    /// The rest of Frog still reads the shortcut and the learning switch from the legacy preferences: conflict
    /// checks, the shortcut reference and the choice store.
    private func mirror() {
        guard unreadable == nil, model.configurationLoaded else { return }
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
        model.setPluginShortcut(Self.shortcutID, name: info.name, hotkey: settings.shortcut.hotkey) { [weak self] in self?.show() }
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
        headless.opensPluginProviders = false
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
