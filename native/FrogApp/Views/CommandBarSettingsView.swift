import SwiftUI
import FrogCore

struct CommandBarSettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        PageScroll {
            PageHeader(title: "Command bar")
            SettingsSection(title: "Shortcut") {
                CompactRow(title: "Open command bar") {
                    HotkeyRecorder(hotkey: Binding(get: { model.configuration.preferences.toolkitSettings.effectiveCommandBarHotkey }, set: { key in
                        do { try model.updateToolkit { $0.commandBarHotkey = key } } catch { model.report(error) }
                    }), showsClearButton: false)
                    Button("Open") { model.showCommandBar() }
                }
                if let issue = model.hotkeyErrors[AppModel.commandBarID] { Text(issue).font(.caption).foregroundStyle(FrogStyle.warning) }
            }
            CommandChoicesSection(choices: model.commandChoices)
            Text("Type an app, window or file, or calculate 25% * 200.")
                .font(.system(size: 12)).foregroundStyle(FrogStyle.muted)
            CommandBarSetupView()
        }
    }
}

/// Learn from your choices, and how much was learned. The count comes from the store, which the page observes.
private struct CommandChoicesSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var choices: CommandChoiceStore
    @State private var confirmingForget = false
    private var learning: Bool { model.configuration.preferences.toolkitSettings.commandBarSettings.learnChoices }
    private var remembered: String {
        switch choices.count {
        case 0: "Nothing learned yet"
        case 1: "Frog remembers 1 choice"
        default: "Frog remembers \(choices.count.formatted()) choices"
        }
    }
    var body: some View {
        SettingsSection(title: "Ranking") {
            CompactRow(title: "Learn from your choices", detail: "Rows you pick move up. Kept on this Mac.") {
                Toggle("Learn from your choices", isOn: Binding(get: { learning }, set: { on in
                    do {
                        try model.updateToolkit { toolkit in
                            var settings = toolkit.commandBarSettings; settings.learnChoices = on; toolkit.commandBar = settings
                        }
                    } catch { model.report(error) }
                })).labelsHidden().toggleStyle(.switch)
            }
            if learning || choices.issue != nil {
                CompactRow(title: remembered) {
                    Button("Forget learned choices…", role: .destructive) { confirmingForget = true }
                        .disabled(choices.count == 0 && choices.issue == nil)
                }
                if let issue = choices.issue {
                    Text(issue).font(.caption).foregroundStyle(FrogStyle.warning).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .confirmationDialog("Forget learned choices?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { model.forgetCommandChoices() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The command bar goes back to its usual order. This cannot be undone.") }
    }
}
