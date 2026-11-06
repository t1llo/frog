import AppKit
import SwiftUI

/// A plugin's or feature's icon, as System Settings draws them: a white SF Symbol on a rounded square filled
/// with the tint. The same in light and dark, so a feature is recognised by its colour everywhere: the sidebar,
/// the Features page, setup, the menu-bar popups and the command bar all draw this one tile.
///
/// Pass the feature's own `PluginTint` colour. A tint that is not a colour of its own — the accent of a grey
/// theme such as Minimal — would make a pale square that glares on a dark panel, or a near-black one heavy on a
/// light page; the tile draws those as a neutral tile instead (the control fill with an ink
/// symbol), which sits quietly in both appearances. A light, coloured tint (a pastel accent in dark mode) is
/// deepened until a white symbol reads on it.
struct PluginIconTile: View {
    enum Size: CGFloat {
        /// Sidebar rows.
        case sidebar = 20
        /// List and table rows.
        case list = 28
        /// The sidebar's top row, which opens Settings.
        case hero = 32
        /// Page and card headers.
        case header = 40

        fileprivate var radius: CGFloat {
            switch self {
            case .sidebar: FrogStyle.smallRadius
            case .list, .hero: FrogStyle.controlRadius
            case .header: FrogStyle.cardRadius
            }
        }
    }

    let symbol: String
    let tint: Color
    var size: Size = .list
    @Environment(\.self) private var environment

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        let fill = Self.fill(for: tint, in: environment)
        Image(systemName: symbol)
            .font(.system(size: size.rawValue * 0.52, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(fill == nil ? FrogStyle.ink : .white)
            .frame(width: size.rawValue, height: size.rawValue)
            .background {
                if let fill { shape.fill(fill.gradient) } else { shape.fill(FrogStyle.control) }
            }
            // A hairline keeps pale tints apart from a white page.
            .overlay(shape.strokeBorder(.black.opacity(fill == nil ? 0 : 0.06), lineWidth: 0.5))
            .accessibilityHidden(true)
    }

    /// The colour the tile is filled with, or nil for a neutral tile. Exposed for tests.
    static func fill(for tint: Color, in environment: EnvironmentValues) -> Color? {
        let resolved = tint.resolve(in: environment)
        let color = NSColor(srgbRed: CGFloat(resolved.red), green: CGFloat(resolved.green), blue: CGFloat(resolved.blue), alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // A near-white or near-black grey (a grey theme's accent): no colour of its own, and a glaring or heavy
        // square. A mid grey such as `PluginTint.gray` stays the tile System Settings draws for General.
        if saturation < 0.18 && (brightness > 0.7 || brightness < 0.35) { return nil }
        // A pastel: keep its hue, deepen it until a white symbol reads on it, as the built-in tints do.
        if brightness > 0.78 && saturation < 0.6 {
            return Color(hue: Double(hue), saturation: Double(max(saturation, 0.55)), brightness: 0.68)
        }
        return tint
    }
}
