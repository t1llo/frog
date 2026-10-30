import Foundation

/// Stable identities shared by configuration, navigation and command routing. The order is the sidebar's and the
/// Features page's: text and AI first, then finding and arranging things, small tools, and the Mac itself.
public enum FeatureID: String, Codable, CaseIterable, Identifiable, Sendable {
    case writing
    case explain
    case dictation
    case commandBar
    case applicationShortcuts
    case windows
    case windowSwitcher
    case clipboard
    case scratchpad
    case scripts
    case usage
    case systemMonitor
    case stayAwake
    case menuBar
    case cleaner
    case phone
    case plugins

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .writing: "Writing"
        case .explain: "Explain"
        case .dictation: "Dictation"
        case .commandBar: "Command bar"
        case .applicationShortcuts: "Shortcuts"
        case .windows: "Windows"
        case .windowSwitcher: "Window switcher"
        case .clipboard: "Clipboard"
        case .scratchpad: "Notes"
        case .scripts: "Scripts"
        case .usage: "LLM usage"
        case .systemMonitor: "System monitor"
        case .stayAwake: "Stay awake"
        case .menuBar: "Menu bar"
        case .cleaner: "App cleaner"
        case .phone: "Phone"
        case .plugins: "Plugins"
        }
    }
    public var symbol: String {
        switch self {
        case .writing: "text.cursor"
        case .explain: "questionmark.bubble"
        case .dictation: "waveform"
        case .commandBar: "magnifyingglass"
        case .applicationShortcuts: "command"
        case .windows: "rectangle.split.2x1"
        case .windowSwitcher: "macwindow.on.rectangle"
        case .clipboard: "clipboard"
        case .scratchpad: "note.text"
        case .scripts: "terminal"
        case .usage: "chart.bar.xaxis"
        case .systemMonitor: "gauge.medium"
        case .stayAwake: "cup.and.saucer"
        case .menuBar: "menubar.rectangle"
        case .cleaner: "trash.circle"
        case .phone: "iphone"
        case .plugins: "puzzlepiece.extension"
        }
    }
    /// One line for the Features page and the command bar's search.
    public var detail: String {
        switch self {
        case .writing: "Rewrite selected text with your rules."
        case .explain: "Ask about selected text and get a short answer."
        case .dictation: "Turn speech into text."
        case .commandBar: "Find apps, files, settings and commands."
        case .applicationShortcuts: "Open apps and run Mac actions with a shortcut."
        case .windows: "Snap and tile windows."
        case .windowSwitcher: "Switch between windows with the keyboard."
        case .clipboard: "Search and paste text you copied."
        case .scratchpad: "Markdown notes, and text to paste from the command bar."
        case .scripts: "Run your own shell scripts."
        case .usage: "Claude and Codex limits and activity."
        case .systemMonitor: "CPU, GPU, memory and battery."
        case .stayAwake: "Keep the Mac awake, also with the lid closed."
        case .menuBar: "Hide menu bar icons behind a divider."
        case .cleaner: "Uninstall apps with the files they leave behind."
        case .phone: "Share the clipboard and files with your Android phone."
        case .plugins: "Features you build with your AI agent, or install from others."
        }
    }
}

public struct ToolkitPreferences: Codable, Equatable, Sendable {
    public var enabled: [String: Bool] = [:]
    public var hiddenSidebarItems: Set<String> = []
    /// Features shown at the top of the sidebar, above the others.
    public var pinnedSidebarItems: Set<String> = []
    /// Feature IDs in the order the user arranged the sidebar; empty for the catalog's order.
    public var sidebarOrder: [String] = []
    public var commandBarHotkey: Hotkey?
    public var windowSwitcherHotkey: Hotkey?
    public var usage: UsageDisplayPreferences?
    public var menuBar: MenuBarPreferences?
    /// The CPU and GPU item in the menu bar.
    public var systemMonitor: SystemMonitorPreferences?
    /// The icon that says Stay awake is on.
    public var stayAwake: StayAwakePreferences?
    public var explain: ExplainSettings?
    public var windows: WindowPreferences?
    public var cleaner: CleanerPreferences?
    public var commandBar: CommandBarPreferences?
    /// Lets the `frog` command and AI agents control Frog through its local socket. Off unless turned on.
    public var agentAccess: Bool?
    /// Sends copied text and images to paired phones while Phone is on. On unless turned off.
    public var phoneAutoSend: Bool?
    public var commandBarSettings: CommandBarPreferences { commandBar ?? CommandBarPreferences() }
    public var effectiveCommandBarHotkey: Hotkey { commandBarHotkey ?? Hotkey(keyCode: 49, modifiers: 4096 | 2048) }
    public var effectiveWindowSwitcherHotkey: Hotkey { windowSwitcherHotkey ?? Hotkey(keyCode: 48, modifiers: 256) }
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case enabled
        case hiddenSidebarItems
        case pinnedSidebarItems
        case sidebarOrder
        case commandBarHotkey
        case windowSwitcherHotkey
        case usage
        case menuBar
        case systemMonitor
        case stayAwake
        case explain
        case windows
        case cleaner
        case commandBar
        case agentAccess
        case phoneAutoSend
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent([String: Bool].self, forKey: .enabled) ?? [:]
        hiddenSidebarItems = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenSidebarItems) ?? []
        pinnedSidebarItems = try values.decodeIfPresent(Set<String>.self, forKey: .pinnedSidebarItems) ?? []
        sidebarOrder = try values.decodeIfPresent([String].self, forKey: .sidebarOrder) ?? []
        commandBarHotkey = try values.decodeIfPresent(Hotkey.self, forKey: .commandBarHotkey)
        windowSwitcherHotkey = try values.decodeIfPresent(Hotkey.self, forKey: .windowSwitcherHotkey)
        usage = try values.decodeIfPresent(UsageDisplayPreferences.self, forKey: .usage)
        menuBar = try values.decodeIfPresent(MenuBarPreferences.self, forKey: .menuBar)
        systemMonitor = try values.decodeIfPresent(SystemMonitorPreferences.self, forKey: .systemMonitor)
        stayAwake = try values.decodeIfPresent(StayAwakePreferences.self, forKey: .stayAwake)
        explain = try values.decodeIfPresent(ExplainSettings.self, forKey: .explain)
        windows = try values.decodeIfPresent(WindowPreferences.self, forKey: .windows)
        cleaner = try values.decodeIfPresent(CleanerPreferences.self, forKey: .cleaner)
        commandBar = try values.decodeIfPresent(CommandBarPreferences.self, forKey: .commandBar)
        agentAccess = try values.decodeIfPresent(Bool.self, forKey: .agentAccess)
        phoneAutoSend = try values.decodeIfPresent(Bool.self, forKey: .phoneAutoSend)
        retireMergedFeatures()
    }

    /// Features earlier versions had. Snippets and the shelf became notes, and Quick actions became
    /// command bar rows, in 1.0.39.
    public static let retiredFeatures: Set<String> = ["snippets", "shelf", "quickActions"]

    /// Someone who used snippets or the shelf finds those items in Notes, so Notes is turned on for
    /// them. The retired IDs are dropped, so the next save no longer writes them.
    mutating func retireMergedFeatures() {
        if enabled["snippets"] == true || enabled["shelf"] == true { enabled["scratchpad"] = true }
        for id in Self.retiredFeatures { enabled[id] = nil }
        hiddenSidebarItems.subtract(Self.retiredFeatures)
        pinnedSidebarItems.subtract(Self.retiredFeatures)
        sidebarOrder.removeAll { Self.retiredFeatures.contains($0) }
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
    /// How the menu-bar item draws its limits, one of `MenuBarMeterChoices.styles`.
    public var menuBarStyle: String
    /// Its colours, one of `MenuBarMeterChoices.palettes`.
    public var menuBarPalette: String
    public init(provider: String = "Claude", range: String = "7d", metric: String = "API cost", allDevices: Bool = false, loginSource: String = "Automatic",
                claudeAccounts: Bool = false, claudeAccountsView: String = "each", claudeAccountsMenuBar: String = "session",
                menuBarStyle: String = "numbers", menuBarPalette: String = "clean") {
        self.provider = provider; self.range = range; self.metric = metric
        self.allDevices = allDevices; self.loginSource = loginSource
        self.claudeAccounts = claudeAccounts; self.claudeAccountsView = claudeAccountsView
        self.claudeAccountsMenuBar = claudeAccountsMenuBar
        self.menuBarStyle = menuBarStyle; self.menuBarPalette = menuBarPalette
    }

    private enum CodingKeys: String, CodingKey {
        case provider, range, metric, allDevices, loginSource, claudeAccounts, claudeAccountsView, claudeAccountsMenuBar
        case menuBarStyle, menuBarPalette
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
        menuBarStyle = try values.decodeIfPresent(String.self, forKey: .menuBarStyle) ?? defaults.menuBarStyle
        menuBarPalette = try values.decodeIfPresent(String.self, forKey: .menuBarPalette) ?? defaults.menuBarPalette
    }

    public func validate() throws {
        guard ["each", "combined"].contains(claudeAccountsView) else {
            throw FrogError.message("Choose each or combined for Claude accounts.")
        }
        guard ["session", "week"].contains(claudeAccountsMenuBar) else {
            throw FrogError.message("Choose session or week for the Claude accounts menu bar item.")
        }
        guard MenuBarMeterChoices.styles.contains(menuBarStyle), MenuBarMeterChoices.palettes.contains(menuBarPalette) else {
            throw FrogError.message("Choose a known design for the LLM usage menu bar item.")
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
    /// The sidebar's features: pinned ones first, each group in the user's order.
    public var sidebarFeatures: [FeatureID] {
        let settings = toolkitSettings
        return SidebarArrangement(order: settings.sidebarOrder, pinned: settings.pinnedSidebarItems).shown(
            FeatureID.allCases.filter { featureEnabled($0) && !settings.hiddenSidebarItems.contains($0.rawValue) })
    }
    /// Window arrangement belongs to Shortcuts, independently of the switcher overlay.
    public func ruleFeatureEnabled(_ rule: Rule) -> Bool {
        switch rule.category {
        case .text: rule.isExplainRule ? featureEnabled(.explain) : featureEnabled(.writing)
        case .audio: featureEnabled(.dictation)
        case .application, .system: featureEnabled(.applicationShortcuts)
        case .window: windowActionsEnabled
        }
    }
}

public enum ToolkitRoute: Hashable, Sendable {
    case feature(FeatureID), history, models, features, settings, statistics
    /// An installed plugin's page, by its id.
    case plugin(String)
    public func available(in preferences: Preferences) -> Bool {
        switch self {
        case .feature(let feature): preferences.featureEnabled(feature)
        case .plugin: preferences.featureEnabled(.plugins)
        default: true
        }
    }
}
