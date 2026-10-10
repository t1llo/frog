import AppKit
import SwiftUI
import FrogCore

struct FrogWindowMaterial: NSViewRepresentable {
    var popup = false
    var cornerRadius: CGFloat? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = FrogBackdropView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = popup ? .popover : .sidebar
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

struct AppearanceSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var accentInput = ""
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        CompactRow(title: "Appearance") {
            CompactSegments(values: AppearancePreferences.Mode.allCases, selected: appearance.mode ?? .system, title: { $0.rawValue.capitalized }) { mode in var value = appearance; value.mode = mode; save(value) }
        }
        Divider()
        CompactRow(title: "Theme") {
            CompactMenu(value: (appearance.theme ?? .frog).title) {
                ForEach(AppearancePreferences.Theme.allCases, id: \.self) { theme in
                    Button(theme.title) {
                        var value = appearance; value.theme = theme; value.useThemeAccent = true
                        value.lightPalette = nil; value.darkPalette = nil
                        save(value)
                    }
                }
            }
        }
        Divider()
        CompactRow(title: "Accent color") {
            HStack(spacing: 10) {
                Button("Reset") { var value = appearance; value.useThemeAccent = true; value.lightPalette?["accent"] = nil; value.darkPalette?["accent"] = nil; save(value) }.buttonStyle(.link)
                HStack(spacing: 2) {
                    Text("#").foregroundStyle(FrogStyle.muted)
                    TextField("RGB", text: $accentInput).textFieldStyle(.plain).frame(width: 58)
                        .onSubmit { saveAccent() }.accessibilityLabel("Accent hex color")
                }.font(.system(size: 11, design: .monospaced)).padding(6)
                    .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 5))
                    .onAppear { accentInput = appearance.accentHex }
                    .onChange(of: appearance.accentHex) { _, value in accentInput = value }
                ColorPicker("Accent color", selection: Binding(get: { FrogStyle.accent }, set: { color in
                    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                    var value = appearance; value.useThemeAccent = false; value.lightPalette?["accent"] = nil; value.darkPalette?["accent"] = nil; value.accentHex = String(format: "%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255)); save(value)
                }), supportsOpacity: false).labelsHidden()
            }
        }
        Divider()
        CompactRow(title: "Window transparency", detail: "Blur the desktop behind the whole window. Text stays opaque; fields keep a readable tint.") {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { appearance.transparency }, set: { amount in var value = appearance; value.transparency = amount; save(value) }), in: 0...1).frame(width: 145)
                Text("\(Int(appearance.transparency * 100))%").font(.system(size: 11)).monospacedDigit().frame(width: 32)
            }
        }
        Divider()
        CompactRow(title: "Popup transparency", detail: "Independent backdrop blur for every Frog popup, including the menu, usage, recording and shortcut panels.") {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { appearance.popupTransparency ?? 0 }, set: { amount in var value = appearance; value.popupTransparency = amount; save(value) }), in: 0...1).frame(width: 145)
                Text("\(Int((appearance.popupTransparency ?? 0) * 100))%").font(.system(size: 11)).monospacedDigit().frame(width: 32)
            }
        }
        if reduceTransparency || contrast == .increased {
            Text("macOS accessibility settings currently keep surfaces opaque. Your transparency preferences are saved for later.")
                .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
        }
        Divider()
        CompactRow(title: "Custom palette", detail: "Edit palette.light.* and palette.dark.* in config, then Reload. Background, sidebar, surface, inset, border, text, muted and accent inherit the preset until overridden. Choosing a preset resets overrides.") {
            Button("Open config") { model.openConfiguration() }
        }
    }
    private var appearance: AppearancePreferences { model.configuration.preferences.appearance ?? AppearancePreferences() }
    private func saveAccent() {
        let hex = accentInput.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "").uppercased()
        var value = appearance; value.accentHex = hex; value.useThemeAccent = false
        value.lightPalette?["accent"] = nil; value.darkPalette?["accent"] = nil
        guard value.valid else { model.report(FrogError.message("Enter a six-digit RGB hex color, such as A3D8AF.")); return }
        save(value); accentInput = hex
    }
    private func save(_ value: AppearancePreferences) { var preferences = model.configuration.preferences; preferences.appearance = value; do { try model.savePreferences(preferences) } catch { model.report(error) } }
}
