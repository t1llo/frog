import Foundation

/// What the window cheat sheet lists: every layout and window command that has a shortcut, grouped.
public enum WindowCheatSheet {
    public struct Item: Equatable, Sendable, Identifiable {
        public var title: String
        public var action: WindowAction?
        public var command: WindowCommand?
        public var hotkey: Hotkey
        public var id: String { action?.rawValue ?? command?.rawValue ?? title }
        public init(title: String, action: WindowAction? = nil, command: WindowCommand? = nil, hotkey: Hotkey) {
            self.title = title; self.action = action; self.command = command; self.hotkey = hotkey
        }
    }

    public struct Section: Equatable, Sendable, Identifiable {
        public var title: String
        public var items: [Item]
        public var id: String { title }
        public init(title: String, items: [Item]) { self.title = title; self.items = items }
    }

    /// The section titles in the order the sheet shows them; commands come last.
    public static let order = ["Halves", "Quarters", "Thirds", "Sizes", "Displays", "Undo", commandsTitle]
    static let commandsTitle = "Windows"

    public static func group(for action: WindowAction) -> String {
        switch action {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: "Halves"
        case .topLeft, .topRight, .bottomLeft, .bottomRight: "Quarters"
        case .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds: "Thirds"
        case .maximize, .minimize, .center, .toggleFullScreen, .centeredSmall, .centeredMedium, .centeredLarge: "Sizes"
        case .nextDisplay, .previousDisplay: "Displays"
        case .restore: "Undo"
        }
    }

    /// Sections in `order`, each in `WindowAction.allCases` order, with only enabled layout rules
    /// that have a shortcut. Empty sections are left out.
    public static func sections(rules: [Rule], commands: [(WindowCommand, Hotkey)]) -> [Section] {
        var items: [String: [Item]] = [:]
        for action in WindowAction.allCases {
            for rule in rules where rule.enabled && rule.category == .window && rule.action?.windowAction == action {
                guard let key = rule.hotkey else { continue }
                items[group(for: action), default: []].append(Item(title: action.title, action: action, hotkey: key))
            }
        }
        for command in WindowCommand.allCases {
            for (listed, key) in commands where listed == command {
                items[commandsTitle, default: []].append(Item(title: command.title, command: command, hotkey: key))
            }
        }
        return order.compactMap { title in items[title].map { Section(title: title, items: $0) } }
    }
}
