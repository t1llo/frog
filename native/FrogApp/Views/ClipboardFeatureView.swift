import SwiftUI
import FrogCore

struct ClipboardFeatureView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        PageScroll {
            PageHeader(title: "Clipboard", subtitle: "Settings for copied text and quick pasting.")
            SettingsSection(title: "Clipboard history") {
                CompactRow(title: "Browse copied text", detail: "One history, alongside your text and audio activity.") {
                    Button("Open clipboard history", systemImage: "clock.arrow.circlepath") { model.openClipboardHistoryPage() }
                }
                Text("The last 100 items stay in memory. Disabling Clipboard or quitting Frog clears them; clipboard text is never added to saved writing history.")
                    .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
            }
            SettingsSection(title: "Quick paste picker") {
                CompactRow(title: "Keyboard shortcut", detail: "Find and paste a recent clip without leaving your current app.") {
                    HotkeyRecorder(hotkey: Binding(get: { model.configuration.preferences.workflowSettings.effectiveClipboardHistoryHotkey }, set: { value in
                        var preferences = model.configuration.preferences.workflowSettings
                        preferences.clipboardHistoryHotkey = value
                        do { try model.saveWorkflowPreferences(preferences) } catch { model.report(error) }
                    }), showsClearButton: false, purpose: .clipboardHistory)
                }
                if let issue = model.hotkeyErrors[AppModel.clipboardHistoryID] { InlineIssue(message: issue) }
                Button("Open quick paste picker") { model.showClipboardHistory() }
            }
            Text("Sensitive entries stay hidden until revealed in History. Manage collection in Features → Clipboard.")
                .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
        }
    }
}
