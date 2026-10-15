import Foundation

/// Stable identities shared by configuration, navigation and command routing.
public enum FeatureID: String, Codable, CaseIterable, Identifiable, Sendable {
    case writing
    // slot: explain
    case dictation
    case applicationShortcuts
    case windowSwitcher
    case clipboard
    case stayAwake
    case commandBar
    case usage
    case snippets
    case scratchpad
    case shelf
    case scripts
    case quickActions
    case menuBar
    case systemMonitor
    // slot: windows
    // slot: cleaner
    // slot: emoji-picker
    // slot: processes
    // slot: color-picker
    // slot: quicklinks
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .writing: "Writing"
        case .dictation: "Dictation"
        case .applicationShortcuts: "Shortcuts"
        case .windowSwitcher: "Window switcher"
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
        case .systemMonitor: "System monitor"
        // slot: explain
        // slot: windows
        // slot: cleaner
        // slot: emoji-picker
        // slot: processes
        // slot: color-picker
        // slot: quicklinks
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
        case .systemMonitor: "gauge.medium"
        // slot: explain
        // slot: windows
        // slot: cleaner
        // slot: emoji-picker
        // slot: processes
        // slot: color-picker
        // slot: quicklinks
        }
    }
    public var detail: String {
        switch self {
        case .writing: "Rewrite selected text with your rules and local or connected models."
        case .dictation: "Turn speech into text with local or connected speech models."
        case .applicationShortcuts: "Launch applications and run window or system actions."
        case .windowSwitcher: "Switch between individual windows with your keyboard."
        case .clipboard: "Search and paste recent clipboard items kept in memory."
        case .stayAwake: "Keep background work running on a timed, opt-in session."
        case .commandBar: "Search applications, files, macOS settings, windows and Frog commands."
        case .usage: "View plan limits, token activity and estimated costs from your AI tools."
        case .snippets: "Keep reusable text with date, time and clipboard variables."
        case .scratchpad: "Write local notes with Markdown preview."
        case .shelf: "Keep files, links and text ready for your next drag or copy."
        case .scripts: "Save and explicitly run local shell scripts with captured output."
        case .quickActions: "Common Mac actions and useful text tools in one place."
        case .menuBar: "Keep menu bar items behind a divider and reveal them when needed."
        case .systemMonitor: "See CPU, GPU, disk and power activity in the Frog menu."
        // slot: explain
        // slot: windows
        // slot: cleaner
        // slot: emoji-picker
        // slot: processes
        // slot: color-picker
        // slot: quicklinks
        }
    }

    /// Small background tools are configured in Features rather than separate pages.
    public var hasPage: Bool {
        switch self {
        case .windowSwitcher: false
        case .clipboard: false
        case .systemMonitor: false
        // slot: explain
        // slot: windows
        // slot: cleaner
        // slot: emoji-picker
        // slot: processes
        // slot: color-picker
        // slot: quicklinks
        default: true
        }
    }
}

public struct ToolkitPreferences: Codable, Equatable, Sendable {
    public var enabled: [String: Bool] = [:]
    public var hiddenSidebarItems: Set<String> = []
    public var commandBarHotkey: Hotkey?
    public var windowSwitcherHotkey: Hotkey?
    public var usage: UsageDisplayPreferences?
    public var menuBar: MenuBarPreferences?
    // slot: explain
    // slot: windows
    // slot: cleaner
    // slot: command-bar
    public var commandBar: CommandBarPreferences?
    public var commandBarSettings: CommandBarPreferences { commandBar ?? CommandBarPreferences() }
    // slot: clipboard
    // slot: snippets
    // slot: emoji-picker
    // slot: color-picker
    // slot: quicklinks
    public var effectiveCommandBarHotkey: Hotkey { commandBarHotkey ?? Hotkey(keyCode: 49, modifiers: 4096 | 2048) }
    public var effectiveWindowSwitcherHotkey: Hotkey { windowSwitcherHotkey ?? Hotkey(keyCode: 48, modifiers: 256) }
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case enabled
        case hiddenSidebarItems
        case commandBarHotkey
        case windowSwitcherHotkey
        case usage
        case menuBar
        // slot: explain
        // slot: windows
        // slot: cleaner
        // slot: command-bar
        case commandBar
        // slot: clipboard
        // slot: snippets
        // slot: emoji-picker
        // slot: color-picker
        // slot: quicklinks
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent([String: Bool].self, forKey: .enabled) ?? [:]
        hiddenSidebarItems = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenSidebarItems) ?? []
        commandBarHotkey = try values.decodeIfPresent(Hotkey.self, forKey: .commandBarHotkey)
        windowSwitcherHotkey = try values.decodeIfPresent(Hotkey.self, forKey: .windowSwitcherHotkey)
        usage = try values.decodeIfPresent(UsageDisplayPreferences.self, forKey: .usage)
        menuBar = try values.decodeIfPresent(MenuBarPreferences.self, forKey: .menuBar)
        // slot: explain
        // slot: windows
        // slot: cleaner
        // slot: command-bar
        commandBar = try values.decodeIfPresent(CommandBarPreferences.self, forKey: .commandBar)
        // slot: clipboard
        // slot: snippets
        // slot: emoji-picker
        // slot: color-picker
        // slot: quicklinks
    }
}

/// Display preferences only; accounts, credentials, readings and polling gates are machine-local.
public struct UsageDisplayPreferences: Codable, Equatable, Sendable {
    public var provider: String
    public var range: String
    public var metric: String
    public var allDevices: Bool
    public var loginSource: String
    /// Shows each Claude account found on this Mac instead of one.
    public var claudeAccounts: Bool
    /// "each" or "combined".
    public var claudeAccountsView: String
    /// The window the menu bar shows per account: "session" or "week".
    public var claudeAccountsMenuBar: String
    public init(provider: String = "Claude", range: String = "7d", metric: String = "API cost", allDevices: Bool = false, loginSource: String = "Automatic",
                claudeAccounts: Bool = false, claudeAccountsView: String = "each", claudeAccountsMenuBar: String = "session") {
        self.provider = provider; self.range = range; self.metric = metric
        self.allDevices = allDevices; self.loginSource = loginSource
        self.claudeAccounts = claudeAccounts; self.claudeAccountsView = claudeAccountsView
        self.claudeAccountsMenuBar = claudeAccountsMenuBar
    }

    private enum CodingKeys: String, CodingKey {
        case provider, range, metric, allDevices, loginSource, claudeAccounts, claudeAccountsView, claudeAccountsMenuBar
    }

    /// Files written before a field existed load with that field's default.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        provider = try values.decodeIfPresent(String.self, forKey: .provider) ?? defaults.provider
        range = try values.decodeIfPresent(String.self, forKey: .range) ?? defaults.range
        metric = try values.decodeIfPresent(String.self, forKey: .metric) ?? defaults.metric
        allDevices = try values.decodeIfPresent(Bool.self, forKey: .allDevices) ?? defaults.allDevices
        loginSource = try values.decodeIfPresent(String.self, forKey: .loginSource) ?? defaults.loginSource
        claudeAccounts = try values.decodeIfPresent(Bool.self, forKey: .claudeAccounts) ?? defaults.claudeAccounts
        claudeAccountsView = try values.decodeIfPresent(String.self, forKey: .claudeAccountsView) ?? defaults.claudeAccountsView
        claudeAccountsMenuBar = try values.decodeIfPresent(String.self, forKey: .claudeAccountsMenuBar) ?? defaults.claudeAccountsMenuBar
    }

    public func validate() throws {
        guard ["each", "combined"].contains(claudeAccountsView) else {
            throw FrogError.message("Choose each or combined for Claude accounts.")
        }
        guard ["session", "week"].contains(claudeAccountsMenuBar) else {
            throw FrogError.message("Choose session or week for the Claude accounts menu bar item.")
        }
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
    /// Until the window switcher became a feature of its own, preferences had no `toolkit` and the
    /// switcher ran only while Shortcuts was on. Preferences from then keep a switcher that was off in
    /// effect off, and gain `toolkit`, so that the next save records that this was done.
    mutating func separateWindowSwitcherFromShortcuts() {
        guard windowSwitcherEnabled, !shortcutsEnabled else { return }
        windowSwitcherEnabled = false
        if toolkit == nil { toolkit = ToolkitPreferences() }
    }
    public mutating func setFeature(_ feature: FeatureID, enabled: Bool) {
        ensureToolkit()
        switch feature {
        case .applicationShortcuts: applicationShortcutsEnabled = enabled
        case .windowSwitcher: windowSwitcherEnabled = enabled
        case .clipboard:
            var settings = workflowSettings; settings.clipboardHistoryEnabled = enabled; workflows = settings
        default: toolkit?.enabled[feature.rawValue] = enabled
        }
    }
    /// Creates `toolkit` the way `setFeature` does, so callers in FrogApp never build it by hand.
    public mutating func ensureToolkit() {
        guard toolkit == nil else { return }
        separateWindowSwitcherFromShortcuts()
        toolkit = ToolkitPreferences()
    }
    public var sidebarFeatures: [FeatureID] {
        FeatureID.allCases.filter { $0.hasPage && featureEnabled($0) && !toolkitSettings.hiddenSidebarItems.contains($0.rawValue) }
    }
    /// Window arrangement belongs to Shortcuts, independently of the switcher overlay.
    public func ruleFeatureEnabled(_ rule: Rule) -> Bool {
        switch rule.category {
        // Answer rules stay inert until the Explain feature exists; then they follow `.explain`.
        case .text: rule.answersInPanel ? false : featureEnabled(.writing)
        case .audio: featureEnabled(.dictation)
        case .application, .window, .system: featureEnabled(.applicationShortcuts)
        }
    }
}

public enum ToolkitRoute: Hashable, Sendable {
    case feature(FeatureID), history, models, features, settings, statistics
    public func available(in preferences: Preferences) -> Bool {
        guard case .feature(let feature) = self else { return true }
        return feature.hasPage && preferences.featureEnabled(feature)
    }
}
