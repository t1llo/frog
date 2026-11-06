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

/// Frog's design tokens. docs/design.md has the rules; `StyleTokenScanTests` checks the ones code can.
enum FrogStyle {
    // Corners nest: a shape inside another has the outer radius minus the gap between them, so both curves
    // share one centre and the gap stays even all the way round. Every row, field and highlight is
    // `controlRadius`, and each container is that plus the gap its content keeps from its edge.

    /// Key caps, badges, colour swatches: small marks inside a control.
    static let smallRadius: CGFloat = 4
    /// Rows and their highlight, fields, menu rows, symbol tiles and blocks inside a card or popup.
    /// Buttons, search boxes in a page, segmented controls and switches are capsules instead.
    static let controlRadius: CGFloat = 10
    /// The gap between a card's edge and the rows of a list inside it.
    static let listInset: CGFloat = 4
    /// Cards, grouped settings, lists and previews: their rows sit `listInset` in.
    static let cardRadius: CGFloat = controlRadius + listInset
    /// The gap between a popup's edge and its search field, rows and blocks.
    static let panelInset: CGFloat = 8
    /// Popups, menus and floating panels: their content sits `panelInset` in.
    static let panelRadius: CGFloat = controlRadius + panelInset
    /// The gap between a popup's edge and a card inside it, such as the menu-bar menus' groups.
    static let panelCardInset: CGFloat = panelRadius - cardRadius
    /// The main window's corner: macOS 26 rounds a window with a toolbar to about 28 points (measured).
    static var windowRadius: CGFloat {
        if #available(macOS 26, *) { return 28 }
        return 10
    }
    /// The main window's sidebar panel, `sidebarInset` inside the window's corner.
    static var sidebarRadius: CGFloat { max(windowRadius - sidebarInset, cardRadius) }
    /// The gap between the sidebar's edge and its rows.
    static var sidebarRowInset: CGFloat { sidebarRadius - controlRadius }
    /// Small floating status pills, 36 points tall.
    static let pillRadius: CGFloat = 18
    /// Buttons, fields, dropdowns, search boxes and segmented controls.
    static let controlHeight: CGFloat = 28
    /// The same controls in popups, panel headers and dense rows.
    static let compactHeight: CGFloat = 24
    /// The least height of a `FrogRow` in a `FrogSection` card: Rex's 38-point settings row.
    static let rowHeight: CGFloat = 38
    /// Where a `FrogRow`'s text and its separator start inside a section card, and where a section's heading and
    /// the note under a card line up: 10 from the card's edge, as in Rex.
    static let rowInset: CGFloat = 10
    /// A row of the main window's sidebar.
    static let sidebarRowHeight: CGFloat = 32
    /// How far the main window's sidebar panel floats in from the window's edges.
    static let sidebarInset: CGFloat = 8
    /// The bar above a page that holds back and forward and the page's title.
    static let toolbarHeight: CGFloat = 52
    /// How far below the toolbar its veil fades out over a scrolled page: the gap above a page's first section,
    /// so at rest the veil covers nothing.
    static let toolbarFade: CGFloat = space12
    /// Space around a page's content (`FrogPage`) and between its sections.
    static let pagePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 30
    /// The spacing scale for gaps, stacks and paddings: 2 between a title and its caption, 4 inside a label,
    /// 6 and 8 between controls, 10 between blocks inside a card, 12 between a row's icon, text and control,
    /// 16 between groups. docs/design.md says which goes where.
    static let space2: CGFloat = 2
    static let space4: CGFloat = 4
    static let space6: CGFloat = 6
    static let space8: CGFloat = 8
    static let space10: CGFloat = 10
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    /// Where content starts inside a card, a section card, and a popup's header, body and footer: 14 from the
    /// edge. A list adds `listInset` around its rows and `rowPadding` inside them, which together make the
    /// same 14, so a row's text lines up with the header's.
    static let cardPadding: CGFloat = 14
    static let rowPadding: CGFloat = cardPadding - listInset
    /// Space around a sheet's content, its header and its buttons.
    static let sheetPadding: CGFloat = 20
    /// The widest a settings page's column grows (`FrogPage`), so rows stay readable in a wide window.
    static let pageWidth: CGFloat = 720
    /// Dashboards, tables and grids (`FrogPage(width: FrogStyle.wideWidth)`, `PageScroll`).
    static let wideWidth: CGFloat = 1080
    /// A hovered row or control. Neutral, so it reads the same in every theme; `selection` marks what is chosen.
    static var hover: Color { inkLayer(light: 0.05, dark: 0.05) }
    /// A control held down.
    static var pressed: Color { ink.opacity(0.1) }
    /// Cards and section cards: a thin layer of the text colour over the page, so a card lifts off the
    /// background in every theme without a border.
    static var card: Color { inkLayer(light: 0.035, dark: 0.05) }
    /// Buttons, fields, dropdowns and search boxes: one step above a card.
    static var control: Color { inkLayer(light: 0.06, dark: 0.1) }
    /// The faint line colour handed to plugin pages' stylesheet. Frog's own cards set their rows apart by space.
    static var separator: Color { inkLayer(light: 0.09, dark: 0.15) }
    /// The open page in the sidebar: neutral, like the hover, only stronger.
    static var sidebarSelection: Color { selection }
    /// The faint edge of a pane or popup, as Rex draws it: the sidebar panel, `frogPanel()` and the window switcher.
    static var hairline: Color { inkLayer(light: 0.1, dark: 0.12) }
    /// Glass panels: the light that catches the top of the pane, and its brighter top edge.
    static var glassSheen: Color { whiteLayer(light: 0.18, dark: 0.05) }
    static var glassEdge: Color { whiteLayer(light: 0.7, dark: 0.22) }
    private static func whiteLayer(light: Double, dark: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor.white.withAlphaComponent(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }
    private static func inkLayer(light: Double, dark: Double) -> Color {
        let ink = ink
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            var resolved = NSColor(ink)
            appearance.performAsCurrentDrawingAppearance { resolved = resolved.usingColorSpace(.sRGB) ?? resolved }
            return resolved.withAlphaComponent(isDark ? dark : light)
        })
    }
    static var canvas: AnyShapeStyle { adaptiveSurface(themed(\.canvas), strength: 0.85) }
    static var sidebar: AnyShapeStyle { adaptiveSurface(themed(\.sidebar), strength: 0.85) }
    static var surface: AnyShapeStyle { adaptiveSurface(themed(\.surface), strength: 0.78) }
    static var inset: AnyShapeStyle { adaptiveSurface(themed(\.inset), strength: 0.55) }
    static var opaqueCanvas: Color { themed(\.canvas) }
    static var opaqueInset: Color { themed(\.inset) }
    static var opaqueSidebar: Color { themed(\.sidebar) }
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
    private static var usesThemeAccent: Bool {
        let settings = FrogAppearance.shared.settings
        return settings.useThemeAccent == true || (settings.useThemeAccent == nil && settings.accentHex == "A3D8AF")
    }
    private static var presetAccent: Color {
        if usesThemeAccent {
            let value = themeAccent(FrogAppearance.shared.settings.effectiveTheme)
            return adaptive(light: value.light, dark: value.dark)
        }
        let rgb = UInt32(FrogAppearance.shared.settings.accentHex, radix: 16) ?? 0xA3D8AF
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    private static func themeAccent(_ theme: AppearancePreferences.Theme) -> (light: UInt32, dark: UInt32) {
        switch theme {
        case .frog: (0x397A4C, 0xA3D8AF)
        case .tokyoNight: (0x34548A, 0x7AA2F7)
        case .catppuccin: (0x8839EF, 0xCBA6F7)
        case .nord: (0x466A83, 0x88C0D0)
        case .gruvbox: (0x9D5500, 0xFABD2F)
        case .dracula: (0x7040AE, 0xBD93F9)
        case .rosePine: (0xA35169, 0xEBBCBA)
        case .solarized: (0x217EAF, 0x2AA198)
        case .everforest: (0x587D37, 0xA7C080)
        case .graphite: (0x555D69, 0xB8C1D0)
        case .minimal: (0x3C4149, 0xD0D6E0)
        // After palettes of the Rex terminal.
        case .wool: (0x0B60ED, 0x4582F9)
        case .pewter: (0x696969, 0x898989)
        case .deepSea: (0x2F7D68, 0x57E7C1)
        case .inkwell: (0x5A6FA1, 0x88A7F1)
        case .polarNight: (0x5E7487, 0x96B7D6)
        case .eggshell: (0x1D6ACE, 0x3D7FD4)
        }
    }
    static var accentSoft: Color { accent.opacity(0.15) }
    /// Text and symbols on an accent fill: the primary button, a chosen segment. Light accents of dark themes
    /// take the dark surface colour, dark accents of light themes take white.
    static var onAccent: Color { panelSurface }
    /// The track of a switch that is off: a neutral grey in every theme.
    static var switchTrack: Color { inkLayer(light: 0.12, dark: 0.18) }
    /// The track of a switch that is on. The accent when it has a colour of its own; a near-grey accent (Minimal,
    /// Graphite, Pewter) would look like the off track or like ink, so those take the theme's green instead.
    static var switchOn: Color {
        let accent = accent, good = good
        return Color(nsColor: NSColor(name: nil) { appearance in
            var resolved = NSColor(accent), fallback = NSColor(good)
            appearance.performAsCurrentDrawingAppearance {
                resolved = resolved.usingColorSpace(.sRGB) ?? resolved
                fallback = fallback.usingColorSpace(.sRGB) ?? fallback
            }
            return resolved.saturationComponent < 0.22 ? fallback : resolved
        })
    }
    /// An on switch in a window that is not in front: grey, as macOS draws it, but darker than off.
    static var switchOnInactive: Color { inkLayer(light: 0.38, dark: 0.42) }
    /// How a disabled control is drawn: its normal look, faded. Buttons, switches, checkboxes and dropdowns alike.
    static let disabledOpacity: Double = 0.4
    /// What is chosen: a neutral raised layer, as Rex marks its selected tab and row. The accent shows state.
    static var selection: Color { inkLayer(light: 0.08, dark: 0.1) }
    static var ink: Color { themed(\.ink) }
    static var muted: Color { themed(\.muted) }
    /// A text field's placeholder: tertiary, a step lighter than `muted`, so an empty field never looks filled in.
    static var placeholder: Color { muted.opacity(0.72) }

    /// Status tones from each theme's own palette: comfortably fine, worth watching, at the limit.
    static var good: Color { tone(\.good, "good") }
    static var warning: Color { tone(\.warning, "warning") }
    static var critical: Color { tone(\.critical, "critical") }
    /// For loads and limits where low is unremarkable: accent, then warning, then critical.
    static func level(_ fraction: Double, warning: Double = 0.7, critical: Double = 0.9) -> Color {
        fraction >= critical ? Self.critical : fraction >= warning ? Self.warning : accent
    }

    /// Graph lines keep one colour each, whatever the level they show. Minimal's own accent is a
    /// neutral grey that would read as a reference line, so there the main line is indigo.
    static var series: Color {
        let settings = FrogAppearance.shared.settings
        let custom = settings.lightPalette?["accent"] != nil || settings.darkPalette?["accent"] != nil
        guard settings.effectiveTheme == .minimal, usesThemeAccent, !custom else { return accent }
        return adaptive(light: 0x5E6AD2, dark: 0x7B84EC)
    }
    /// The second line of a graph: a soft ink, which reads against the accent of every theme in light and dark.
    /// Warning and critical colours stay with meters.
    static var seriesSecondary: Color { ink.opacity(0.55) }

    private struct Tones {
        var good, warning, critical: (light: UInt32, dark: UInt32)
    }
    private static func presetTones(_ theme: AppearancePreferences.Theme) -> Tones {
        switch theme {
        case .frog: Tones(good: (0x2F8F4E, 0x8FD9A0), warning: (0xB7791F, 0xE8B866), critical: (0xC8443C, 0xF07F78))
        case .tokyoNight: Tones(good: (0x33635C, 0x9ECE6A), warning: (0x8F5E15, 0xE0AF68), critical: (0x8C4351, 0xF7768E))
        case .catppuccin: Tones(good: (0x40A02B, 0xA6E3A1), warning: (0xDF8E1D, 0xF9E2AF), critical: (0xD20F39, 0xF38BA8))
        case .nord: Tones(good: (0x4F7F53, 0xA3BE8C), warning: (0xA9791C, 0xEBCB8B), critical: (0xBF616A, 0xD9737D))
        case .gruvbox: Tones(good: (0x79740E, 0xB8BB26), warning: (0xAF3A03, 0xFE8019), critical: (0x9D0006, 0xFB4934))
        case .dracula: Tones(good: (0x2E8B4E, 0x50FA7B), warning: (0xB26A1B, 0xFFB86C), critical: (0xC93B3B, 0xFF5555))
        case .rosePine: Tones(good: (0x286983, 0x9CCFD8), warning: (0xC47F1A, 0xF6C177), critical: (0xB4637A, 0xEB6F92))
        case .solarized: Tones(good: (0x859900, 0x859900), warning: (0xB58900, 0xB58900), critical: (0xDC322F, 0xDC322F))
        case .everforest: Tones(good: (0x6F8A00, 0xA7C080), warning: (0xC98F00, 0xDBBC7F), critical: (0xE0473F, 0xE67E80))
        case .graphite: Tones(good: (0x3E8E5A, 0x7FC796), warning: (0xB7791F, 0xDDB46A), critical: (0xC4453F, 0xE87C7C))
        case .minimal: Tones(good: (0x2B8A57, 0x4CB782), warning: (0xB7791F, 0xF2C94C), critical: (0xD0443C, 0xEB5757))
        case .wool: Tones(good: (0x14661E, 0x46BD3F), warning: (0x995C00, 0xCE9923), critical: (0xC6242C, 0xFF7368))
        // Pewter is grey through and through, so status keeps Graphite's tones to stay readable.
        case .pewter: Tones(good: (0x3E8E5A, 0x7FC796), warning: (0xB7791F, 0xDDB46A), critical: (0xC4453F, 0xE87C7C))
        case .deepSea: Tones(good: (0x3F8D6A, 0x59CA98), warning: (0x927D43, 0xD1B361), critical: (0xC85E5C, 0xDD6866))
        case .inkwell: Tones(good: (0x608D68, 0x83C08D), warning: (0x947C4F, 0xD5B171), critical: (0xC3626D, 0xD86C79))
        case .polarNight: Tones(good: (0x638865, 0x86B989), warning: (0x937C53, 0xD4B277), critical: (0xBE646E, 0xD36F7A))
        case .eggshell: Tones(good: (0x357C3B, 0x5FB066), warning: (0x906302, 0xD19A2E), critical: (0xB2493C, 0xE0705F))
        }
    }
    private static func tone(_ key: KeyPath<Tones, (light: UInt32, dark: UInt32)>, _ name: String) -> Color {
        let settings = FrogAppearance.shared.settings, preset = presetTones(settings.effectiveTheme)[keyPath: key]
        return adaptive(light: settings.lightPalette?[name].flatMap { UInt32($0, radix: 16) } ?? preset.light,
                        dark: settings.darkPalette?[name].flatMap { UInt32($0, radix: 16) } ?? preset.dark)
    }

    private struct Palette {
        var canvas, sidebar, surface, inset, border, ink, muted: UInt32
    }
    private static func palette(dark: Bool) -> Palette {
        var palette = presetPalette(FrogAppearance.shared.settings.effectiveTheme, dark: dark)
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
    private static func presetPalette(_ theme: AppearancePreferences.Theme, dark: Bool) -> Palette {
        switch (theme, dark) {
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
        case (.minimal, false): Palette(canvas: 0xFFFFFF, sidebar: 0xF5F5F6, surface: 0xFFFFFF, inset: 0xF0F0F2, border: 0xE4E4E8, ink: 0x23252A, muted: 0x6B6F76)
        case (.minimal, true): Palette(canvas: 0x0F1011, sidebar: 0x08090A, surface: 0x141516, inset: 0x1C1C1F, border: 0x2A2C32, ink: 0xF7F8F8, muted: 0x8A8F98)
        // After palettes of the Rex terminal: Merino, Silver Point, Abyssal Trench, Ink Meridian, Midnight Tundra and
        // Porcelain Morning. A palette Rex has in one appearance only borrows the other's neutrals from Porcelain
        // Morning or Silver Point Dark, with its accent and tones made readable on them.
        case (.wool, false): Palette(canvas: 0xF6F7F9, sidebar: 0xECEEF2, surface: 0xF8F9FB, inset: 0xFAFBFC, border: 0xD1D2D5, ink: 0x202328, muted: 0x6A6D71)
        case (.wool, true): Palette(canvas: 0x0C0E11, sidebar: 0x131519, surface: 0x101319, inset: 0x1E2023, border: 0x424549, ink: 0xE7EDF3, muted: 0x83878B)
        case (.pewter, false): Palette(canvas: 0xF4F4F4, sidebar: 0xEAEAEA, surface: 0xF6F7F9, inset: 0xF7F9FA, border: 0xCFCFCF, ink: 0x1A1A1A, muted: 0x6A6A6A)
        case (.pewter, true): Palette(canvas: 0x131313, sidebar: 0x1A1A1A, surface: 0x171717, inset: 0x232323, border: 0x474747, ink: 0xB4B4B4, muted: 0x898989)
        case (.deepSea, false): Palette(canvas: 0xF7F9FA, sidebar: 0xEEEFF0, surface: 0xF9FBFC, inset: 0xFAFBFC, border: 0xD0D3D6, ink: 0x303A42, muted: 0x666E75)
        case (.deepSea, true): Palette(canvas: 0x07101B, sidebar: 0x0E1621, surface: 0x0B141E, inset: 0x17202B, border: 0x3A4652, ink: 0xBCCCD8, muted: 0x798894)
        case (.inkwell, false): Palette(canvas: 0xF7F9FA, sidebar: 0xEEEFF0, surface: 0xF9FBFC, inset: 0xFAFBFC, border: 0xD0D3D6, ink: 0x303A42, muted: 0x666E75)
        case (.inkwell, true): Palette(canvas: 0x111622, sidebar: 0x181D28, surface: 0x161A25, inset: 0x222632, border: 0x444A59, ink: 0xCDD6E9, muted: 0x858D9E)
        case (.polarNight, false): Palette(canvas: 0xF7F9FA, sidebar: 0xEEEFF0, surface: 0xF9FBFC, inset: 0xFAFBFC, border: 0xD0D3D6, ink: 0x303A42, muted: 0x666E75)
        case (.polarNight, true): Palette(canvas: 0x0F141B, sidebar: 0x161B21, surface: 0x13181E, inset: 0x1F242B, border: 0x424951, ink: 0xCBD4DD, muted: 0x838B94)
        case (.eggshell, false): Palette(canvas: 0xF7F9FA, sidebar: 0xEEEFF0, surface: 0xF9FBFC, inset: 0xFAFBFC, border: 0xD0D3D6, ink: 0x303A42, muted: 0x666E75)
        case (.eggshell, true): Palette(canvas: 0x131313, sidebar: 0x1A1A1A, surface: 0x171717, inset: 0x232323, border: 0x474747, ink: 0xB4B4B4, muted: 0x898989)
        }
    }
    /// A theme's own colours in one appearance, whatever theme is in use, for the theme picker's cards.
    struct ThemeSwatch {
        let canvas, surface, ink, muted, accent: Color
        /// The row of dots under a card's sample: the theme's text, accent and status colours.
        let dots: [Color]
    }
    static func swatch(_ theme: AppearancePreferences.Theme, dark: Bool) -> ThemeSwatch {
        func color(_ value: UInt32) -> Color {
            Color(.sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
        }
        let palette = presetPalette(theme, dark: dark), tones = presetTones(theme), accent = themeAccent(theme)
        let pick = { (pair: (light: UInt32, dark: UInt32)) in color(dark ? pair.dark : pair.light) }
        return ThemeSwatch(canvas: color(palette.canvas), surface: color(palette.surface), ink: color(palette.ink),
                           muted: color(palette.muted), accent: pick(accent),
                           dots: [color(palette.ink), pick(tones.critical), pick(tones.good), pick(tones.warning), pick(accent), color(palette.muted)])
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

/// Frog's type scale. Every text in the app uses one of these; docs/design.md says which goes where.
enum FrogType {
    /// Large titles inside a page, such as a dashboard's headline. A page's own title is `toolbarTitle`.
    static let title = Font.system(size: 19, weight: .semibold)
    /// The open page's title in the bar above it.
    static let toolbarTitle = Font.system(size: 15, weight: .semibold)
    /// Row titles in section cards and sidebar rows.
    static let row = Font.system(size: 13)
    /// The open sidebar row, and a hero row's title.
    static let rowMedium = Font.system(size: 13, weight: .semibold)
    /// Section headings, popup titles and empty-state titles.
    static let section = Font.system(size: 13, weight: .semibold)
    /// Page subtitles and empty-state messages.
    static let lead = Font.system(size: 13)
    /// Row titles, list items, field text, dropdown values and menu rows.
    static let body = Font.system(size: 13)
    /// Buttons and the titles of settings and cards.
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    /// Row descriptions, secondary lines and compact controls.
    static let small = Font.system(size: 11)
    /// Small group labels above content, and compact buttons.
    static let label = Font.system(size: 11, weight: .medium)
    /// Timestamps, paths, counts, badges and footnotes.
    static let caption = Font.system(size: 10)
    static let mono = Font.system(size: 11, design: .monospaced)
}

extension View {
    /// Popups and floating panels. `pill` is for 36-point status pills.
    func frogPanel(pill: Bool = false) -> some View {
        modifier(FrogPanelSurface(corner: pill ? FrogStyle.pillRadius : FrogStyle.panelRadius, pill: pill))
    }
    /// The card every grouped surface uses: lists, tables, settings groups, previews.
    func frogTableSurface() -> some View {
        modifier(FrogCardSurface())
    }
    /// The fill and hairline every bordered control shares: secondary buttons, dropdowns, fields, search boxes,
    /// segmented controls and shortcut badges.
    /// `radius` overrides the corner, as for a field nested in a panel's corner (`FrogStyle.nestedRadius`).
    func frogControlSurface(hovering: Bool = false, pressed: Bool = false, height: CGFloat? = FrogStyle.controlHeight, capsule: Bool = false, radius: CGFloat? = nil) -> some View {
        modifier(FrogControlSurface(hovering: hovering, pressed: pressed, height: height, capsule: capsule, radius: radius))
    }
    /// A row that highlights on hover and when chosen, as in lists, menus and the sidebar.
    func frogRowHighlight(hovering: Bool, selected: Bool = false) -> some View {
        modifier(RowHighlight(hovering: hovering, selected: selected))
    }
}

private struct RowHighlight: ViewModifier {
    let hovering: Bool
    let selected: Bool
    @Environment(\.frogKeyboardSurface) private var keyboardSurface
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: FrogStyle.controlRadius, style: .continuous)
        content.background {
            shape.fill(selected ? FrogStyle.selection : hovering ? FrogStyle.hover : .clear)
                .animation(FrogMotion.hover(hovering, keyboardSurface: keyboardSurface), value: hovering)
        }.contentShape(shape)
    }
}

extension View {
    /// A list row that keeps its own hover state. Lists in a card set their rows 1–2 points apart, inset 6
    /// from the card's edge.
    func frogHoverRow(selected: Bool = false) -> some View {
        modifier(HoverRowHighlight(selected: selected))
    }
}

private struct HoverRowHighlight: ViewModifier {
    var selected = false
    @State private var hovering = false
    func body(content: Content) -> some View {
        content.frogRowHighlight(hovering: hovering, selected: selected).onHover { hovering = $0 }
    }
}

/// Choosing items in a list, such as files to remove. Settings that turn something on or off use a switch.
struct FrogCheckboxStyle: ToggleStyle {
    func makeBody(configuration: ToggleStyleConfiguration) -> FrogCheckbox { FrogCheckbox(configuration: configuration) }
}

struct FrogCheckbox: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: FrogStyle.smallRadius)
                        .fill(configuration.isOn ? AnyShapeStyle(FrogStyle.accent) : FrogStyle.inset)
                    RoundedRectangle(cornerRadius: FrogStyle.smallRadius)
                        .strokeBorder(configuration.isOn ? Color.clear : FrogStyle.border)
                    // The mark grows in from 0.8 as the box fills; Reduce Motion keeps only the fade.
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(FrogStyle.panelSurface)
                        .scaleEffect(configuration.isOn || reduceMotion ? 1 : 0.8).opacity(configuration.isOn ? 1 : 0)
                        .accessibilityHidden(true)
                }.frame(width: 14, height: 14).animation(FrogMotion.check, value: configuration.isOn).opacity(enabled ? 1 : FrogStyle.disabledOpacity)
                configuration.label
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(configuration.isOn ? [.isButton, .isSelected] : .isButton)
    }
}

extension ToggleStyle where Self == FrogCheckboxStyle {
    static var frogCheckbox: FrogCheckboxStyle { FrogCheckboxStyle() }
}

/// The on/off switch: a 36 by 20 capsule track with a round knob 2 points in. On fills the track with
/// `switchOn` (the accent, or the theme's green when the accent is a grey that would not read as "on"); off is
/// the neutral `switchTrack`. In a window that is not in front an on switch keeps a darker grey than off, so the
/// two still differ by more than the knob's side. Every on/off setting uses it; the label is the row's title.
struct FrogSwitchStyle: ToggleStyle {
    func makeBody(configuration: ToggleStyleConfiguration) -> FrogSwitch { FrogSwitch(configuration: configuration) }
}

extension ToggleStyle where Self == FrogSwitchStyle {
    static var frogSwitch: FrogSwitchStyle { FrogSwitchStyle() }
}

struct FrogSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.compactRowTitle) private var rowTitle
    @Environment(\.self) private var values

    /// `.labelsHidden()` reaches a custom style only through `labelsVisibility`, which macOS 14 lacks.
    private var labelsShown: Bool {
        if #available(macOS 15, *) { return values.labelsVisibility != .hidden }
        return true
    }

    /// The track and knob, the size of macOS's own small switch: 36 by 20, or 28 by 16 for `.mini`.
    static func size(mini: Bool) -> CGSize { mini ? CGSize(width: 28, height: 16) : CGSize(width: 36, height: 20) }

    var body: some View {
        let on = configuration.isOn
        let size = Self.size(mini: controlSize == .mini)
        let knob = size.height - 4
        let active = activeState == .key || activeState == .active
        HStack(spacing: FrogStyle.space8) {
            // In a row the row's title names the switch, as with `.labelsHidden()`.
            if rowTitle == nil && labelsShown { configuration.label }
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule(style: .continuous).fill(on ? (active ? FrogStyle.switchOn : FrogStyle.switchOnInactive) : FrogStyle.switchTrack)
                Circle().fill(Color.white)
                    .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                    .frame(width: knob, height: knob).padding(2)
            }
            .frame(width: size.width, height: size.height)
            .overlay { if contrast == .increased { Capsule(style: .continuous).strokeBorder(FrogStyle.ink.opacity(0.6)) } }
            .animation(reduceMotion ? nil : FrogMotion.slide, value: on)
            .contentShape(Capsule())
            .onTapGesture { if enabled { configuration.isOn.toggle() } }
        }
        .opacity(enabled ? 1 : FrogStyle.disabledOpacity)
        // VoiceOver reads a system switch named by the toggle's label, even where the label is not drawn. The
        // explicit style keeps the stand-in from drawing this style again.
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch) }
    }
}

private struct FrogCardSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: FrogStyle.cardRadius, style: .continuous)
        // No border: the card is a thin layer over the page. Increase Contrast brings the outline back.
        content.environment(\.frogDenseContainer, true)
            .background(FrogStyle.card, in: shape).clipShape(shape)
            .overlay { if contrast == .increased { shape.strokeBorder(FrogStyle.muted) } }
    }
}

private struct FrogControlSurface: ViewModifier {
    let hovering: Bool
    let pressed: Bool
    let height: CGFloat?
    /// Buttons and search boxes are capsules in Rex; fields keep the rounded rectangle.
    let capsule: Bool
    let radius: CGFloat?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.frogKeyboardSurface) private var keyboardSurface
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? (capsule ? (height ?? FrogStyle.controlHeight) / 2 : FrogStyle.controlRadius), style: .continuous)
        content.frame(minHeight: height)
            .background {
                ZStack {
                    shape.fill(FrogStyle.control)
                    shape.fill(pressed ? FrogStyle.pressed : hovering ? FrogStyle.hover : .clear)
                        .animation(FrogMotion.hover(hovering || pressed, keyboardSurface: keyboardSurface), value: hovering || pressed)
                }
            }
            // A filled control needs no outline; Increase Contrast brings it back.
            .overlay { if contrast == .increased { shape.strokeBorder(FrogStyle.muted) } }
            .contentShape(shape)
    }
}

private struct FrogPanelSurface: ViewModifier {
    let corner: CGFloat
    /// A status pill: a true capsule. A continuous corner as large as half the height flattens the round ends
    /// into short straight edges, which read as stray strokes beside the pill.
    var pill = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let settings = FrogAppearance.shared.settings
        let shape = RoundedRectangle(cornerRadius: corner, style: pill ? .circular : .continuous)
        let glass = settings.effectiveTransparency(popup: true, reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased) > 0
        content.environment(\.frogDenseContainer, true)
        .frogSurface(.hud, cornerRadius: corner, cornerStyle: pill ? .circular : .continuous)
        .foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent)
        .clipShape(shape)
        // A faint edge, as Rex outlines its panes; glass is lit along its top edge; Increase Contrast makes it solid.
        .overlay {
            if contrast == .increased {
                shape.strokeBorder(FrogStyle.ink)
            } else if glass {
                shape.strokeBorder(LinearGradient(colors: [FrogStyle.glassEdge, FrogStyle.hairline, FrogStyle.hairline], startPoint: .top, endPoint: .bottom))
            } else {
                shape.strokeBorder(FrogStyle.hairline)
            }
        }
        .preferredColorScheme(settings.mode == .dark ? .dark : settings.mode == .light ? .light : nil)
        .environment(\.frogPopupSurface, true)
    }
}

/// Frog's one button. The main window sets the secondary kind for every button inside it.
struct FrogButtonStyle: ButtonStyle {
    enum Kind {
        /// The one main action of a page, sheet or card.
        case primary
        /// Every other action.
        case secondary
        /// Actions that sit beside content, such as Reset or Skip: no fill until hovered.
        case ghost
        /// Removes or deletes something.
        case destructive
    }
    var kind: Kind = .secondary
    /// 24 points tall, for popups, panel headers and dense rows.
    var compact = false

    init(_ kind: Kind = .secondary, compact: Bool = false) { self.kind = kind; self.compact = compact }
    init(primary: Bool) { kind = primary ? .primary : .secondary }

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        FrogButtonBody(configuration: configuration, kind: kind, compact: compact)
    }
}

extension ButtonStyle where Self == FrogButtonStyle {
    static func frog(_ kind: FrogButtonStyle.Kind = .secondary, compact: Bool = false) -> FrogButtonStyle {
        FrogButtonStyle(kind, compact: compact)
    }
}

extension View {
    /// Disables a control and says why: `reason` nil enables it; otherwise the control fades and its tooltip and
    /// VoiceOver hint give the reason ("Choose a model first"). Use it for a disabled primary action, so it never
    /// sits there greyed out without a word.
    func frogDisabled(_ reason: String?) -> some View {
        disabled(reason != nil)
            .help(reason.map { L10n.text($0) } ?? "")
            .accessibilityHint(reason.map { L10n.text($0) } ?? "")
    }
}

private struct FrogButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: FrogButtonStyle.Kind
    let compact: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.frogKeyboardSurface) private var keyboardSurface
    @State private var hovering = false

    /// A press answers on the down event: a deeper fill and, unless motion is reduced, a slight shrink.
    var body: some View {
        // Rex's buttons are capsules.
        let shape = Capsule(style: .continuous)
        let pressed = configuration.isPressed && enabled
        let hovered = hovering && enabled
        let fade = FrogMotion.hover(hovered || pressed, keyboardSurface: keyboardSurface)
        let label = configuration.label
            .font(compact ? FrogType.label : FrogType.bodyMedium).lineLimit(1)
            .padding(.horizontal, compact ? 10 : 12)
            .foregroundStyle(foreground)
            .frame(minHeight: compact ? FrogStyle.compactHeight : FrogStyle.controlHeight)
        Group {
            // One disabled look for every kind: the secondary pill, faded. A disabled primary keeps no accent, so
            // it never reads as a grey button that is broken, and a disabled ghost stays plain text.
            switch enabled || kind == .ghost ? kind : .secondary {
            case .secondary, .destructive:
                label.frogControlSurface(hovering: hovered, pressed: pressed, height: compact ? FrogStyle.compactHeight : FrogStyle.controlHeight, capsule: true)
            case .primary:
                label.background {
                    // The accent, as Rex fills its one main action.
                    shape.fill(FrogStyle.accent.opacity(pressed ? 0.76 : hovered ? 0.88 : 1)).animation(fade, value: hovered || pressed)
                }.contentShape(shape)
            case .ghost:
                label.background {
                    shape.fill(pressed ? FrogStyle.pressed : hovered ? FrogStyle.hover : .clear).animation(fade, value: hovered || pressed)
                }.contentShape(shape)
            }
        }
        // Only the scale springs: whatever the action changes inside the button on release stays an instant cut.
        .animation(keyboardSurface ? nil : FrogMotion.press) { $0.scaleEffect(pressed && !reduceMotion && !keyboardSurface ? 0.97 : 1) }
        .opacity(enabled ? 1 : FrogStyle.disabledOpacity)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        if !enabled { return kind == .ghost ? FrogStyle.muted : FrogStyle.ink }
        return switch kind {
        case .primary: FrogStyle.onAccent
        case .secondary: FrogStyle.ink
        case .ghost: hovering ? FrogStyle.ink : FrogStyle.muted
        case .destructive: FrogStyle.critical
        }
    }
}

/// A padded card. Lists and tables that draw their own rows use `frogTableSurface()`.
struct FrogCard<Content: View>: View {
    var padding: CGFloat = FrogStyle.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading).frogTableSurface()
    }
}

/// The v1 name of `FrogSection`, kept for views not moved yet.
struct SettingsSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title; self.accessory = accessory(); self.content = content()
    }

    var body: some View {
        FrogSection(title, accessory: { accessory }, content: { content })
    }
}

extension SettingsSection where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

/// The v1 name of `FrogPageHeader`, kept for pages not moved yet.
struct PageHeader<Actions: View>: View {
    let title: String
    var subtitle = ""
    @ViewBuilder var actions: Actions

    var body: some View {
        FrogPageHeader(title: title, subtitle: subtitle) { actions }
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, subtitle: String = "") {
        self.title = title; self.subtitle = subtitle; self.actions = EmptyView()
    }
}

/// The v1 name of `FrogPage`, at the wide width, kept for pages not moved yet.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        FrogPage(width: FrogStyle.wideWidth) { content }
    }
}

private struct FrogDenseContainerKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True inside a card (`frogTableSurface`, `FrogCard`, `FrogSection`) or a popup (`frogPanel`), where a
    /// heading is a small sub-group caption rather than a section heading.
    var frogDenseContainer: Bool {
        get { self[FrogDenseContainerKey.self] }
        set { self[FrogDenseContainerKey.self] = newValue }
    }
}

/// A label above a group of content. Inside a card or a popup it is the small muted caption of a sub-group; on a
/// page or in a sheet, outside any card, it is drawn as the one section heading (`FrogSectionHeader`), so a page
/// never shows two heading styles side by side.
struct SectionCaption: View {
    let text: String
    @Environment(\.frogDenseContainer) private var dense
    var body: some View {
        if dense {
            Text(L10n.text(text)).font(FrogType.label)
                .foregroundStyle(FrogStyle.muted).accessibilityAddTraits(.isHeader)
        } else {
            Text(L10n.text(text)).font(FrogType.section)
                .foregroundStyle(FrogStyle.ink).accessibilityAddTraits(.isHeader)
        }
    }
}

struct SymbolTile: View {
    let symbol: String
    var size: CGFloat = 40
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.4, weight: .medium))
            .foregroundStyle(FrogStyle.muted).frame(width: size, height: size)
            .background(FrogStyle.control, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct FrogBadge: View {
    let text: String
    var active = false
    var body: some View {
        Text(L10n.text(text)).font(FrogType.caption.weight(.semibold))
            .foregroundStyle(active ? FrogStyle.accent : FrogStyle.muted)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(active ? AnyShapeStyle(FrogStyle.accentSoft) : AnyShapeStyle(FrogStyle.control), in: RoundedRectangle(cornerRadius: FrogStyle.smallRadius, style: .continuous))
    }
}

/// A recorded shortcut as one chip ("⌃⌥Space"): `compactHeight` tall and at least `minWidth` wide, so a column
/// of them lines up whatever their keys. Hints that only name keys use `KeyCaps`.
struct ShortcutBadge: View {
    static let minWidth: CGFloat = 56
    let text: String
    var body: some View {
        // One line always; in a narrow layout tile a four-modifier shortcut shrinks a little instead of wrapping.
        Text(text).font(FrogType.bodyMedium).lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 8).frame(minWidth: Self.minWidth).modifier(CompactActionSurface())
            .accessibilityLabel("Shortcut: \(text)")
    }
}

/// A compact, 24-point control with the shared fill and hairline, which highlights on hover.
struct CompactActionSurface: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content.foregroundStyle(FrogStyle.ink)
            .frogControlSurface(hovering: hovering, height: FrogStyle.compactHeight)
            .onHover { hovering = $0 }
    }
}

struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text(title)).font(FrogType.bodyMedium).foregroundStyle(FrogStyle.ink)
            content.textFieldStyle(.plain).font(FrogType.body).padding(.horizontal, 8).padding(.vertical, 6)
                .frogControlSurface()
        }
    }
}

/// v1, kept for code not moved yet: new code puts a `FrogDropdown` in a `FrogRow`.
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

/// An icon-only action. Borderless shows only its symbol until hovered; bordered matches a compact button.
struct IconAction: View {
    let title: String
    let symbol: String
    var destructive = false
    var bordered = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            IconLabel(symbol: symbol, destructive: destructive, bordered: bordered, hovering: hovering)
        }.buttonStyle(.plain).onHover { hovering = $0 }.accessibilityLabel(L10n.text(title)).help(L10n.text(title))
    }
}

/// A menu behind an icon, "…" unless `symbol` says otherwise, drawn exactly like the `IconAction` beside it.
/// The system's borderless menu style would drop Frog's surface and hover.
struct IconMenu<Items: View>: View {
    let title: String
    var symbol = "ellipsis"
    var bordered = true
    @ViewBuilder var items: Items
    @State private var hovering = false
    var body: some View {
        Menu { items } label: { IconLabel(symbol: symbol, destructive: false, bordered: bordered, hovering: hovering) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .onHover { hovering = $0 }.accessibilityLabel(L10n.text(title)).help(L10n.text(title))
    }
}

/// The icon of `IconAction` and `IconMenu`: on a 24-point control surface when `bordered`, else a muted symbol
/// that darkens on a 28-point hover fill.
private struct IconLabel: View {
    let symbol: String
    let destructive: Bool
    let bordered: Bool
    let hovering: Bool
    var body: some View {
        if bordered {
            Image(systemName: symbol).font(FrogType.label).contentTransition(.symbolEffect(.replace))
                .foregroundStyle(destructive ? FrogStyle.critical : FrogStyle.ink)
                .frame(width: FrogStyle.compactHeight).modifier(CompactActionSurface())
        } else {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).contentTransition(.symbolEffect(.replace))
                .foregroundStyle(destructive ? FrogStyle.critical : hovering ? FrogStyle.ink : FrogStyle.muted)
                .frame(width: FrogStyle.controlHeight, height: FrogStyle.controlHeight)
                .frogRowHighlight(hovering: hovering)
        }
    }
}

/// A copy that confirms itself: the symbol turns into a checkmark for a moment. An icon, or a button with
/// `title` when `labeled`.
struct CopyAction: View {
    var title = "Copy"
    var labeled = false
    let perform: () -> Void
    @State private var copied = false
    /// Counts copies, so copying again restarts the confirmation.
    @State private var copies = 0
    var body: some View {
        Group {
            if labeled {
                Button(action: copy) {
                    Label { Text(L10n.text(title)) } icon: {
                        // One width for both symbols, so the button never nudges its neighbours.
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").contentTransition(.symbolEffect(.replace))
                            .frame(width: 14)
                    }
                }.accessibilityLabel(L10n.text(copied ? "Copied" : title))
            } else {
                IconAction(title: copied ? "Copied" : title, symbol: copied ? "checkmark" : "doc.on.doc", action: copy)
            }
        }
        .task(id: copies) {
            guard copies > 0 else { return }
            do { try await Task.sleep(for: FrogMotion.confirmation); withAnimation(FrogMotion.reveal) { copied = false } } catch {}
        }
    }

    private func copy() {
        perform()
        copies += 1
        withAnimation(FrogMotion.reveal) { copied = true }
        AccessibilityNotification.Announcement(L10n.text("Copied")).post()
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    let description: String
    @ViewBuilder var control: Control
    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(title)).font(FrogType.bodyMedium).foregroundStyle(FrogStyle.ink)
                Text(L10n.text(description)).font(FrogType.small).foregroundStyle(FrogStyle.muted)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            control
        }
    }
}

/// An empty list or page: a symbol, a title, one sentence and, when there is one, the action that fills it.
struct FrogEmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions
    var body: some View {
        VStack(spacing: 10) {
            SymbolTile(symbol: symbol, size: 32)
            Text(L10n.text(title)).font(FrogType.section).foregroundStyle(FrogStyle.ink)
            Text(L10n.text(message)).font(FrogType.lead).foregroundStyle(FrogStyle.muted)
                .multilineTextAlignment(.center).lineSpacing(4).frame(maxWidth: 340)
            // A padded EmptyView would still take space, so the others keep their layout.
            if Actions.self != EmptyView.self { actions.padding(.top, 4) }
        }.frame(maxWidth: .infinity).padding(.vertical, 44).padding(.horizontal, 24)
    }
}

extension FrogEmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

struct FrogMark: View {
    private static let image = FrogResources.bundle.url(forResource: "FrogLogo", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) } ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
    var size: CGFloat = 46
    var body: some View {
        Image(nsImage: Self.image).resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}
