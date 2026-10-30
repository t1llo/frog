import Foundation

public struct AppearancePreferences: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case system, light, dark }
    public enum Theme: String, Codable, CaseIterable, Sendable {
        case minimal, frog, tokyoNight, catppuccin, nord, gruvbox, dracula, rosePine, solarized, everforest, graphite
        public var title: String {
            switch self {
            case .minimal: "Minimal"
            case .frog: "Frog"; case .tokyoNight: "Tokyo Night"; case .catppuccin: "Catppuccin"; case .nord: "Nord"
            case .gruvbox: "Gruvbox"; case .dracula: "Dracula"; case .rosePine: "Rosé Pine"
            case .solarized: "Solarized"; case .everforest: "Everforest"; case .graphite: "Graphite"
            }
        }
    }
    public var mode: Mode?
    public var theme: Theme?
    /// Minimal is the theme until one is chosen.
    public var effectiveTheme: Theme { theme ?? .minimal }
    public var useThemeAccent: Bool?
    /// Six-digit RGB, without '#'.
    public var accentHex = "A3D8AF"
    /// Zero is opaque; one is the strongest material translucency.
    public var transparency = 0.0
    /// Independent overlay translucency; nil preserves the readable opaque default.
    public var popupTransparency: Double?
    /// The light inside popups and the sidebar; nil is off.
    public var glow: Glow?
    /// How bright the glow and its glare are, from 0 to 1; nil is `defaultGlowStrength`.
    public var glowStrength: Double?
    /// The glow drifts slowly and its glare follows the pointer; nil is on. Still under Reduce Motion.
    public var glowMotion: Bool?
    public static let defaultGlowStrength = 0.6
    /// Partial semantic overrides. Missing colors inherit the selected preset.
    public var lightPalette: [String: String]?
    public var darkPalette: [String: String]?
    public static let paletteKeys = ["background", "sidebar", "surface", "inset", "border", "text", "muted", "accent", "on-accent", "good", "warning", "critical"]
    public init() {}
    /// Accessibility overrides affect rendering only; saved preferences remain portable.
    public func effectiveTransparency(popup: Bool, reduceTransparency: Bool, increasedContrast: Bool) -> Double {
        guard !reduceTransparency, !increasedContrast else { return 0 }
        let amount = popup ? popupTransparency ?? 0 : transparency
        return amount.isFinite ? min(1, max(0, amount)) : 0
    }
    /// The glow as drawn: off while macOS reduces transparency or increases contrast.
    public func effectiveGlow(reduceTransparency: Bool, increasedContrast: Bool) -> Glow {
        reduceTransparency || increasedContrast ? .off : glow ?? .off
    }
    public var effectiveGlowStrength: Double {
        let amount = glowStrength ?? Self.defaultGlowStrength
        return amount.isFinite ? min(1, max(0, amount)) : Self.defaultGlowStrength
    }
    public var valid: Bool {
        (glowStrength ?? 0).isFinite && (0...1).contains(glowStrength ?? 0) && accentHex.count == 6 && UInt32(accentHex, radix: 16) != nil && transparency.isFinite && (0...1).contains(transparency)
            && (popupTransparency ?? 0).isFinite && (0...1).contains(popupTransparency ?? 0)
            && [lightPalette, darkPalette].compactMap { $0 }.allSatisfy { palette in
                palette.allSatisfy { Self.paletteKeys.contains($0.key) && $0.value.count == 6 && UInt32($0.value, radix: 16) != nil }
            }
    }

    /// A light drawn inside Frog's glass: a soft glow in the accent's colours and a glare on the rim nearest it.
    public enum Glow: String, Codable, CaseIterable, Sendable {
        case off, halo, aurora, prism
        public var title: String {
            switch self {
            case .off: "Off"; case .halo: "Halo"; case .aurora: "Aurora"; case .prism: "Prism"
            }
        }
    }

    /// Ready-made combinations of transparency and glow. Any other combination is custom.
    public enum Look: String, CaseIterable, Sendable {
        case solid, frosted, glass, aurora, prism
        public var title: String {
            switch self {
            case .solid: "Solid"; case .frosted: "Frosted"; case .glass: "Clear glass"; case .aurora: "Aurora"; case .prism: "Prism"
            }
        }
        private var values: (window: Double, popup: Double, glow: Glow, strength: Double) {
            switch self {
            case .solid: (0, 0, .off, AppearancePreferences.defaultGlowStrength)
            case .frosted: (0.4, 0.5, .halo, 0.45)
            case .glass: (0.8, 0.85, .halo, 0.7)
            case .aurora: (0.6, 0.65, .aurora, 0.7)
            case .prism: (0.6, 0.65, .prism, 0.6)
            }
        }
        /// Sets transparency and glow; colours, theme and motion stay.
        public func apply(to appearance: inout AppearancePreferences) {
            let values = values
            appearance.transparency = values.window
            appearance.popupTransparency = values.popup
            appearance.glow = values.glow
            appearance.glowStrength = values.strength
        }
        /// The look these settings are, or nil when they are custom.
        public static func matching(_ appearance: AppearancePreferences) -> Look? {
            func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.005 }
            return allCases.first { look in
                let values = look.values
                let glow = appearance.glow ?? .off
                return near(appearance.transparency, values.window) && near(appearance.popupTransparency ?? 0, values.popup)
                    && glow == values.glow && (glow == .off || near(appearance.effectiveGlowStrength, values.strength))
            }
        }
    }
}
