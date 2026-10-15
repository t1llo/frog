import Foundation

/// What the layout picker lists and which tile is selected: the layouts that place the window,
/// grouped as the cheat sheet groups them, four tiles to a row, filtered by the typed text.
public struct LayoutPickerModel: Equatable, Sendable {
    public struct Tile: Equatable, Sendable, Identifiable {
        public var action: WindowAction
        public var hotkey: Hotkey?
        public var title: String { action.title }
        public var id: String { action.rawValue }
        public init(action: WindowAction, hotkey: Hotkey?) { self.action = action; self.hotkey = hotkey }
    }

    public struct Section: Equatable, Sendable, Identifiable {
        public var title: String
        public var tiles: [Tile]
        public var id: String { title }
        /// The tiles in rows of `LayoutPickerModel.columns`.
        public var rows: [[Tile]] {
            stride(from: 0, to: tiles.count, by: LayoutPickerModel.columns).map { Array(tiles[$0..<min($0 + LayoutPickerModel.columns, tiles.count)]) }
        }
        public init(title: String, tiles: [Tile]) { self.title = title; self.tiles = tiles }
    }

    public enum Direction: Sendable { case left, right, up, down }

    public static let columns = 4
    /// The section titles in order; the cheat sheet's, without its commands.
    public static let sectionTitles = ["Halves", "Quarters", "Thirds", "Sizes", "Displays", "Undo"]
    /// Minimize and full screen leave nothing to place, so the picker does not offer them.
    public static let offered = WindowAction.allCases.filter { $0 != .minimize && $0 != .toggleFullScreen }

    public private(set) var query = ""
    public private(set) var sections: [Section] = []
    public private(set) var selection: WindowAction?
    private let hotkeys: [WindowAction: Hotkey]

    public init(hotkeys: [WindowAction: Hotkey]) {
        self.hotkeys = hotkeys
        sections = Self.sections(query: "", hotkeys: hotkeys)
        selection = sections.first?.tiles.first?.action
    }

    /// Every visible tile's action, in reading order.
    public var visibleActions: [WindowAction] { sections.flatMap { $0.tiles.map(\.action) } }

    public mutating func setQuery(_ text: String) {
        query = text
        sections = Self.sections(query: text, hotkeys: hotkeys)
        if let selection, visibleActions.contains(selection) { return }
        selection = visibleActions.first
    }

    public mutating func select(_ action: WindowAction) {
        guard visibleActions.contains(action) else { return }
        selection = action
    }

    /// Left and right step through the tiles in reading order, across rows and sections; up and
    /// down go to the row above or below, keeping the column where that row is long enough.
    /// Both stop at the first and last tile.
    public mutating func move(_ direction: Direction) {
        let rows = sections.flatMap { $0.rows.map { $0.map(\.action) } }
        let order = rows.flatMap { $0 }
        guard let first = order.first else { selection = nil; return }
        guard let selection, let index = order.firstIndex(of: selection),
              let row = rows.firstIndex(where: { $0.contains(selection) }),
              let column = rows[row].firstIndex(of: selection) else { self.selection = first; return }
        switch direction {
        case .left: self.selection = order[max(0, index - 1)]
        case .right: self.selection = order[min(order.count - 1, index + 1)]
        case .up, .down:
            let target = direction == .up ? max(0, row - 1) : min(rows.count - 1, row + 1)
            self.selection = rows[target][min(column, rows[target].count - 1)]
        }
    }

    static func sections(query: String, hotkeys: [WindowAction: Hotkey]) -> [Section] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sectionTitles.compactMap { title in
            let tiles = offered.filter { action in
                WindowCheatSheet.group(for: action) == title
                    && (text.isEmpty || action.title.localizedCaseInsensitiveContains(text) || title.localizedCaseInsensitiveContains(text))
            }.map { Tile(action: $0, hotkey: hotkeys[$0]) }
            return tiles.isEmpty ? nil : Section(title: title, tiles: tiles)
        }
    }
}
