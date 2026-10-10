import SwiftUI
import FrogCore

struct WindowSwitcherFeatureView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CompactRow(title: "Switch windows") {
                HotkeyRecorder(hotkey: Binding(get: {
                    model.configuration.preferences.toolkitSettings.effectiveWindowSwitcherHotkey
                }, set: { value in
                    var preferences = model.configuration.preferences
                    preferences.setFeature(.windowSwitcher, enabled: preferences.featureEnabled(.windowSwitcher))
                    preferences.toolkit?.windowSwitcherHotkey = value
                    do { try model.savePreferences(preferences) } catch { model.report(error) }
                }), showsClearButton: false, purpose: .windowSwitcher)
            }
            if !model.windowSwitcherReady,
               !["Not started", "Paused while recording a shortcut"].contains(model.windowSwitcherStatus) {
                InlineIssue(message: model.windowSwitcherStatus)
            }
            Text("Hold the shortcut’s modifiers to keep switching; release to focus the selected window. Add Shift to move backward.")
                .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
        }
    }
}
