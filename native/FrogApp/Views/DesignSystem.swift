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

/// Shared adaptive colors keep the app, sheets, and controls in the same visual language.
enum FrogStyle {
    static let corner: CGFloat = 6
    static var canvas: Color { themed(\.canvas).opacity(1 - FrogAppearance.shared.settings.transparency * 0.85) }
    static var sidebar: Color { themed(\.sidebar).opacity(1 - FrogAppearance.shared.settings.transparency * 0.85) }
    static var surface: Color { themed(\.surface).opacity(1 - FrogAppearance.shared.settings.transparency * 0.78) }
    static var inset: Color { themed(\.inset).opacity(1 - FrogAppearance.shared.settings.transparency * 0.78) }
    static var border: Color { themed(\.border) }
    /// Overlays need a stable backdrop independent of the main window's translucency.
    static var panelSurface: Color { themed(\.surface) }
    static var accent: Color {
        if FrogAppearance.shared.settings.useThemeAccent == true ||
            (FrogAppearance.shared.settings.useThemeAccent == nil && FrogAppearance.shared.settings.accentHex == "A3D8AF") {
            switch FrogAppearance.shared.settings.theme ?? .frog {
            case .frog: return adaptive(light: 0x397A4C, dark: 0xA3D8AF)
            case .tokyoNight: return adaptive(light: 0x34548A, dark: 0x7AA2F7)
            case .catppuccin: return adaptive(light: 0x8839EF, dark: 0xCBA6F7)
            case .nord: return adaptive(light: 0x466A83, dark: 0x88C0D0)
            }
        }
        let rgb = UInt32(FrogAppearance.shared.settings.accentHex, radix: 16) ?? 0xA3D8AF
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    static var accentSoft: Color { accent.opacity(0.15) }
    static var selection: Color { ink.opacity(0.07) }
    static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x18261C)
    static var ink: Color { themed(\.ink) }
    static var muted: Color { themed(\.muted) }

    private struct Palette {
        let canvas, sidebar, surface, inset, border, ink, muted: UInt32
    }
    private static func palette(dark: Bool) -> Palette {
        switch (FrogAppearance.shared.settings.theme ?? .frog, dark) {
        case (.frog, false): Palette(canvas: 0xFFFFFF, sidebar: 0xF7F7F5, surface: 0xFFFFFF, inset: 0xF5F5F4, border: 0xE2E2DF, ink: 0x252525, muted: 0x73736F)
        case (.frog, true): Palette(canvas: 0x191919, sidebar: 0x151515, surface: 0x1E1E1F, inset: 0x242424, border: 0x383839, ink: 0xE8E8E8, muted: 0xA0A0A3)
        case (.tokyoNight, false): Palette(canvas: 0xE1E2E7, sidebar: 0xD5D6DB, surface: 0xEBECF0, inset: 0xDADBE0, border: 0xB4B5BD, ink: 0x343B58, muted: 0x565F89)
        case (.tokyoNight, true): Palette(canvas: 0x1A1B26, sidebar: 0x16161E, surface: 0x24283B, inset: 0x1F2335, border: 0x414868, ink: 0xC0CAF5, muted: 0xA9B1D6)
        case (.catppuccin, false): Palette(canvas: 0xEFF1F5, sidebar: 0xE6E9EF, surface: 0xFFFFFF, inset: 0xDCE0E8, border: 0xBCC0CC, ink: 0x4C4F69, muted: 0x6C6F85)
        case (.catppuccin, true): Palette(canvas: 0x1E1E2E, sidebar: 0x181825, surface: 0x313244, inset: 0x242435, border: 0x45475A, ink: 0xCDD6F4, muted: 0xBAC2DE)
        case (.nord, false): Palette(canvas: 0xECEFF4, sidebar: 0xE5E9F0, surface: 0xF8FAFC, inset: 0xE5E9F0, border: 0xC4CCD8, ink: 0x2E3440, muted: 0x4C566A)
        case (.nord, true): Palette(canvas: 0x2E3440, sidebar: 0x272D38, surface: 0x3B4252, inset: 0x323A48, border: 0x4C566A, ink: 0xECEFF4, muted: 0xD8DEE9)
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
    func frogTableSurface() -> some View {
        background(FrogStyle.surface, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
            .clipShape(RoundedRectangle(cornerRadius: FrogStyle.corner))
            .overlay(RoundedRectangle(cornerRadius: FrogStyle.corner).strokeBorder(FrogStyle.border.opacity(0.35)))
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
            .background(primary ? FrogStyle.ink : FrogStyle.surface, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
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
            .background(active ? FrogStyle.accentSoft : FrogStyle.inset, in: RoundedRectangle(cornerRadius: 4))
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
            .background(hovering ? FrogStyle.selection : FrogStyle.inset, in: RoundedRectangle(cornerRadius: 4))
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
