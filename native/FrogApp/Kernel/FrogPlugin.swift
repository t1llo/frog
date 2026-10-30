import FrogCore
import SwiftUI

/// A feature of Frog. The host creates a plugin when it is turned on, calls `start()`, and calls `stop()` and
/// drops it when it is turned off or Frog quits. Everything else is optional.
@MainActor protocol FrogPlugin: AnyObject {
    static var info: PluginInfo { get }
    /// Begin work: register shortcuts, monitors and status items. Keep it cheap; load heavy things on first use.
    func start() async
    /// Undo everything `start` did. After it returns the plugin holds no monitors, timers or menu-bar items.
    func stop() async
    /// What it can do, for the command bar, shortcuts, the menu bar and agents.
    var actions: [PluginAction] { get }
    /// Its page in the main window. Nil for a plugin without settings.
    func page() -> AnyView?
    /// Rows or a tab for the Frog menu-bar popup.
    var menu: [MenuContribution] { get }
    /// Its table in config.toml changed, from Frog or from an editor. Read it again with `context.settings`.
    func settingsChanged()
}

extension FrogPlugin {
    func start() async {}
    func stop() async {}
    var actions: [PluginAction] { [] }
    func page() -> AnyView? { nil }
    var menu: [MenuContribution] { [] }
    func settingsChanged() {}
    var info: PluginInfo { Self.info }
}

/// A piece of the Frog menu-bar popup.
struct MenuContribution: Identifiable {
    enum Placement: Equatable {
        /// A control in the popup's main list, such as the Stay awake switch.
        case row
        /// A tab beside Frog's own, such as System or Usage.
        case tab(title: String, symbol: String)
    }
    let id: String
    var placement: Placement = .row
    /// Lower comes first.
    var order = 100
    let content: @MainActor () -> AnyView

    var tabTitle: String? {
        if case .tab(let title, _) = placement { return title }
        return nil
    }
}

/// How a built-in plugin is made, so the host can list it before it exists.
struct PluginDescriptor: Identifiable {
    let info: PluginInfo
    let make: @MainActor (PluginContext) -> any FrogPlugin
    var id: String { info.id }

    @MainActor init<Plugin: FrogPlugin>(_ type: Plugin.Type, make: @escaping @MainActor (PluginContext) -> Plugin) {
        info = type.info
        self.make = { make($0) }
    }
}

/// What a plugin may use. Plugins reach shared services through it, never through each other.
@MainActor final class PluginContext {
    let info: PluginInfo
    unowned let host: PluginHost
    /// The app model the features were built on. Plugins move off it one at a time; new code should not reach for it.
    unowned let legacy: AppModel

    init(info: PluginInfo, host: PluginHost, legacy: AppModel) {
        self.info = info; self.host = host; self.legacy = legacy
    }

    /// This plugin's table in config.toml, `[<plugin id>]`; defaults for keys that are missing, with a warning
    /// reported for each value that could not be read.
    func settings<Section: ConfigSection>(_ type: Section.Type = Section.self) -> Section {
        do {
            let result = try legacy.settingsFile.section(info.id, as: type)
            for warning in result.warnings { legacy.report(FrogError.message("config.toml line \(warning.line): \(warning.message)")) }
            return result.value
        } catch {
            report(error)
            return Section()
        }
    }

    /// Writes this plugin's table, keeping the comments and spelling of everything it does not change.
    func save<Section: ConfigSection>(_ settings: Section) throws {
        try legacy.settingsFile.update(info.id, settings)
    }

    /// Shows this plugin's page in the main window.
    func openPage() { host.open(info.id) }
    func report(_ error: Error) { legacy.report(error) }
}
