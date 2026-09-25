import Foundation

public struct AppearancePreferences: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case system, light, dark }
    public enum Theme: String, Codable, CaseIterable, Sendable {
        case frog, tokyoNight, catppuccin, nord
        public var title: String {
            switch self { case .frog: "Frog"; case .tokyoNight: "Tokyo Night"; case .catppuccin: "Catppuccin"; case .nord: "Nord" }
        }
    }
    public var mode: Mode?
    public var theme: Theme?
    public var useThemeAccent: Bool?
    /// Six-digit RGB, without '#'.
    public var accentHex = "A3D8AF"
    /// Zero is opaque; one is the strongest material translucency.
    public var transparency = 0.0
    public init() {}
    public var valid: Bool {
        accentHex.count == 6 && UInt32(accentHex, radix: 16) != nil && transparency.isFinite && (0...1).contains(transparency)
    }
}
