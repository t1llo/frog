import AppKit
import SwiftUI
import FrogCore

/// Every built-in plugin, in sidebar order within each category.
enum BuiltinPlugins {
    @MainActor static var all: [PluginDescriptor] {
        [
            PluginDescriptor(WritingPlugin.self) { WritingPlugin(context: $0) },
            PluginDescriptor(ExplainPlugin.self) { ExplainPlugin(context: $0) },
            PluginDescriptor(DictationPlugin.self) { DictationPlugin(context: $0) },
            PluginDescriptor(HistoryPlugin.self) { HistoryPlugin(context: $0) },
            PluginDescriptor(CommandBarPlugin.self) { CommandBarPlugin(context: $0) },
            PluginDescriptor(ShortcutsPlugin.self) { ShortcutsPlugin(context: $0) },
            PluginDescriptor(ClipboardPlugin.self) { ClipboardPlugin(context: $0) },
            PluginDescriptor(NotesPlugin.self) { NotesPlugin(context: $0) },
            PluginDescriptor(ScriptsPlugin.self) { ScriptsPlugin(context: $0) },
            PluginDescriptor(WindowsPlugin.self) { WindowsPlugin(context: $0) },
            PluginDescriptor(WindowSwitcherPlugin.self) { WindowSwitcherPlugin(context: $0) },
            PluginDescriptor(SystemMonitorPlugin.self) { SystemMonitorPlugin(context: $0) },
            PluginDescriptor(LLMUsagePlugin.self) { LLMUsagePlugin(context: $0) },
            PluginDescriptor(StayAwakePlugin.self) { StayAwakePlugin(context: $0) },
            PluginDescriptor(HiddenBarPlugin.self) { HiddenBarPlugin(context: $0) },
            PluginDescriptor(AppCleanerPlugin.self) { AppCleanerPlugin(context: $0) },
            PluginDescriptor(PhonePlugin.self) { PhonePlugin(context: $0) },
            PluginDescriptor(CommunityPlugin.self) { CommunityPlugin(context: $0) }
        ]
    }

    /// The feature switch each plugin used before plugins existed; on and off still live there until each plugin
    /// keeps its own settings.
    static let legacyFeatures: [String: FeatureID] = [
        "writing": .writing, "explain": .explain, "dictation": .dictation, "command-bar": .commandBar,
        "shortcuts": .applicationShortcuts, "clipboard": .clipboard, "notes": .scratchpad, "scripts": .scripts,
        "windows": .windows, "window-switcher": .windowSwitcher, "system-monitor": .systemMonitor,
        "llm-usage": .usage, "stay-awake": .stayAwake, "hidden-bar": .menuBar, "app-cleaner": .cleaner,
        "phone": .phone, "community": .plugins
    ]

    static func pluginID(for feature: FeatureID) -> String {
        legacyFeatures.first { $0.value == feature }?.key ?? feature.rawValue
    }
}

/// A plugin whose work still runs in `AppModel`; it adds the page, actions and menu rows on top.
@MainActor class LegacyPlugin {
    let context: PluginContext
    var model: AppModel { context.legacy }
    init(context: PluginContext) { self.context = context }

    func legacyPage<Page: View>(_ page: Page) -> AnyView { AnyView(page.environmentObject(model)) }
}
