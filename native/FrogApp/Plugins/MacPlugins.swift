import AppKit
import SwiftUI
import FrogCore

final class StayAwakePlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "stay-awake", name: "Stay awake", symbol: "cup.and.saucer", tint: .orange, category: .system,
                                 summary: "Keep the Mac and its screen awake", enabledByDefault: true, recommended: true)
    func page() -> AnyView? { legacyPage(StayAwakeView(power: model.power)) }
    var actions: [PluginAction] {
        [PluginAction(id: "stay-awake.toggle", title: "Stay awake on or off", symbol: "cup.and.saucer", keywords: "caffeinate sleep awake") { [model] _ in
            model.power.setEnabled(!model.power.isEnabled)
            await model.power.waitForOperation()
            return .done(model.power.isEnabled ? "Stay awake is on." : "Stay awake is off.")
        }]
    }
    var menu: [MenuContribution] {
        [MenuContribution(id: "stay-awake.switch", order: 0) { [model] in AnyView(StayAwakeMenuRow(power: model.power)) }]
    }
}

final class HiddenBarPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "hidden-bar", name: "Hidden bar", symbol: "menubar.rectangle", tint: .gray, category: .system,
                                 summary: "Tuck menu-bar icons out of sight")
    func page() -> AnyView? {
        legacyPage(MenuBarSettingsView(organizer: model.toolkit.menuBarOrganizer, settings: Binding(
            get: { [model] in model.configuration.preferences.toolkitSettings.menuBar ?? MenuBarPreferences() },
            set: { [model] value in
                do { try model.updateToolkit { $0.menuBar = value.normalized } } catch { model.report(error) }
            })))
    }
    var menu: [MenuContribution] {
        [MenuContribution(id: "hidden-bar.notice", order: 50) { [model] in
            AnyView(MenuBarOrganizerNotice(organizer: model.toolkit.menuBarOrganizer))
        }]
    }
}

final class AppCleanerPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "app-cleaner", name: "App cleaner", symbol: "trash", tint: .red, category: .system,
                                 summary: "Remove apps with what they leave behind")
    func page() -> AnyView? { legacyPage(CleanerView(cleaner: model.cleaner)) }
}
