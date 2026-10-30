import Foundation

/// A window command that is not a layout: it opens or shows something rather than moving the
/// front window. Its shortcut is kept in `WindowPreferences.shortcuts` under its raw value.
public enum WindowCommand: String, CaseIterable, Codable, Sendable, Identifiable {
    case cheatSheet
    case layoutPicker

    /// The part of Windows a command belongs to; suggested shortcuts are added per part.
    public enum Group: String, Sendable { case simple, tiling, canvas }

    /// Fixed for good: a number is never reused or given to another command. 1 is the layout
    /// picker, 10–29 are tiling commands and 30–39 canvas commands.
    public var number: Int {
        switch self {
        case .cheatSheet: 2
        case .layoutPicker: 1
        }
    }

    /// The id of the shortcut Frog registers; layout rules use `AC57F600-…`.
    public var id: UUID { UUID(uuidString: String(format: "AC57F601-63D0-4E76-9900-%012d", number))! }

    public var title: String {
        switch self {
        case .cheatSheet: "Window cheat sheet"
        case .layoutPicker: "Arrange window…"
        }
    }

    public var symbol: String {
        switch self {
        case .cheatSheet: "keyboard"
        case .layoutPicker: "rectangle.split.2x1"
        }
    }

    public var group: Group {
        switch self {
        case .cheatSheet, .layoutPicker: .simple
        }
    }

    /// The command runs while its shortcut is held and ends when it is released.
    public var isMomentary: Bool {
        switch self {
        case .cheatSheet: true
        case .layoutPicker: false
        }
    }

    /// Extra words the command bar matches.
    public var keywords: String {
        switch self {
        case .layoutPicker: "window layout arrange snap"
        case .cheatSheet: "window shortcuts cheat sheet"
        }
    }

    public static func command(for id: UUID) -> WindowCommand? { allCases.first { $0.id == id } }

    /// The rule Frog registers for the shortcut, the way it registers its own shortcuts.
    public func rule(hotkey: Hotkey) -> Rule { Rule(id: id, name: title, hotkey: hotkey) }
}
