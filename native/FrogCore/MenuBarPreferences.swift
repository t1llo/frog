import Foundation

/// Portable behavior only. macOS owns status-item positions on each Mac.
public struct MenuBarPreferences: Codable, Equatable, Sendable {
    public var autoHide = true
    public var autoHideSeconds: Double = 10
    public var startCollapsed = false
    public var permanentlyHiddenSection = false
    public var hoverToReveal = false
    /// Opt-in: no global combination is reserved by default.
    public var hotkey: Hotkey?

    public init() {}

    public var normalized: Self {
        var value = self
        value.autoHideSeconds = autoHideSeconds.isFinite ? min(3600, max(1, autoHideSeconds)) : 10
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case autoHide, autoHideSeconds, startCollapsed, permanentlyHiddenSection, hoverToReveal, hotkey
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        autoHide = try values.decodeIfPresent(Bool.self, forKey: .autoHide) ?? true
        autoHideSeconds = try values.decodeIfPresent(Double.self, forKey: .autoHideSeconds) ?? 10
        startCollapsed = try values.decodeIfPresent(Bool.self, forKey: .startCollapsed) ?? false
        permanentlyHiddenSection = try values.decodeIfPresent(Bool.self, forKey: .permanentlyHiddenSection) ?? false
        hoverToReveal = try values.decodeIfPresent(Bool.self, forKey: .hoverToReveal) ?? false
        hotkey = try values.decodeIfPresent(Hotkey.self, forKey: .hotkey)
        self = normalized
    }
}
