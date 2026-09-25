import AppKit
import SwiftUI
import FrogCore

struct FrogWindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .sidebar; view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct AppearanceSettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        CompactRow(title: "Appearance") {
            CompactMenu(value: (appearance.mode ?? .system).rawValue.capitalized) {
                ForEach(AppearancePreferences.Mode.allCases, id: \.self) { mode in
                    Button(L10n.text(mode.rawValue.capitalized)) { var value = appearance; value.mode = mode; save(value) }
                }
            }
        }
        Divider()
        CompactRow(title: "Theme") {
            CompactMenu(value: (appearance.theme ?? .frog).title) {
                ForEach(AppearancePreferences.Theme.allCases, id: \.self) { theme in
                    Button(theme.title) {
                        var value = appearance; value.theme = theme; value.useThemeAccent = true
                        save(value)
                    }
                }
            }
        }
        Divider()
        CompactRow(title: "Accent color") {
            HStack(spacing: 10) {
                Button("Reset") { var value = appearance; value.useThemeAccent = true; save(value) }.buttonStyle(.link)
                ColorPicker("Accent color", selection: Binding(get: { FrogStyle.accent }, set: { color in
                    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                    var value = appearance; value.useThemeAccent = false; value.accentHex = String(format: "%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255)); save(value)
                }), supportsOpacity: false).labelsHidden()
            }
        }
        Divider()
        CompactRow(title: "Transparency") {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { appearance.transparency }, set: { amount in var value = appearance; value.transparency = amount; save(value) }), in: 0...1).frame(width: 145)
                Text("\(Int(appearance.transparency * 100))%").font(.system(size: 11)).monospacedDigit().frame(width: 32)
            }
        }
    }
    private var appearance: AppearancePreferences { model.configuration.preferences.appearance ?? AppearancePreferences() }
    private func save(_ value: AppearancePreferences) { var preferences = model.configuration.preferences; preferences.appearance = value; do { try model.savePreferences(preferences) } catch { model.report(error) } }
}
