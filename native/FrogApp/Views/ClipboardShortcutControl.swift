import SwiftUI
import FrogCore

/// The Quick paste shortcut, in the Clipboard page's header.
struct ClipboardShortcutControl: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            Text("Quick paste").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
            HotkeyRecorder(hotkey: Binding(get: { model.configuration.preferences.workflowSettings.effectiveClipboardHistoryHotkey }, set: { value in
                var preferences = model.configuration.preferences.workflowSettings
                preferences.clipboardHistoryHotkey = value
                do { try model.saveWorkflowPreferences(preferences) } catch { model.report(error) }
            }), showsClearButton: false, purpose: .clipboardHistory)
                .controlSize(.small).fixedSize().environment(\.compactRowTitle, "Quick paste")
        }
    }
}
