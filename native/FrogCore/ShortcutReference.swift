import Foundation

/// The page a global shortcut belongs to, in the order the pages appear in Frog.
public enum ShortcutReferenceGroup: Int, CaseIterable, Sendable {
    case writing, explain, dictation, windows, shortcuts, plugins, frog
    public var title: String {
        switch self {
        case .writing: "Writing"
        case .explain: "Explain"
        case .dictation: "Dictation"
        case .windows: "Windows"
        case .shortcuts: "Shortcuts"
        case .plugins: "Plugins"
        case .frog: "Frog"
        }
    }
}

public struct ShortcutReferenceItem: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var hotkey: Hotkey
    public var group: ShortcutReferenceGroup
    public init(id: String, title: String, hotkey: Hotkey, group: ShortcutReferenceGroup) {
        self.id = id; self.title = title; self.hotkey = hotkey; self.group = group
    }
}

/// Every global shortcut Frog answers to right now, the single source for the shortcut panel.
public enum ShortcutReference {
    /// The enabled rules with a shortcut whose page is on, extra rules another page registers (listed under
    /// Shortcuts), then Frog's own shortcuts whose feature is on. `answersInPanel` tells which text rules answer
    /// in a panel rather than replacing the selection; they are listed under Explain.
    public static func items(configuration: Configuration, ruleEnabled: (Rule) -> Bool, extraRules: [Rule] = [],
                             answersInPanel: (Rule) -> Bool = { _ in false }) -> [ShortcutReferenceItem] {
        var items: [ShortcutReferenceItem] = []
        for rule in configuration.rules where rule.enabled && ruleEnabled(rule) {
            guard let hotkey = rule.hotkey else { continue }
            let group: ShortcutReferenceGroup = switch rule.category {
            case .text: answersInPanel(rule) ? .explain : .writing
            case .audio: .dictation
            case .window: .windows
            case .application, .system: .shortcuts
            }
            items.append(ShortcutReferenceItem(id: rule.id.uuidString, title: title(rule), hotkey: hotkey, group: group))
        }
        for rule in extraRules where rule.enabled {
            guard let hotkey = rule.hotkey else { continue }
            items.append(ShortcutReferenceItem(id: rule.id.uuidString, title: title(rule), hotkey: hotkey,
                                               group: rule.category == .window ? .windows : .shortcuts))
        }
        let preferences = configuration.preferences
        let workflow = preferences.workflowSettings
        let toolkit = preferences.toolkitSettings
        let frog: [(id: String, title: String, hotkey: Hotkey?)] = [
            ("frog.command-bar", "Command bar", preferences.featureEnabled(.commandBar) ? toolkit.effectiveCommandBarHotkey : nil),
            ("frog.clipboard", "Clipboard history", preferences.featureEnabled(.clipboard) ? workflow.effectiveClipboardHistoryHotkey : nil),
            ("frog.window-switcher", "Window switcher", preferences.featureEnabled(.windowSwitcher) ? toolkit.effectiveWindowSwitcherHotkey : nil),
            ("frog.menu-bar", "Show or hide menu bar items", preferences.featureEnabled(.menuBar) ? toolkit.menuBar?.hotkey : nil),
            ("frog.cancel-recording", "Cancel recording", preferences.featureEnabled(.dictation) ? workflow.cancelRecordingHotkey : nil),
            ("frog.shortcuts", "Show shortcuts", workflow.shortcutPanelHotkey)
        ]
        for entry in frog {
            guard let hotkey = entry.hotkey else { continue }
            items.append(ShortcutReferenceItem(id: entry.id, title: entry.title, hotkey: hotkey, group: .frog))
        }
        return items
    }

    /// The items under their page, pages in order, rows in the order given; pages without a row are left out.
    /// A page whose only row names the page itself (Explain's "Explain", Dictation's "Dictate") gets no heading
    /// of its own to repeat it: the row joins Frog's, which lists each feature's own shortcut.
    public static func grouped(_ items: [ShortcutReferenceItem]) -> [(group: ShortcutReferenceGroup, items: [ShortcutReferenceItem])] {
        var byGroup = Dictionary(grouping: items, by: \.group)
        var features: [ShortcutReferenceItem] = []
        for group in ShortcutReferenceGroup.allCases where group != .frog {
            guard let rows = byGroup[group], rows.count == 1, names(rows[0].title, group) else { continue }
            features.append(rows[0])
            byGroup[group] = nil
        }
        if !features.isEmpty { byGroup[.frog] = features + (byGroup[.frog] ?? []) }
        return ShortcutReferenceGroup.allCases.compactMap { group in
            byGroup[group].flatMap { $0.isEmpty ? nil : (group, $0) }
        }
    }

    /// Whether a row's title names its page: the same word, or its verb ("Dictate" for Dictation).
    private static func names(_ title: String, _ group: ShortcutReferenceGroup) -> Bool {
        let title = title.lowercased(), page = group.title.lowercased()
        return title == page || (title.count >= 5 && page.hasPrefix(String(title.prefix(5))) && !title.contains(" "))
    }

    private static func title(_ rule: Rule) -> String {
        rule.action?.systemAction?.title ?? rule.name
    }
}
