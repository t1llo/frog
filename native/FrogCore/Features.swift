import Foundation

/// Stable identities shared by configuration, navigation and command routing.
public enum FeatureID: String, Codable, CaseIterable, Identifiable, Sendable {
    case writing, dictation, applicationShortcuts, windowSwitcher, clipboard, stayAwake
    case commandBar, usage, snippets, scratchpad, shelf, scripts, quickActions, menuBar
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .writing: "Writing"
        case .dictation: "Dictation"
        case .applicationShortcuts: "Shortcuts"
        case .windowSwitcher: "Windows"
        case .clipboard: "Clipboard"
        case .stayAwake: "Stay awake"
        case .commandBar: "Command bar"
        case .usage: "Mr. Usage"
        case .snippets: "Snippets"
        case .scratchpad: "Notes"
        case .shelf: "Shelf"
        case .scripts: "Scripts"
        case .quickActions: "Quick actions"
        case .menuBar: "Menu bar"
        }
    }
    public var symbol: String {
        switch self {
        case .writing: "text.cursor"
        case .dictation: "waveform"
        case .applicationShortcuts: "command"
        case .windowSwitcher: "macwindow.on.rectangle"
        case .clipboard: "clipboard"
        case .stayAwake: "cup.and.saucer"
        case .commandBar: "magnifyingglass"
        case .usage: "chart.bar.xaxis"
        case .snippets: "text.badge.plus"
        case .scratchpad: "note.text"
        case .shelf: "tray"
        case .scripts: "terminal"
        case .quickActions: "bolt"
        case .menuBar: "menubar.rectangle"
        }
    }
    public var detail: String {
        switch self {
        case .writing: "Rewrite selected text with your rules and local or connected models."
        case .dictation: "Turn speech into text with local or connected speech models."
        case .applicationShortcuts: "Launch applications and run window or system actions."
        case .windowSwitcher: "Search and switch individual windows with Command–Tab."
        case .clipboard: "Search and paste recent clipboard items kept in memory."
        case .stayAwake: "Keep background work running on a timed, opt-in session."
        case .commandBar: "Search applications, windows, files and Frog commands from anywhere."
        case .usage: "View plan limits, token activity and estimated costs from your AI tools."
        case .snippets: "Keep reusable text with date, time and clipboard variables."
        case .scratchpad: "Write local notes with Markdown preview."
        case .shelf: "Keep files, links and text ready for your next drag or copy."
        case .scripts: "Save and explicitly run local shell scripts with captured output."
        case .quickActions: "Common Mac actions and useful text tools in one place."
        case .menuBar: "Keep menu bar items behind a divider and reveal them when needed."
        }
    }
}

public struct ToolkitPreferences: Codable, Equatable, Sendable {
    public var enabled: [String: Bool] = [:]
    public var hiddenSidebarItems: Set<String> = []
    public var commandBarHotkey: Hotkey?
    public var usage: UsageDisplayPreferences?
    public var menuBar: MenuBarPreferences?
    public var effectiveCommandBarHotkey: Hotkey { commandBarHotkey ?? Hotkey(keyCode: 49, modifiers: 4096 | 2048) }
    public init() {}
    private enum CodingKeys: String, CodingKey { case enabled, hiddenSidebarItems, commandBarHotkey, usage, menuBar }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent([String: Bool].self, forKey: .enabled) ?? [:]
        hiddenSidebarItems = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenSidebarItems) ?? []
        commandBarHotkey = try values.decodeIfPresent(Hotkey.self, forKey: .commandBarHotkey)
        usage = try values.decodeIfPresent(UsageDisplayPreferences.self, forKey: .usage)
        menuBar = try values.decodeIfPresent(MenuBarPreferences.self, forKey: .menuBar)
    }
}

/// Display preferences only; accounts, credentials, readings and polling gates are machine-local.
public struct UsageDisplayPreferences: Codable, Equatable, Sendable {
    public var provider: String
    public var range: String
    public var metric: String
    public var allDevices: Bool
    public var loginSource: String
    public init(provider: String = "Claude", range: String = "7d", metric: String = "API cost", allDevices: Bool = false, loginSource: String = "Automatic") {
        self.provider = provider; self.range = range; self.metric = metric
        self.allDevices = allDevices; self.loginSource = loginSource
    }
}

extension Preferences {
    public var toolkitSettings: ToolkitPreferences { toolkit ?? ToolkitPreferences() }
    public func featureEnabled(_ feature: FeatureID) -> Bool {
        switch feature {
        // These existing controls remain canonical rather than a second copy of the setting.
        case .applicationShortcuts: shortcutsEnabled
        case .windowSwitcher: windowSwitcherEnabled && (toolkit != nil || shortcutsEnabled)
        case .clipboard: workflowSettings.clipboardHistoryEnabled == true
        case .writing, .dictation, .stayAwake: toolkitSettings.enabled[feature.rawValue] ?? true
        default: toolkitSettings.enabled[feature.rawValue] ?? false
        }
    }
    public mutating func setFeature(_ feature: FeatureID, enabled: Bool) {
        if toolkit == nil {
            windowSwitcherEnabled = windowSwitcherEnabled && shortcutsEnabled
            toolkit = ToolkitPreferences()
        }
        switch feature {
        case .applicationShortcuts: applicationShortcutsEnabled = enabled
        case .windowSwitcher: windowSwitcherEnabled = enabled
        case .clipboard:
            var settings = workflowSettings; settings.clipboardHistoryEnabled = enabled; workflows = settings
        default: toolkit?.enabled[feature.rawValue] = enabled
        }
    }
    public var sidebarFeatures: [FeatureID] {
        FeatureID.allCases.filter { featureEnabled($0) && !toolkitSettings.hiddenSidebarItems.contains($0.rawValue) }
    }
}

public enum ToolkitRoute: Hashable, Sendable {
    case feature(FeatureID), history, models, features, settings, statistics
    public func available(in preferences: Preferences) -> Bool {
        guard case .feature(let feature) = self else { return true }
        return preferences.featureEnabled(feature)
    }
}
