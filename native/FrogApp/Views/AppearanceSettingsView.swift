import AppKit
import SwiftUI
import FrogCore

struct FrogWindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .underWindowBackground; view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct AppearanceSettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        FrogCard {
            VStack(spacing: 12) {
                HStack {
                    Text("Accent")
                    Spacer()
                    ForEach(["A3D8AF", "8EBCFF", "C3A6FF", "FFB989", "F49DB0"], id: \.self) { hex in
                        Button {
                            var value = appearance; value.accentHex = hex; save(value)
                        } label: {
                            let rgb = UInt32(hex, radix: 16)!
                            Circle().fill(Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255))
                                .frame(width: 18, height: 18).overlay(Circle().stroke(.white, lineWidth: appearance.accentHex == hex ? 2 : 0))
                        }.buttonStyle(.plain).accessibilityLabel("Accent \(hex)")
                    }
                    ColorPicker("Custom accent", selection: Binding(get: { FrogStyle.accent }, set: { color in
                        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                        var value = appearance
                        value.accentHex = String(format: "%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
                        save(value)
                    }), supportsOpacity: false).labelsHidden()
                }
                HStack {
                    Text("Transparency")
                    Slider(value: Binding(get: { appearance.transparency }, set: { amount in var value = appearance; value.transparency = amount; save(value) }), in: 0...1).frame(maxWidth: 220)
                    Text("\(Int(appearance.transparency * 100))%").monospacedDigit().frame(width: 36)
                }
            }.font(.system(size: 12))
        }
    }
    private var appearance: AppearancePreferences { model.configuration.preferences.appearance ?? AppearancePreferences() }
    private func save(_ value: AppearancePreferences) {
        var preferences = model.configuration.preferences; preferences.appearance = value
        do { try model.savePreferences(preferences) } catch { model.report(error) }
    }
}
