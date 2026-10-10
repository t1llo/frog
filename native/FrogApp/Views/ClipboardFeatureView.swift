import SwiftUI
import FrogCore

struct ClipboardFeatureView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CompactRow(title: "Quick paste shortcut") {
                HotkeyRecorder(hotkey: Binding(get: { model.configuration.preferences.workflowSettings.effectiveClipboardHistoryHotkey }, set: { value in
                    var preferences = model.configuration.preferences.workflowSettings
                    preferences.clipboardHistoryHotkey = value
                    do { try model.saveWorkflowPreferences(preferences) } catch { model.report(error) }
                }), showsClearButton: false, purpose: .clipboardHistory)
            }
            if let issue = model.hotkeyErrors[AppModel.clipboardHistoryID] { InlineIssue(message: issue) }
            Button("Open clipboard history", systemImage: "clock.arrow.circlepath") { model.openClipboardHistoryPage() }
            Text("The last 100 items stay in memory until Clipboard is disabled or Frog quits. Browse and reveal sensitive entries in History → Clipboard.")
                .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
        }
    }
}
