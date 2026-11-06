import FrogCore
import SwiftUI

/// A community plugin's settings in Frog's own controls: the settings its plugin.json declares, the keys of its
/// shortcuts and the folders the user gave it.
struct PluginSettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    let id: String
    @ObservedObject var plugins: PluginRuntime
    let done: () -> Void

    var body: some View {
        let item = plugins.item(id)
        let manifest = item?.manifest
        VStack(alignment: .leading, spacing: FrogStyle.space16) {
            HStack(spacing: FrogStyle.space12) {
                PluginIconTile(symbol: PluginSymbol.name(item?.symbol ?? PluginManifest.defaultSymbol), tint: PluginTint.purple.color, size: .header)
                VStack(alignment: .leading, spacing: FrogStyle.space2) {
                    Text(item?.name ?? id).font(FrogType.title).tracking(-0.4).accessibilityAddTraits(.isHeader)
                    Text("Settings").font(FrogType.small).foregroundStyle(FrogStyle.muted)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: FrogStyle.sectionSpacing - 6) {
                    if let manifest, let item {
                        if !manifest.settings.isEmpty {
                            FrogSection("General") {
                                ForEach(manifest.settings, id: \.key) { setting in
                                    FrogRow(setting.title, caption: setting.help) { control(setting) }
                                }
                            }
                        }
                        let shortcutActions = PluginRuntime.allows(item, .hotkeys) ? manifest.actions.filter { $0.parameters.allSatisfy { !($0.required ?? false) } } : []
                        if !shortcutActions.isEmpty {
                            FrogSection("Shortcuts") {
                                ForEach(shortcutActions, id: \.id) { action in
                                    FrogRow(action.title, caption: plugins.shortcutIssues[PluginRuntime.shortcutKey(id, action.id)]) {
                                        HotkeyRecorder(hotkey: shortcutBinding(action.id))
                                    }
                                }
                            }
                        }
                        if PluginRuntime.allows(item, .files) {
                            let folders = (try? plugins.folders(id).list()) ?? []
                            FrogSection("Folders", footer: "The plugin reads and changes only these folders. It asks for one when it needs it.") {
                                if folders.isEmpty {
                                    FrogRow("No folders yet")
                                } else {
                                    ForEach(folders, id: \.id) { folder in
                                        FrogRow(folder.name, caption: (folder.path as NSString).abbreviatingWithTildeInPath) {
                                            IconAction(title: "Remove \(folder.name)", symbol: "minus.circle") {
                                                do { try plugins.forgetFolder(id, folder.id) } catch { model.report(error) }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if manifest.settings.isEmpty, shortcutActions.isEmpty, !PluginRuntime.allows(item, .files) {
                            Text("This plugin has no settings.").font(FrogType.body).foregroundStyle(FrogStyle.muted)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 440).fixedSize(horizontal: false, vertical: true).bottomScrollFade()
            FrogSheetButtons(padded: false) { FrogPrimaryButton("Done", action: done) }
        }
        .padding(FrogStyle.sheetPadding).frame(width: 520)
        .font(FrogType.body).foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent)
    }

    @ViewBuilder private func control(_ setting: PluginSetting) -> some View {
        let value = try? plugins.settingValue(id, setting)
        switch setting.type {
        case .boolean:
            Toggle("", isOn: Binding(get: { if case .boolean(let flag)? = value { flag } else { false } },
                                     set: { save(setting, .boolean($0)) }))
                .toggleStyle(.frogSwitch).controlSize(.small).labelsHidden().accessibilityLabel(setting.title)
        case .choice:
            let current: String = if case .text(let text)? = value { text } else { setting.choices?.first ?? "" }
            FrogDropdown(selected: current, options: setting.choices ?? [], width: 180, title: { $0 }) { save(setting, .text($0)) }
        case .integer:
            let current: Int? = if case .integer(let number)? = value { number } else { nil }
            PluginNumberSetting(value: current, minimum: setting.minimum, maximum: setting.maximum, title: setting.title) {
                save(setting, .text(String($0)))
            }
        case .text:
            let current: String = if case .text(let text)? = value { text } else { "" }
            PluginTextSetting(value: current, secret: false, width: 220) { save(setting, .text($0)) }
        case .secret:
            PluginTextSetting(value: "", secret: true, width: 220, saved: value != nil) { text in
                save(setting, text.isEmpty ? nil : .text(text))
            }
        }
    }

    private func save(_ setting: PluginSetting, _ value: PluginSettingValue?) {
        do { try plugins.setSetting(id, setting.key, value) } catch { model.report(error) }
    }

    private func shortcutBinding(_ action: String) -> Binding<Hotkey?> {
        Binding(get: { plugins.shortcut(id, action: action)?.hotkey }, set: { hotkey in
            do { try plugins.setShortcut(id, action: action, to: try hotkey.map { try Shortcut($0) }) } catch { model.report(error) }
        })
    }
}

/// A text, number or secret setting, kept when the user presses Return or leaves the field.
private struct PluginTextSetting: View {
    let value: String
    let secret: Bool
    let width: CGFloat
    var saved = false
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if secret { SecureField(saved ? "Saved in the Keychain" : "Not set", text: $draft) }
                else { TextField("", text: $draft) }
            }
            .textFieldStyle(.plain).font(FrogType.body).focused($focused)
            .padding(.horizontal, 8).frogControlSurface().frame(width: width)
            .onSubmit(save)
            if secret, saved {
                IconAction(title: "Remove the saved value", symbol: "xmark.circle") { draft = ""; commit("") }
            }
        }
        .onAppear { draft = secret ? "" : value }
        .onChange(of: value) { _, new in if !focused, !secret { draft = new } }
        .onChange(of: focused) { _, now in if !now { save() } }
    }

    private func save() {
        if secret { guard !draft.isEmpty else { return }; commit(draft); draft = ""; return }
        if draft != value { commit(draft) }
    }
}

/// A whole number in the same field as the text settings, its digits on the trailing side; the arrow keys step it by
/// one, and it stays within the plugin's bounds, which its tooltip names.
private struct PluginNumberSetting: View {
    let value: Int?
    let minimum: Int?
    let maximum: Int?
    let title: String
    let commit: (Int) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        // Minus and plus beside the field show that it steps, and step it without the keyboard; each stops at its bound.
        HStack(spacing: FrogStyle.space4) {
            IconAction(title: "Decrease \(L10n.text(title))", symbol: "minus") { step(by: -1) }
                .disabled(atBound(minimum))
            field
            IconAction(title: "Increase \(L10n.text(title))", symbol: "plus") { step(by: 1) }
                .disabled(atBound(maximum))
                // The plus ends on the content edge, level with switches and buttons; only its hover fill reaches past.
                .padding(.trailing, -IconAction.glyphInset)
        }
    }

    private func atBound(_ bound: Int?) -> Bool {
        guard let bound, let current = Int(draft) ?? value else { return false }
        return current == bound
    }

    private var field: some View {
        TextField("", text: $draft).textFieldStyle(.plain).font(FrogType.body.monospacedDigit())
            .multilineTextAlignment(.trailing).focused($focused)
            .padding(.horizontal, FrogStyle.space8).frogControlSurface().frame(width: 64)
            .accessibilityLabel(L10n.text(title)).help(range ?? "")
            .onSubmit(save)
            .onKeyPress(.upArrow) { step(by: 1); return .handled }
            .onKeyPress(.downArrow) { step(by: -1); return .handled }
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(by: 1)
                case .decrement: step(by: -1)
                @unknown default: break
                }
            }
            .onAppear { draft = value.map(String.init) ?? "" }
            .onChange(of: value) { _, new in if !focused { draft = new.map(String.init) ?? "" } }
            .onChange(of: focused) { _, now in if !now { save() } }
    }

    /// "1–120", or the one bound the plugin sets.
    private var range: String? {
        switch (minimum, maximum) {
        case let (low?, high?): "\(low)–\(high)"
        case let (low?, nil): "At least \(low)"
        case let (nil, high?): "At most \(high)"
        default: nil
        }
    }

    private func step(by delta: Int) {
        // The field shows the stepped number at once, even while it has focus and ignores `value` changes.
        let stepped = clamped((Int(draft) ?? value ?? 0) + delta)
        draft = String(stepped)
        if stepped != value { commit(stepped) }
    }

    private func clamped(_ number: Int) -> Int { min(max(number, minimum ?? .min), maximum ?? .max) }

    private func save() {
        guard let number = Int(draft.trimmingCharacters(in: .whitespaces)) else { draft = value.map(String.init) ?? ""; return }
        let kept = clamped(number)
        draft = String(kept)
        if kept != value { commit(kept) }
    }
}
