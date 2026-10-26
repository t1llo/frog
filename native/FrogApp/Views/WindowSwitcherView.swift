import SwiftUI
import FrogCore

struct WindowSwitcherView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PageScroll {
            PageHeader(title: "Window switcher")
            SettingsSection(title: "Shortcut") {
                CompactRow(title: "Switch windows", detail: "Hold the modifiers to keep switching. Add Shift to go back.") {
                    HotkeyRecorder(hotkey: Binding(get: {
                        model.configuration.preferences.toolkitSettings.effectiveWindowSwitcherHotkey
                    }, set: { value in
                        var preferences = model.configuration.preferences
                        preferences.ensureToolkit()
                        preferences.toolkit?.windowSwitcherHotkey = value
                        do { try model.savePreferences(preferences) } catch { model.report(error) }
                    }), showsClearButton: false, purpose: .windowSwitcher)
                }
                if !model.windowSwitcherReady,
                   !["Not started", "Paused while recording a shortcut"].contains(model.windowSwitcherStatus) {
                    InlineIssue(message: model.windowSwitcherStatus)
                }
            }
        }
    }
}
