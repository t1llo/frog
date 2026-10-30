import Foundation

/// The looks a menu-bar meter can take. LLM usage and System monitor share them.
public enum MenuBarMeterChoices {
    /// "numbers" keeps the readout as text; "segments" lights one of five steps per 20%;
    /// "bars" fills a smooth track; "columns" stands the bars side by side.
    public static let styles = ["numbers", "segments", "bars", "columns"]
    /// "clean" follows the menu bar's own colour; "level" turns green, amber and red as a meter
    /// fills; "spectrum" runs from green to red along the meter.
    public static let palettes = ["clean", "level", "spectrum"]
}

/// The System monitor menu-bar item as `config` kept it, read once to seed `[system-monitor]`.
public struct SystemMonitorPreferences: Codable, Equatable, Sendable {
    public var menuBarItem = false
    public var menuBarStyle = "segments"
    public var menuBarPalette = "spectrum"

    public init(menuBarItem: Bool = false, menuBarStyle: String = "segments", menuBarPalette: String = "spectrum") {
        self.menuBarItem = menuBarItem; self.menuBarStyle = menuBarStyle; self.menuBarPalette = menuBarPalette
        self = normalized
    }

    /// An unknown look, such as one from a newer Frog, falls back to the default.
    public var normalized: Self {
        var value = self
        if !MenuBarMeterChoices.styles.contains(menuBarStyle) { value.menuBarStyle = "segments" }
        if !MenuBarMeterChoices.palettes.contains(menuBarPalette) { value.menuBarPalette = "spectrum" }
        return value
    }

    private enum CodingKeys: String, CodingKey { case menuBarItem, menuBarStyle, menuBarPalette }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        menuBarItem = try values.decodeIfPresent(Bool.self, forKey: .menuBarItem) ?? false
        menuBarStyle = try values.decodeIfPresent(String.self, forKey: .menuBarStyle) ?? "segments"
        menuBarPalette = try values.decodeIfPresent(String.self, forKey: .menuBarPalette) ?? "spectrum"
        self = normalized
    }
}

/// The optional icon that says Stay awake is on.
public struct StayAwakePreferences: Codable, Equatable, Sendable {
    /// "icon" is the cup alone; "ring" drains a ring around it as a timed session runs out;
    /// "time" adds the time that is left.
    public static let menuBarStyles = ["icon", "ring", "time"]
    public var menuBarItem = false
    public var menuBarStyle = "ring"

    public init(menuBarItem: Bool = false, menuBarStyle: String = "ring") {
        self.menuBarItem = menuBarItem; self.menuBarStyle = menuBarStyle
        self = normalized
    }

    public var normalized: Self {
        var value = self
        if !Self.menuBarStyles.contains(menuBarStyle) { value.menuBarStyle = "ring" }
        return value
    }

    private enum CodingKeys: String, CodingKey { case menuBarItem, menuBarStyle }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        menuBarItem = try values.decodeIfPresent(Bool.self, forKey: .menuBarItem) ?? false
        menuBarStyle = try values.decodeIfPresent(String.self, forKey: .menuBarStyle) ?? "ring"
        self = normalized
    }
}
