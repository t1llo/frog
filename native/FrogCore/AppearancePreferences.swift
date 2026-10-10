import Foundation

public struct AppearancePreferences: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case system, light, dark }
    public enum Theme: String, Codable, CaseIterable, Sendable {
        case frog, tokyoNight, catppuccin, nord, gruvbox, dracula, rosePine, solarized, everforest, graphite
        public var title: String {
            switch self {
            case .frog: "Frog"; case .tokyoNight: "Tokyo Night"; case .catppuccin: "Catppuccin"; case .nord: "Nord"
            case .gruvbox: "Gruvbox"; case .dracula: "Dracula"; case .rosePine: "Rosé Pine"
            case .solarized: "Solarized"; case .everforest: "Everforest"; case .graphite: "Graphite"
            }
        }
    }
    public var mode: Mode?
    public var theme: Theme?
    public var useThemeAccent: Bool?
    /// Six-digit RGB, without '#'.
    public var accentHex = "A3D8AF"
    /// Zero is opaque; one is the strongest material translucency.
    public var transparency = 0.0
    /// Independent overlay translucency; nil preserves the readable opaque default.
    public var popupTransparency: Double?
    /// Partial semantic overrides. Missing colors inherit the selected preset.
    public var lightPalette: [String: String]?
    public var darkPalette: [String: String]?
    public static let paletteKeys = ["background", "sidebar", "surface", "inset", "border", "text", "muted", "accent", "on-accent"]
    public init() {}
    /// Accessibility overrides affect rendering only; saved preferences remain portable.
    public func effectiveTransparency(popup: Bool, reduceTransparency: Bool, increasedContrast: Bool) -> Double {
        guard !reduceTransparency, !increasedContrast else { return 0 }
        let amount = popup ? popupTransparency ?? 0 : transparency
        return amount.isFinite ? min(1, max(0, amount)) : 0
    }
    public var valid: Bool {
        accentHex.count == 6 && UInt32(accentHex, radix: 16) != nil && transparency.isFinite && (0...1).contains(transparency)
            && (popupTransparency ?? 0).isFinite && (0...1).contains(popupTransparency ?? 0)
            && [lightPalette, darkPalette].compactMap { $0 }.allSatisfy { palette in
                palette.allSatisfy { Self.paletteKeys.contains($0.key) && $0.value.count == 6 && UInt32($0.value, radix: 16) != nil }
            }
    }
}
