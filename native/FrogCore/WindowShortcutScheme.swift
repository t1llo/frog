import Foundation

/// The window shortcuts Frog suggests, and how they are added to a configuration without changing
/// a shortcut that is already set or taking one that is in use.
public enum WindowShortcutScheme {
    private static let controlOption: UInt32 = 4096 | 2048
    private static let controlOptionCommand: UInt32 = 4096 | 2048 | 256

    public static let actions: [WindowAction: Hotkey] = [
        .leftHalf: Hotkey(keyCode: 123, modifiers: controlOption),
        .rightHalf: Hotkey(keyCode: 124, modifiers: controlOption),
        .topHalf: Hotkey(keyCode: 126, modifiers: controlOption),
        .bottomHalf: Hotkey(keyCode: 125, modifiers: controlOption),
        .topLeft: Hotkey(keyCode: 32, modifiers: controlOption),
        .topRight: Hotkey(keyCode: 34, modifiers: controlOption),
        .bottomLeft: Hotkey(keyCode: 38, modifiers: controlOption),
        .bottomRight: Hotkey(keyCode: 40, modifiers: controlOption),
        .leftThird: Hotkey(keyCode: 2, modifiers: controlOption),
        .centerThird: Hotkey(keyCode: 3, modifiers: controlOption),
        .rightThird: Hotkey(keyCode: 5, modifiers: controlOption),
        .leftTwoThirds: Hotkey(keyCode: 14, modifiers: controlOption),
        .rightTwoThirds: Hotkey(keyCode: 17, modifiers: controlOption),
        .maximize: Hotkey(keyCode: 36, modifiers: controlOption),
        .center: Hotkey(keyCode: 8, modifiers: controlOption),
        .restore: Hotkey(keyCode: 51, modifiers: controlOption),
        .nextDisplay: Hotkey(keyCode: 124, modifiers: controlOptionCommand),
        .previousDisplay: Hotkey(keyCode: 123, modifiers: controlOptionCommand),
    ]

    public static let commands: [WindowCommand: Hotkey] = [
        .cheatSheet: Hotkey(keyCode: 44, modifiers: controlOption),
        .layoutPicker: Hotkey(keyCode: 13, modifiers: controlOption),
    ]

    /// A suggestion that was left out because its shortcut is in use.
    public struct Skip: Equatable, Sendable {
        public var title: String
        public var hotkey: Hotkey
        public init(title: String, hotkey: Hotkey) { self.title = title; self.hotkey = hotkey }
    }

    public struct Result: Equatable, Sendable {
        public var configuration: Configuration
        /// Titles of the actions and commands that got a shortcut, in the order they were added.
        public var added: [String]
        public var skipped: [Skip]

        /// The line shown under the button. `display` writes a shortcut the way the app shows it.
        public func summary(display: (Hotkey) -> String) -> String {
            guard !added.isEmpty else { return "Every suggested shortcut is already assigned or in use." }
            let count = added.count == 1 ? "Added 1 shortcut." : "Added \(added.count) shortcuts."
            guard !skipped.isEmpty else { return count }
            let listed = skipped.prefix(3).map { "\($0.title) (\(display($0.hotkey)))" }.joined(separator: ", ")
            let rest = skipped.count > 3 ? " and \(skipped.count - 3) more." : "."
            return "\(count) Skipped \(skipped.count) already in use: \(listed)\(rest)"
        }
    }

    /// The shortcuts a configuration already claims, as `ConfigurationFile.validate` collects them,
    /// in its order. A shortcut source added there must be added here too.
    public static func usedShortcuts(_ configuration: Configuration) -> Set<Hotkey> {
        let preferences = configuration.preferences
        let toolkit = preferences.toolkitSettings, workflow = preferences.workflowSettings
        var used = Set<Hotkey>()
        if preferences.featureEnabled(.commandBar) { used.insert(toolkit.effectiveCommandBarHotkey) }
        if preferences.featureEnabled(.menuBar), let key = toolkit.menuBar?.hotkey { used.insert(key) }
        if let key = workflow.shortcutPanelHotkey { used.insert(key) }
        if let key = workflow.cancelRecordingHotkey { used.insert(key) }
        if workflow.clipboardHistoryEnabled == true { used.insert(workflow.effectiveClipboardHistoryHotkey) }
        // Every enabled rule, whether or not its feature is on.
        for rule in configuration.rules where rule.enabled {
            if let key = rule.hotkey { used.insert(key) }
        }
        used.formUnion(WindowSwitches(preferences).shortcutRules.compactMap(\.hotkey))
        return used
    }

    /// Adds the suggested shortcuts of every layout and of the commands in `groups` that have none.
    /// `taken` holds shortcuts the configuration cannot show, such as the window switcher's.
    public static func apply(to configuration: Configuration, groups: Set<WindowCommand.Group>, taken: Set<Hotkey>) -> Result {
        var result = configuration
        var used = usedShortcuts(configuration).union(taken)
        var added: [String] = [], skipped: [Skip] = []
        for action in WindowAction.allCases {
            guard let key = actions[action] else { continue }
            let index = result.rules.firstIndex { $0.category == .window && $0.action?.windowAction == action }
            if let index, result.rules[index].hotkey != nil { continue }
            guard !used.contains(key) else { skipped.append(Skip(title: action.title, hotkey: key)); continue }
            if let index {
                result.rules[index].hotkey = key; result.rules[index].enabled = true
            } else {
                var rule = action.rule
                guard !result.rules.contains(where: { $0.id == rule.id }) else { continue }
                rule.hotkey = key; rule.enabled = true
                result.rules.append(rule)
            }
            used.insert(key); added.append(action.title)
        }
        for command in WindowCommand.allCases where groups.contains(command.group) {
            guard let key = commands[command],
                  result.preferences.toolkitSettings.windows?.shortcuts[command.rawValue] == nil else { continue }
            guard !used.contains(key) else { skipped.append(Skip(title: command.title, hotkey: key)); continue }
            result.preferences.ensureToolkit()
            var windows = result.preferences.toolkit?.windows ?? WindowPreferences()
            windows.shortcuts[command.rawValue] = key
            result.preferences.toolkit?.windows = windows
            used.insert(key); added.append(command.title)
        }
        return Result(configuration: result, added: added, skipped: skipped)
    }
}
