import AppKit
import SwiftUI
import FrogCore

struct FrogWindowMaterial: NSViewRepresentable {
    var popup = false
    var cornerRadius: CGFloat? = nil
    /// Overrides the material `popup` picks; `frogSurface` passes its kind's.
    var material: NSVisualEffectView.Material? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = FrogBackdropView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material ?? (popup ? .popover : .sidebar)
        view.blendingMode = .behindWindow
        // Active even for nonactivating/click-through panels: blur must not depend on focus.
        view.state = .active
        view.isEmphasized = contrast == .increased
        view.wantsLayer = true
        let disabled = reduceTransparency || contrast == .increased
        view.layer?.backgroundColor = disabled ? NSColor(popup ? FrogStyle.panelSurface : FrogStyle.opaqueCanvas).cgColor : nil
        (view as? FrogBackdropView)?.setCornerRadius(cornerRadius)
    }
}

private final class FrogBackdropView: NSVisualEffectView {
    private var radius: CGFloat?
    private var maskedSize: NSSize?

    func setCornerRadius(_ value: CGFloat?) {
        guard radius != value else { return }
        radius = value; maskedSize = nil
        updateMask()
    }
    override func layout() {
        super.layout()
        updateMask()
    }
    private func updateMask() {
        guard maskedSize != bounds.size else { return }
        maskedSize = bounds.size
        guard let radius, bounds.width > 0, bounds.height > 0 else { maskImage = nil; return }
        // SwiftUI's clip only clips its rendered layer. The native backdrop and
        // window shadow need the same mask, otherwise square corners leak behind it.
        maskImage = NSImage(size: bounds.size, flipped: false) { rectangle in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rectangle, xRadius: radius, yRadius: radius).fill()
            return true
        }
        if let window, !window.styleMask.contains(.titled), let host = window.contentView {
            // MenuBarExtra adds background siblings outside the SwiftUI content clip.
            // Clip the public content host too, keeping those native layers inside
            // the same outline without reaching into private SwiftUI view classes.
            host.wantsLayer = true
            host.layer?.cornerRadius = radius
            host.layer?.masksToBounds = true
        }
        window?.invalidateShadow()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Covers menu-bar windows created by SwiftUI as well as our explicit NSPanel hosts.
        window?.isOpaque = false
        window?.backgroundColor = .clear
        maskedSize = nil; updateMask()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A slider and the colour panel report every step of a drag. Each step is shown at once; the
/// settings are written once, when the steps pause or the drag ends.
@MainActor
final class AppearanceDraft: ObservableObject {
    /// What the controls show while it is not saved yet.
    @Published private(set) var value: AppearancePreferences?
    private let delay: Duration
    private let preview: (AppearancePreferences) -> Void
    private let stored: () -> AppearancePreferences
    private let save: (AppearancePreferences) -> Void
    /// The saved appearance the waiting value was derived from.
    private var base: AppearancePreferences?
    private var pending: Task<Void, Never>?

    init(delay: Duration = .milliseconds(300), preview: @escaping (AppearancePreferences) -> Void,
         stored: @escaping () -> AppearancePreferences, save: @escaping (AppearancePreferences) -> Void) {
        self.delay = delay; self.preview = preview; self.stored = stored; self.save = save
    }

    /// The app's own appearance and settings; tests pass a preview that leaves the running app alone.
    convenience init(model: AppModel, delay: Duration = .milliseconds(300), preview: ((AppearancePreferences) -> Void)? = nil) {
        self.init(delay: delay, preview: preview ?? { FrogAppearance.shared.apply($0) },
                  stored: { model.configuration.preferences.appearance ?? AppearancePreferences() },
                  save: { value in
                      var preferences = model.configuration.preferences; preferences.appearance = value
                      do { try model.savePreferences(preferences) } catch { model.report(error) }
                  })
    }

    /// One step of a drag.
    func change(_ value: AppearancePreferences) {
        if self.value == nil { base = stored() }
        self.value = value
        preview(value)
        pending?.cancel()
        // The task keeps the draft alive, so a page that closes inside the delay still saves.
        pending = Task { [delay] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    /// A single choice, saved at once together with a drag that is still waiting.
    func set(_ value: AppearancePreferences) { change(value); commit() }

    /// Saves what is waiting: the drag ended or the page is closing.
    func commit() {
        pending?.cancel(); pending = nil
        guard let value else { return }
        self.value = nil
        // A configuration reloaded since the drag began wins over a value that was never saved.
        if stored() == base { save(value) }
        // A refused save must not leave the app looking like something that is not saved.
        let saved = stored()
        if saved != value { preview(saved) }
    }
}

struct AppearanceSettingsView: View {
    @ObservedObject private var model: AppModel
    @StateObject private var draft: AppearanceDraft
    @State private var accentInput = ""
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
        _draft = StateObject(wrappedValue: AppearanceDraft(model: model))
    }
    /// As Rex lays out its appearance settings: one card with the tile pickers for the colour scheme and the
    /// interface style, the theme cards under them and the accent settings that go with the theme, then the glass
    /// settings only while the interface is glass. One card rather than two, so the themes are in view on a
    /// default-size window. One draft.
    var body: some View {
        FrogSection("Appearance") {
            schemeAndStyle
            themes
            accent
            FrogRow("Custom palette", caption: "palette.light.* and palette.dark.* in the configuration file") {
                Button("Open config") { model.openConfiguration() }
            }
        }
        if style == .glass { FrogSection("Glass") { glass } }
    }

    /// Classic is an opaque window and opaque popups; Glass lets the desktop through.
    enum InterfaceStyle: String, CaseIterable { case classic, glass }
    private var style: InterfaceStyle {
        appearance.transparency > 0.005 || (appearance.popupTransparency ?? 0) > 0.005 ? .glass : .classic
    }

    @ViewBuilder private var schemeAndStyle: some View {
        HStack(alignment: .top, spacing: FrogStyle.space16) {
            TileGroup(title: "Color scheme") {
                ForEach(AppearancePreferences.Mode.allCases, id: \.self) { mode in
                    AppearanceTile(title: Self.title(mode), selected: (appearance.mode ?? .system) == mode) {
                        WindowSketch(scheme: mode, glass: false)
                    } choose: { var value = appearance; value.mode = mode; draft.set(value) }
                }
            }
            Spacer().frame(width: FrogStyle.space16)
            TileGroup(title: "Interface style") {
                ForEach(InterfaceStyle.allCases, id: \.self) { kind in
                    AppearanceTile(title: kind == .classic ? "Classic" : "Glass", selected: style == kind) {
                        WindowSketch(scheme: appearance.mode ?? .system, glass: kind == .glass, shapesBehind: true)
                    } choose: {
                        guard style != kind else { return }
                        var value = appearance
                        Self.setGlass(kind == .glass ? 0.5 : 0, in: &value)
                        draft.set(value)
                    }
                }
            }
            Spacer(minLength: 0)
        }.padding(.top, FrogStyle.space10)
            .onDisappear { draft.commit() }
    }

    /// Whether the accent follows the theme, and the colour when it does not.
    @ViewBuilder private var accent: some View {
        FrogRow("Tint with theme", caption: "The theme's own accent color") {
            Toggle("Tint with theme", isOn: Binding(get: { appearance.useThemeAccent ?? (appearance.accentHex == "A3D8AF") }, set: { on in
                var value = appearance; value.useThemeAccent = on
                if on { value.lightPalette?["accent"] = nil; value.darkPalette?["accent"] = nil }
                draft.set(value)
            })).labelsHidden()
        }
        if !(appearance.useThemeAccent ?? (appearance.accentHex == "A3D8AF")) {
            FrogRow("Accent color") {
                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        Text("#").foregroundStyle(FrogStyle.muted)
                        FrogTextField(placeholder: "RGB", text: $accentInput).textFieldStyle(.plain).frame(width: 64)
                            .onSubmit { saveAccent() }.accessibilityLabel("Accent hex color")
                    }.font(FrogType.body).padding(.horizontal, 10).frogControlSurface(capsule: true)
                        .onAppear { accentInput = appearance.accentHex }
                        .onChange(of: appearance.accentHex) { _, value in accentInput = value }
                    ColorPicker("Accent color", selection: Binding(get: { FrogStyle.accent }, set: { color in
                        guard let hex = Self.hex(of: NSColor(color)) else { return }
                        var value = appearance; value.useThemeAccent = false; value.lightPalette?["accent"] = nil; value.darkPalette?["accent"] = nil; value.accentHex = hex; draft.change(value)
                    }), supportsOpacity: false).labelsHidden()
                }
            }
        }
    }

    private var themes: some View {
        VStack(alignment: .leading, spacing: FrogStyle.space8) {
            Text(L10n.text("Theme")).font(FrogType.body).foregroundStyle(FrogStyle.muted)
            ThemeCards(selected: appearance.effectiveTheme) { theme in
                var value = appearance; value.theme = theme
                value.lightPalette = nil; value.darkPalette = nil
                draft.set(value)
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel(L10n.text("Theme"))
        .padding(.vertical, FrogStyle.space10)
    }

    private static func title(_ mode: AppearancePreferences.Mode) -> String {
        switch mode {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// One setting: how much of the desktop shows through. It applies to the window and every popup alike.
    @ViewBuilder private var glass: some View {
        amountRow("Transparency", detail: "The window, menus and panels", value: appearance.transparency) { value, amount in
            Self.setGlass(max(0.05, amount), in: &value)
        }
        if reduceTransparency || contrast == .increased {
            FrogRowNote(text: "Off while macOS reduces transparency.")
        }
    }
    /// Glass is the same transparency everywhere and no glow; zero is Classic.
    private static func setGlass(_ amount: Double, in value: inout AppearancePreferences) {
        value.transparency = amount; value.popupTransparency = amount
        value.glow = nil; value.glowStrength = nil; value.glowMotion = nil
    }
    private var appearance: AppearancePreferences { draft.value ?? model.configuration.preferences.appearance ?? AppearancePreferences() }
    /// A slider from 0 to 100 %, shown at once while dragging and saved when the drag ends.
    private func amountRow(_ title: String, detail: String? = nil, value amount: Double,
                           set: @escaping (inout AppearancePreferences, Double) -> Void) -> some View {
        FrogRow(title, caption: detail) {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { amount }, set: { amount in var value = appearance; set(&value, amount); draft.change(value) }),
                       in: 0...1, onEditingChanged: { if !$0 { draft.commit() } }).frame(width: 145).controlSize(.small)
                    .accessibilityLabel(title)
                Text("\(Int((amount * 100).rounded()))%").font(FrogType.small).monospacedDigit().frame(width: 32, alignment: .trailing)
            }
        }
    }
    /// The nearest six-digit sRGB hex of a picked colour.
    static func hex(of color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
    private func saveAccent() {
        let hex = accentInput.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "").uppercased()
        var value = appearance; value.accentHex = hex; value.useThemeAccent = false
        value.lightPalette?["accent"] = nil; value.darkPalette?["accent"] = nil
        guard value.valid else { model.report(FrogError.message("Enter a six-digit RGB hex color, such as A3D8AF.")); return }
        draft.set(value); accentInput = hex
    }
}

/// A labelled group of tiles in the Appearance card, as Rex's "Color scheme" and "Interface style".
private struct TileGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: FrogStyle.space8) {
            Text(L10n.text(title)).font(FrogType.body).foregroundStyle(FrogStyle.muted)
            HStack(alignment: .top, spacing: FrogStyle.space10) { content }
        }.accessibilityElement(children: .contain).accessibilityLabel(L10n.text(title))
    }
}

/// One choice drawn as a picture with its name under it; the chosen one gets Rex's accent ring.
private struct AppearanceTile<Picture: View>: View {
    let title: String
    let selected: Bool
    @ViewBuilder var picture: Picture
    let choose: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: choose) {
            VStack(spacing: FrogStyle.space6) {
                picture
                    .frame(width: 76, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: FrogStyle.controlRadius, style: .continuous))
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: FrogStyle.controlRadius + 3, style: .continuous)
                        .strokeBorder(selected ? FrogStyle.accent : hovering ? FrogStyle.hairline : .clear, lineWidth: 2))
                Text(L10n.text(title)).font(selected ? FrogType.rowMedium : FrogType.body)
                    .foregroundStyle(FrogStyle.ink).lineLimit(1).fixedSize()
            }.fixedSize().contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityLabel(L10n.text(title)).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A tiny Frog window: light, dark, or split for Auto, each on a desktop of its own mode so Light and Dark read apart;
/// the style tiles add a few shapes behind the window on the same neutral desktop, so Glass has something to frost.
private struct WindowSketch: View {
    let scheme: AppearancePreferences.Mode
    let glass: Bool
    var shapesBehind = false
    var body: some View {
        ZStack {
            switch scheme {
            case .light: desktop(dark: false)
            case .dark: desktop(dark: true)
            case .system: ZStack { desktop(dark: false); desktop(dark: true).mask(DiagonalHalf()) }
            }
            if shapesBehind { shapes }
            switch scheme {
            case .light: window(dark: false)
            case .dark: window(dark: true)
            case .system:
                ZStack {
                    window(dark: false)
                    window(dark: true).mask(DiagonalHalf())
                }
            }
        }
    }

    /// A light desktop that is nearly white, so the Light tile reads as light rather than grey, and a dark one.
    private func desktop(dark: Bool) -> some View {
        LinearGradient(colors: dark ? [Color(white: 0.3), Color(white: 0.12)] : [Color(white: 0.97), Color(white: 0.87)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// A soft band across the desktop, corner to corner behind the window, which a Glass window lets show through
    /// and a Classic one hides; it runs off the tile's edges so it never reads as a mark on the window.
    private var shapes: some View {
        Capsule(style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.4)], startPoint: .leading, endPoint: .trailing))
            .frame(width: 120, height: 20)
            .rotationEffect(.degrees(-28))
    }

    private func window(dark: Bool) -> some View {
        let base = dark ? Color(white: 0.1) : Color(white: 0.98)
        let pane = dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 4, height: 4) }
            }
            RoundedRectangle(cornerRadius: FrogStyle.smallRadius / 2).fill(pane).frame(height: 9)
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: FrogStyle.smallRadius / 2).fill(pane)
                RoundedRectangle(cornerRadius: FrogStyle.smallRadius / 2).fill(pane)
            }
        }.padding(5)
            .frame(width: 50, height: 38)
            .background(base.opacity(glass ? 0.45 : 1), in: RoundedRectangle(cornerRadius: FrogStyle.smallRadius + 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: FrogStyle.smallRadius + 2, style: .continuous).strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
    }
}

/// The lower-right half of a rectangle, cut corner to corner, for the Auto tile's dark side.
private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX + 6, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX - 6, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// Every theme as a small card in its own colours, in a grid that shows them all at once: a sample of text, a
/// prompt in the accent and a row of the theme's colours. The chosen theme has the accent ring.
private struct ThemeCards: View {
    let selected: AppearancePreferences.Theme
    let choose: (AppearancePreferences.Theme) -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: FrogStyle.space10, alignment: .top)],
                  alignment: .leading, spacing: FrogStyle.space12) {
            ForEach(AppearancePreferences.Theme.allCases, id: \.self) { theme in
                ThemeCard(theme: theme, swatch: FrogStyle.swatch(theme, dark: scheme == .dark), selected: theme == selected) { choose(theme) }
            }
        }
    }
}

private struct ThemeCard: View {
    let theme: AppearancePreferences.Theme
    let swatch: FrogStyle.ThemeSwatch
    let selected: Bool
    let choose: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: choose) {
            VStack(spacing: FrogStyle.space6) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text("Aa").font(.system(size: 17)).foregroundStyle(swatch.ink)
                        Spacer(minLength: 2)
                        Text("~/").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(swatch.ink)
                            .frame(width: 22, height: 18)
                            .background(swatch.accent.opacity(0.28), in: RoundedRectangle(cornerRadius: FrogStyle.smallRadius, style: .continuous))
                        RoundedRectangle(cornerRadius: FrogStyle.smallRadius, style: .continuous).fill(swatch.accent).frame(width: 8, height: 18)
                    }
                    HStack(spacing: -3) {
                        ForEach(Array(swatch.dots.enumerated()), id: \.offset) { _, dot in
                            Circle().fill(dot).frame(width: 12, height: 12)
                                .overlay(Circle().strokeBorder(swatch.canvas, lineWidth: 1))
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .frame(maxWidth: .infinity).frame(height: 62)
                .background(swatch.canvas, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: FrogStyle.controlRadius, style: .continuous).strokeBorder(swatch.ink.opacity(0.12)))
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: FrogStyle.controlRadius + 3, style: .continuous)
                    .strokeBorder(selected ? FrogStyle.accent : hovering ? FrogStyle.hairline : .clear, lineWidth: 2))
                Text(L10n.text(theme.title)).font(selected ? FrogType.rowMedium : FrogType.body)
                    .foregroundStyle(selected ? FrogStyle.ink : FrogStyle.muted).lineLimit(1)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityLabel(L10n.text(theme.title)).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
