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
    var body: some View {
        CompactRow(title: "Appearance") {
            CompactSegments(values: AppearancePreferences.Mode.allCases, selected: appearance.mode ?? .system, title: { $0.rawValue.capitalized }) { mode in var value = appearance; value.mode = mode; draft.set(value) }
        }.onDisappear { draft.commit() }
        CompactRow(title: "Theme") {
            CompactMenu(value: appearance.effectiveTheme.title) {
                ForEach(AppearancePreferences.Theme.allCases, id: \.self) { theme in
                    Button(theme.title) {
                        var value = appearance; value.theme = theme; value.useThemeAccent = true
                        value.lightPalette = nil; value.darkPalette = nil
                        draft.set(value)
                    }.compactChoice(selected: theme == appearance.effectiveTheme)
                }
            }
        }
        CompactRow(title: "Accent color") {
            HStack(spacing: 8) {
                Button("Reset") { var value = appearance; value.useThemeAccent = true; value.lightPalette?["accent"] = nil; value.darkPalette?["accent"] = nil; draft.set(value) }.buttonStyle(.frog(.ghost))
                HStack(spacing: 2) {
                    Text("#").foregroundStyle(FrogStyle.muted)
                    TextField("RGB", text: $accentInput).textFieldStyle(.plain).frame(width: 58)
                        .onSubmit { saveAccent() }.accessibilityLabel("Accent hex color")
                }.font(FrogType.body).padding(.horizontal, 8).frogControlSurface()
                    .onAppear { accentInput = appearance.accentHex }
                    .onChange(of: appearance.accentHex) { _, value in accentInput = value }
                ColorPicker("Accent color", selection: Binding(get: { FrogStyle.accent }, set: { color in
                    guard let hex = Self.hex(of: NSColor(color)) else { return }
                    var value = appearance; value.useThemeAccent = false; value.lightPalette?["accent"] = nil; value.darkPalette?["accent"] = nil; value.accentHex = hex; draft.change(value)
                }), supportsOpacity: false).labelsHidden()
            }
        }
        CompactRow(title: "Custom palette", detail: "palette.light.* and palette.dark.* in the configuration file.") {
            Button("Open config") { model.openConfiguration() }
        }
        SectionCaption(text: "Transparency").padding(.top, 6)
        CompactRow(title: "Window transparency") {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { appearance.transparency }, set: { amount in var value = appearance; value.transparency = amount; draft.change(value) }), in: 0...1, onEditingChanged: { if !$0 { draft.commit() } }).frame(width: 145)
                Text("\(Int(appearance.transparency * 100))%").font(FrogType.small).monospacedDigit().frame(width: 32)
            }
        }
        CompactRow(title: "Popup transparency", detail: "Menus and panels.") {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { appearance.popupTransparency ?? 0 }, set: { amount in var value = appearance; value.popupTransparency = amount; draft.change(value) }), in: 0...1, onEditingChanged: { if !$0 { draft.commit() } }).frame(width: 145)
                Text("\(Int((appearance.popupTransparency ?? 0) * 100))%").font(FrogType.small).monospacedDigit().frame(width: 32)
            }
        }
        if reduceTransparency || contrast == .increased {
            Text("Off while macOS reduces transparency.")
                .font(FrogType.caption).foregroundStyle(FrogStyle.muted)
        }
    }
    private var appearance: AppearancePreferences { draft.value ?? model.configuration.preferences.appearance ?? AppearancePreferences() }
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
