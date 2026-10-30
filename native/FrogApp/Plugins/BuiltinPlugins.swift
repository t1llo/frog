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

// MARK: Write

final class WritingPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "writing", name: "Writing", symbol: "text.cursor", tint: .green, category: .write,
                                 summary: "Rewrite selected text with your rules", enabledByDefault: true,
                                 permissions: [.accessibility], recommended: true)
    func page() -> AnyView? { legacyPage(RulesView(fixedCategory: .text)) }
    var actions: [PluginAction] {
        model.configuration.rules.filter { $0.enabled && $0.category == .text && !$0.answersInPanel }.map { rule in
            PluginAction(id: "writing.\(Self.slug(rule.name))", title: rule.name, symbol: "text.cursor",
                         keywords: "writing rule", surfaces: [.agent]) { [model] _ in
                model.runRuleFromCommandBar(rule.id)
                return .done("Running \(rule.name) on the selected text.")
            }
        }
    }
    static func slug(_ name: String) -> String {
        name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
    }
}

final class ExplainPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "explain", name: "Explain", symbol: "questionmark.bubble", tint: .teal, category: .write,
                                 summary: "Ask about selected text", permissions: [.accessibility])
    func page() -> AnyView? { legacyPage(ExplainView()) }
}

final class DictationPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "dictation", name: "Dictation", symbol: "waveform", tint: .red, category: .write,
                                 summary: "Speak instead of typing", enabledByDefault: true,
                                 permissions: [.microphone, .accessibility], recommended: true)
    func page() -> AnyView? {
        legacyPage(RulesView(fixedCategory: .audio, output: .replace) { RecordingSettingsView() })
    }
    var actions: [PluginAction] {
        [PluginAction(id: "dictation.toggle", title: "Start or stop dictation", symbol: "waveform", keywords: "record speak voice") { [model] _ in
            if model.dictation.active { model.dictation.stop(models: model.localModels); return .done("Stopped recording.") }
            guard let rule = model.configuration.rules.first(where: { $0.enabled && $0.category == .audio }) else {
                throw ActionError.failed("Add a dictation rule first.")
            }
            model.startDictation(rule)
            return .done("Recording with \(rule.name).")
        },
         PluginAction(id: "dictation.cancel", title: "Cancel dictation", symbol: "xmark", surfaces: [.agent, .shortcut]) { [model] _ in
            model.dictation.interrupt()
            return .done("Cancelled.")
        }]
    }
    var menu: [MenuContribution] {
        [MenuContribution(id: "dictation.recording", order: 10) { [model] in
            AnyView(DictationMenuRows(dictation: model.dictation, models: model.localModels))
        }]
    }
}

private struct DictationMenuRows: View {
    @ObservedObject var dictation: DictationController
    let models: LocalModels
    var body: some View {
        if dictation.active {
            if dictation.phase == .recording {
                MenuActionRow(title: "Stop recording", symbol: "stop.fill") { dictation.stop(models: models) }
            }
            MenuActionRow(title: "Cancel recording", symbol: "xmark") { dictation.interrupt() }
        }
    }
}

final class HistoryPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "history", name: "History", symbol: "clock.arrow.circlepath", tint: .gray, category: .write,
                                 summary: "Earlier results of your rules")
    func page() -> AnyView? { legacyPage(HistoryView()) }
}

// MARK: Find & launch

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

final class ShortcutsPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "shortcuts", name: "Shortcuts", symbol: "command", tint: .blue, category: .navigate,
                                 summary: "Keys that open apps and run actions", enabledByDefault: true, recommended: true)
    func page() -> AnyView? { legacyPage(RulesView(applications: true)) }
    var actions: [PluginAction] {
        [PluginAction(id: "shortcuts.open-app", title: "Open an app", symbol: "app",
                      parameters: [ActionParameter(name: "app", required: true, help: "The app's name or bundle ID")],
                      surfaces: [.agent]) { input in
            let name = try input.required("app")
            let workspace = NSWorkspace.shared
            let url = workspace.urlForApplication(withBundleIdentifier: name)
                ?? ["/Applications", "/System/Applications", "/System/Applications/Utilities"].lazy
                    .map { URL(fileURLWithPath: $0).appendingPathComponent(name.hasSuffix(".app") ? name : name + ".app") }
                    .first { FileManager.default.fileExists(atPath: $0.path) }
            guard let url else { throw ActionError.failed("No app named \(name).") }
            _ = try await workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return .done("Opened \(url.deletingPathExtension().lastPathComponent).")
        }]
    }
}

final class ClipboardPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "clipboard", name: "Clipboard", symbol: "doc.on.clipboard", tint: .orange, category: .navigate,
                                 summary: "Search and paste what you copied", recommended: true)
    func page() -> AnyView? { legacyPage(ClipboardView()) }
    var actions: [PluginAction] {
        [PluginAction(id: "clipboard.show", title: "Clipboard history", symbol: "doc.on.clipboard", surfaces: [.commandBar, .shortcut, .agent]) { [model] _ in
            model.showClipboardHistory(); return .done()
        }]
    }
    var menu: [MenuContribution] {
        [MenuContribution(id: "clipboard.open", order: 21) { [model] in
            AnyView(MenuActionRow(title: "Clipboard history", symbol: "clipboard",
                                  key: HotkeyManager.display(model.configuration.preferences.workflowSettings.effectiveClipboardHistoryHotkey),
                                  closes: true) {
                model.showClipboardHistory()
            })
        }]
    }
}

final class NotesPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "notes", name: "Notes", symbol: "note.text", tint: .yellow, category: .navigate,
                                 summary: "Markdown notes and text to paste")
    func page() -> AnyView? { legacyPage(UtilityDocumentsView(documents: model.documents, kind: .note)) }
}

final class ScriptsPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "scripts", name: "Scripts", symbol: "terminal", tint: .gray, category: .navigate,
                                 summary: "Run your shell scripts")
    func page() -> AnyView? { legacyPage(UtilityDocumentsView(documents: model.documents, kind: .script)) }
}

// MARK: Windows

final class WindowsPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "windows", name: "Windows", symbol: "rectangle.split.2x1", tint: .purple, category: .windows,
                                 summary: "Snap and tile windows with keys", permissions: [.accessibility], recommended: true)
    func page() -> AnyView? { legacyPage(WindowsView()) }
    var actions: [PluginAction] {
        WindowAction.allCases.map { action in
            PluginAction(id: "windows.\(WritingPlugin.slug(action.title))", title: action.title, symbol: "rectangle.split.2x1",
                         keywords: "window layout move resize", surfaces: [.shortcut, .agent]) { [model] _ in
                model.runWindowAction(action); return .done()
            }
        }
    }
    var menu: [MenuContribution] {
        [MenuContribution(id: "windows.arrange", order: 40) { [model] in
            guard model.windowLayout.pickerAvailable else { return AnyView(EmptyView()) }
            return AnyView(MenuActionRow(title: "Arrange window…", symbol: "rectangle.split.2x1", closes: true) {
                model.windowLayout.handle(.layoutPicker, pressed: true)
            })
        }]
    }
}

final class WindowSwitcherPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "window-switcher", name: "Window switcher", symbol: "macwindow.on.rectangle", tint: .indigo,
                                 category: .windows, summary: "Switch between windows, not apps", enabledByDefault: true,
                                 permissions: [.accessibility], recommended: true)
    func page() -> AnyView? { legacyPage(WindowSwitcherView()) }
}

// MARK: Monitor & Mac

final class SystemMonitorPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "system-monitor", name: "System monitor", symbol: "gauge.medium", tint: .teal, category: .system,
                                 summary: "CPU, GPU, memory and battery")
    func page() -> AnyView? { legacyPage(SystemMonitorPage(monitor: model.systemMonitor)) }
    var menu: [MenuContribution] {
        [MenuContribution(id: "system-monitor.tab", placement: .tab(title: "System", symbol: "gauge.medium"), order: 10) { [model] in
            AnyView(SystemMonitorView(monitor: model.systemMonitor, presenter: .frogMenu))
        }]
    }
}

final class LLMUsagePlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "llm-usage", name: "LLM usage", symbol: "chart.bar.xaxis", tint: .pink, category: .system,
                                 summary: "Claude and Codex limits at a glance")
    func page() -> AnyView? {
        guard let usage = model.toolkit.usage() else { return nil }
        return legacyPage(UsageDashboardView(usage: usage))
    }
    var menu: [MenuContribution] {
        [MenuContribution(id: "llm-usage.tab", placement: .tab(title: "Usage", symbol: "chart.bar.xaxis"), order: 20) { [model, context] in
            guard let usage = model.toolkit.usage() else { return AnyView(EmptyView()) }
            return AnyView(UsageStatusPopover(usage: usage, openDashboard: { context.openPage() },
                                              signIn: { ClaudeSignIn.start(usage) }))
        }]
    }
}

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

// MARK: Devices and community

final class PhonePlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "phone", name: "Phone", symbol: "iphone", tint: .green, category: .devices,
                                 summary: "Share the clipboard with your phone",
                                 permissions: [.localNetwork, .bluetooth, .notifications])
    func page() -> AnyView? { legacyPage(PhoneView()) }
    var menu: [MenuContribution] {
        [MenuContribution(id: "phone.status", order: 30) { [model, context] in
            guard let phone = model.phone else { return AnyView(EmptyView()) }
            return AnyView(PhoneMenuRow(phone: phone) { context.openPage() })
        }]
    }
}

final class CommunityPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "community", name: "Community plugins", symbol: "puzzlepiece.extension", tint: .purple,
                                 category: .community, summary: "Plugins you build or install")
    func page() -> AnyView? { legacyPage(PluginsView(plugins: model.plugins)) }
}
