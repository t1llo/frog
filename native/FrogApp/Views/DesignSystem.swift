import SwiftUI
import AppKit
import FrogCore
import Observation

@Observable
final class FrogAppearance {
    static let shared = FrogAppearance()
    private(set) var settings = AppearancePreferences()
    @MainActor func apply(_ settings: AppearancePreferences) {
        self.settings = settings
        switch settings.mode ?? .system {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

private struct FrogPopupSurfaceKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var frogPopupSurface: Bool {
        get { self[FrogPopupSurfaceKey.self] }
        set { self[FrogPopupSurfaceKey.self] = newValue }
    }
}

/// Resolve within the view's environment, so a popup never inherits window translucency.
struct FrogSurfaceStyle: ShapeStyle {
    let color: Color
    let settings: AppearancePreferences
    let strength: Double
    func opacity(in environment: EnvironmentValues) -> Double {
        1 - settings.effectiveTransparency(popup: environment.frogPopupSurface,
            reduceTransparency: environment.accessibilityReduceTransparency,
            increasedContrast: environment.colorSchemeContrast == .increased) * strength
    }
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle { color.opacity(opacity(in: environment)) }
}

/// Shared adaptive colors keep the app, sheets, and controls in the same visual language.
enum FrogStyle {
    static let corner: CGFloat = 6
    static var canvas: AnyShapeStyle { adaptiveSurface(themed(\.canvas), strength: 0.85) }
    static var sidebar: AnyShapeStyle { adaptiveSurface(themed(\.sidebar), strength: 0.85) }
    static var surface: AnyShapeStyle { adaptiveSurface(themed(\.surface), strength: 0.78) }
    static var inset: AnyShapeStyle { adaptiveSurface(themed(\.inset), strength: 0.55) }
    static var opaqueCanvas: Color { themed(\.canvas) }
    private static func adaptiveSurface(_ color: Color, strength: Double) -> AnyShapeStyle {
        AnyShapeStyle(FrogSurfaceStyle(color: color, settings: FrogAppearance.shared.settings, strength: strength))
    }
    static var border: Color { themed(\.border) }
    /// An opaque reference color; popup translucency is composed over native material.
    static var panelSurface: Color { themed(\.surface) }
    static var accent: Color {
        let defaults = presetAccent
        let settings = FrogAppearance.shared.settings
        guard settings.lightPalette?["accent"] != nil || settings.darkPalette?["accent"] != nil else { return defaults }
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = (dark ? settings.darkPalette : settings.lightPalette)?["accent"]
            if let hex, let value = UInt32(hex, radix: 16) {
                return NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
            }
            var resolved = NSColor(defaults)
            appearance.performAsCurrentDrawingAppearance { resolved = resolved.usingColorSpace(.sRGB) ?? resolved }
            return resolved
        })
    }
    private static var presetAccent: Color {
        if FrogAppearance.shared.settings.useThemeAccent == true ||
            (FrogAppearance.shared.settings.useThemeAccent == nil && FrogAppearance.shared.settings.accentHex == "A3D8AF") {
            switch FrogAppearance.shared.settings.theme ?? .frog {
            case .frog: return adaptive(light: 0x397A4C, dark: 0xA3D8AF)
            case .tokyoNight: return adaptive(light: 0x34548A, dark: 0x7AA2F7)
            case .catppuccin: return adaptive(light: 0x8839EF, dark: 0xCBA6F7)
            case .nord: return adaptive(light: 0x466A83, dark: 0x88C0D0)
            case .gruvbox: return adaptive(light: 0x9D5500, dark: 0xFABD2F)
            case .dracula: return adaptive(light: 0x7040AE, dark: 0xBD93F9)
            case .rosePine: return adaptive(light: 0xA35169, dark: 0xEBBCBA)
            case .solarized: return adaptive(light: 0x217EAF, dark: 0x2AA198)
            case .everforest: return adaptive(light: 0x587D37, dark: 0xA7C080)
            case .graphite: return adaptive(light: 0x555D69, dark: 0xB8C1D0)
            }
        }
        let rgb = UInt32(FrogAppearance.shared.settings.accentHex, radix: 16) ?? 0xA3D8AF
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    static var accentSoft: Color { accent.opacity(0.15) }
    static var selection: Color { accent.opacity(0.13) }
    static var onAccent: Color {
        let settings = FrogAppearance.shared.settings
        return adaptive(light: settings.lightPalette?["on-accent"].flatMap { UInt32($0, radix: 16) } ?? presetPalette(dark: false).surface,
                        dark: settings.darkPalette?["on-accent"].flatMap { UInt32($0, radix: 16) } ?? ((settings.theme ?? .frog) == .frog ? 0x18261C : presetPalette(dark: true).canvas))
    }
    static var ink: Color { themed(\.ink) }
    static var muted: Color { themed(\.muted) }

    private struct Palette {
        var canvas, sidebar, surface, inset, border, ink, muted: UInt32
    }
    private static func palette(dark: Bool) -> Palette {
        var palette = presetPalette(dark: dark)
        let overrides = dark ? FrogAppearance.shared.settings.darkPalette : FrogAppearance.shared.settings.lightPalette
        let roles: [(String, WritableKeyPath<Palette, UInt32>)] = [
            ("background", \.canvas), ("sidebar", \.sidebar), ("surface", \.surface), ("inset", \.inset),
            ("border", \.border), ("text", \.ink), ("muted", \.muted)
        ]
        for (name, key) in roles {
            if let hex = overrides?[name], let value = UInt32(hex, radix: 16) { palette[keyPath: key] = value }
        }
        return palette
    }
    private static func presetPalette(dark: Bool) -> Palette {
        switch (FrogAppearance.shared.settings.theme ?? .frog, dark) {
        case (.frog, false): Palette(canvas: 0xFFFFFF, sidebar: 0xF7F7F5, surface: 0xFFFFFF, inset: 0xF5F5F4, border: 0xE2E2DF, ink: 0x252525, muted: 0x73736F)
        case (.frog, true): Palette(canvas: 0x191919, sidebar: 0x151515, surface: 0x1E1E1F, inset: 0x242424, border: 0x383839, ink: 0xE8E8E8, muted: 0xA0A0A3)
        case (.tokyoNight, false): Palette(canvas: 0xE1E2E7, sidebar: 0xD5D6DB, surface: 0xEBECF0, inset: 0xDADBE0, border: 0xB4B5BD, ink: 0x343B58, muted: 0x565F89)
        case (.tokyoNight, true): Palette(canvas: 0x1A1B26, sidebar: 0x16161E, surface: 0x24283B, inset: 0x1F2335, border: 0x414868, ink: 0xC0CAF5, muted: 0xA9B1D6)
        case (.catppuccin, false): Palette(canvas: 0xEFF1F5, sidebar: 0xE6E9EF, surface: 0xFFFFFF, inset: 0xDCE0E8, border: 0xBCC0CC, ink: 0x4C4F69, muted: 0x6C6F85)
        case (.catppuccin, true): Palette(canvas: 0x1E1E2E, sidebar: 0x181825, surface: 0x313244, inset: 0x242435, border: 0x45475A, ink: 0xCDD6F4, muted: 0xBAC2DE)
        case (.nord, false): Palette(canvas: 0xECEFF4, sidebar: 0xE5E9F0, surface: 0xF8FAFC, inset: 0xE5E9F0, border: 0xC4CCD8, ink: 0x2E3440, muted: 0x4C566A)
        case (.nord, true): Palette(canvas: 0x2E3440, sidebar: 0x272D38, surface: 0x3B4252, inset: 0x323A48, border: 0x4C566A, ink: 0xECEFF4, muted: 0xD8DEE9)
        case (.gruvbox, false): Palette(canvas: 0xFBF1C7, sidebar: 0xF2E5BC, surface: 0xFFF5D4, inset: 0xEBDBB2, border: 0xD5C4A1, ink: 0x3C3836, muted: 0x665C54)
        case (.gruvbox, true): Palette(canvas: 0x282828, sidebar: 0x202020, surface: 0x32302F, inset: 0x3C3836, border: 0x504945, ink: 0xEBDBB2, muted: 0xBDAE93)
        case (.dracula, false): Palette(canvas: 0xF5F2FA, sidebar: 0xECE7F3, surface: 0xFFFFFF, inset: 0xEAE4F2, border: 0xCFC4DE, ink: 0x302C43, muted: 0x6B617D)
        case (.dracula, true): Palette(canvas: 0x282A36, sidebar: 0x21222C, surface: 0x303341, inset: 0x343746, border: 0x4C5066, ink: 0xF8F8F2, muted: 0xB5B5CB)
        case (.rosePine, false): Palette(canvas: 0xFAF4ED, sidebar: 0xF2E9E1, surface: 0xFFFAF3, inset: 0xF2E9E1, border: 0xDFDAD9, ink: 0x575279, muted: 0x797593)
        case (.rosePine, true): Palette(canvas: 0x191724, sidebar: 0x16141F, surface: 0x1F1D2E, inset: 0x26233A, border: 0x403D52, ink: 0xE0DEF4, muted: 0xAAA6C5)
        case (.solarized, false): Palette(canvas: 0xFDF6E3, sidebar: 0xEEE8D5, surface: 0xFFFAEC, inset: 0xEEE8D5, border: 0xD1CBB8, ink: 0x425A61, muted: 0x657B83)
        case (.solarized, true): Palette(canvas: 0x002B36, sidebar: 0x00252F, surface: 0x073642, inset: 0x0C3D49, border: 0x28505A, ink: 0xD3D9CD, muted: 0x93A1A1)
        case (.everforest, false): Palette(canvas: 0xFDF6E3, sidebar: 0xF0EED9, surface: 0xFFFBEB, inset: 0xEAECD4, border: 0xCDD4BE, ink: 0x4F5850, muted: 0x6F7A64)
        case (.everforest, true): Palette(canvas: 0x2D353B, sidebar: 0x272E33, surface: 0x343F44, inset: 0x3D484D, border: 0x4F5B58, ink: 0xD3C6AA, muted: 0xA7B29C)
        case (.graphite, false): Palette(canvas: 0xFAFAFB, sidebar: 0xF0F1F3, surface: 0xFFFFFF, inset: 0xE9EBEF, border: 0xD9DCE2, ink: 0x242932, muted: 0x626B78)
        case (.graphite, true): Palette(canvas: 0x17191D, sidebar: 0x121418, surface: 0x202329, inset: 0x272B32, border: 0x393F49, ink: 0xE4E7EC, muted: 0xA1A9B5)
        }
    }
    private static func themed(_ key: KeyPath<Palette, UInt32>) -> Color {
        adaptive(light: palette(dark: false)[keyPath: key], dark: palette(dark: true)[keyPath: key])
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

extension View {
    func frogPanel(corner: CGFloat = 12) -> some View {
        modifier(FrogPanelSurface(corner: corner))
    }
    func frogTableSurface() -> some View {
        background(FrogStyle.surface, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
            .clipShape(RoundedRectangle(cornerRadius: FrogStyle.corner))
            .overlay(RoundedRectangle(cornerRadius: FrogStyle.corner).strokeBorder(FrogStyle.border.opacity(0.35)))
    }
}

private struct FrogPanelSurface: ViewModifier {
    let corner: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let settings = FrogAppearance.shared.settings
        let amount = settings.effectiveTransparency(popup: true, reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased)
        content.background {
            FrogWindowMaterial(popup: true, cornerRadius: corner)
                .overlay(FrogStyle.panelSurface.opacity(1 - amount * 0.5))
        }
        .foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(contrast == .increased ? FrogStyle.ink : FrogStyle.border.opacity(0.8)))
        .preferredColorScheme(settings.mode == .dark ? .dark : settings.mode == .light ? .light : nil)
        .environment(\.frogPopupSurface, true)
    }
}

struct FrogButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .foregroundStyle(primary ? FrogStyle.panelSurface : FrogStyle.ink)
            .background(primary ? AnyShapeStyle(FrogStyle.ink) : FrogStyle.surface, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
            .overlay(RoundedRectangle(cornerRadius: FrogStyle.corner).strokeBorder(primary ? .clear : FrogStyle.border.opacity(0.6), lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: FrogStyle.corner))
    }
}

struct FrogCard<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(FrogStyle.surface, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
            .overlay(RoundedRectangle(cornerRadius: FrogStyle.corner)
                .strokeBorder(contrast == .increased ? FrogStyle.muted : FrogStyle.border, lineWidth: 1))
    }
}

struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text(title)).font(.system(size: 19, weight: .semibold)).tracking(-0.4)
                    .foregroundStyle(FrogStyle.ink).accessibilityAddTraits(.isHeader)
                if !subtitle.isEmpty { Text(L10n.text(subtitle)).font(.system(size: 13)).foregroundStyle(FrogStyle.muted)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .overlay { WindowDragRegion().accessibilityHidden(true) }
            actions
        }.frame(minHeight: 32)
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, subtitle: String) {
        self.title = title; self.subtitle = subtitle; self.actions = EmptyView()
    }
}

struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(20).frame(maxWidth: 1080)
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

struct SectionCaption: View {
    let text: String
    var body: some View {
        Text(L10n.text(text)).font(.system(size: 11, weight: .medium))
            .foregroundStyle(FrogStyle.muted).accessibilityAddTraits(.isHeader)
    }
}

struct SymbolTile: View {
    let symbol: String
    var size: CGFloat = 40
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.4, weight: .medium))
            .foregroundStyle(FrogStyle.muted).frame(width: size, height: size)
            .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
            .accessibilityHidden(true)
    }
}

struct FrogBadge: View {
    let text: String
    var active = false
    var body: some View {
        Text(L10n.text(text)).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(active ? FrogStyle.accent : FrogStyle.muted)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(active ? AnyShapeStyle(FrogStyle.accentSoft) : FrogStyle.inset, in: RoundedRectangle(cornerRadius: 4))
    }
}

struct ShortcutBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium, design: .monospaced))
            .padding(.horizontal, 7).modifier(CompactActionSurface())
            .accessibilityLabel("Shortcut: \(text)")
    }
}

struct CompactActionSurface: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content.frame(height: 24)
            .foregroundStyle(FrogStyle.ink)
            .background(hovering ? AnyShapeStyle(FrogStyle.selection) : FrogStyle.inset, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(FrogStyle.border.opacity(0.6)))
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .onHover { hovering = $0 }
    }
}

struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text(title)).font(.system(size: 12, weight: .medium)).foregroundStyle(FrogStyle.ink)
            content.textFieldStyle(.plain).padding(8)
                .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(FrogStyle.border, lineWidth: 1))
        }
    }
}

/// Full-width menu controls with the same inset surface as editable fields.
struct FrogMenu<Content: View>: View {
    let title: String
    let value: String
    var symbol = "chevron.up.chevron.down"
    @ViewBuilder var content: Content

    var body: some View {
        CompactRow(title: title) {
            CompactMenu(value: value) { content }
                .accessibilityLabel(L10n.text(title)).accessibilityValue(value)
        }
    }
}

struct IconAction: View {
    let title: String
    let symbol: String
    var destructive = false
    var bordered = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            if bordered {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                    .frame(width: 24).modifier(CompactActionSurface())
            } else {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(destructive ? Color.red : hovering ? FrogStyle.accent : FrogStyle.muted)
                .frame(width: 26, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: FrogStyle.corner))
            }
        }.buttonStyle(.plain).onHover { hovering = $0 }.accessibilityLabel(L10n.text(title)).help(L10n.text(title))
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    let description: String
    @ViewBuilder var control: Control
    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text(title)).font(.system(size: 12, weight: .medium)).foregroundStyle(FrogStyle.ink)
                Text(L10n.text(description)).font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            control
        }
    }
}

struct FrogEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            SymbolTile(symbol: symbol, size: 32)
            Text(L10n.text(title)).font(.system(size: 14, weight: .medium)).foregroundStyle(FrogStyle.ink)
            Text(L10n.text(message)).font(.system(size: 13)).foregroundStyle(FrogStyle.muted)
                .multilineTextAlignment(.center).lineSpacing(4).frame(maxWidth: 340)
        }.frame(maxWidth: .infinity).padding(.vertical, 44).padding(.horizontal, 24)
    }
}

struct FrogMark: View {
    private static let image = FrogResources.bundle.url(forResource: "FrogLogo", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) } ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
    var body: some View {
        Image(nsImage: Self.image).resizable().interpolation(.high).scaledToFit()
            .frame(width: 46, height: 46).accessibilityHidden(true)
    }
}
