import AppKit
import SwiftUI
import FrogCore

final class CommandBarPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "command-bar", name: "Command bar", symbol: "magnifyingglass", tint: .indigo, category: .navigate,
                                 summary: "Find apps, files and actions", recommended: true)
    func page() -> AnyView? { legacyPage(CommandBarSettingsView()) }
    var actions: [PluginAction] {
        [PluginAction(id: "command-bar.show", title: "Open the command bar", symbol: "magnifyingglass", surfaces: [.agent, .shortcut]) { [model] _ in
            model.showCommandBar(); return .done()
        }]
    }
    var menu: [MenuContribution] {
        [MenuContribution(id: "command-bar.open", order: 20) { [model] in
            AnyView(MenuActionRow(title: "Command bar", symbol: "magnifyingglass",
                                  key: HotkeyManager.display(model.configuration.preferences.toolkitSettings.effectiveCommandBarHotkey),
                                  closes: true) {
                model.showCommandBar()
            })
        }]
    }
}
