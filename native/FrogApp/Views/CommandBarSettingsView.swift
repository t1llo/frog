import SwiftUI
import FrogCore

struct CommandBarSettingsView: View {
    @EnvironmentObject private var model: AppModel
    let plugin: CommandBarPlugin

    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Command bar", subtitle: "Apps, files, settings and actions as you type") {
                Button("Open") { plugin.show() }.buttonStyle(.frog())
            }
            FrogSection("Shortcut") {
                FrogRow("Open the bar") {
                    HotkeyRecorder(hotkey: Binding(get: { plugin.settings.shortcut.hotkey }, set: { key in
                        guard let key, let shortcut = try? Shortcut(key) else { return }
                        plugin.save { $0.shortcut = shortcut }
                    }), showsClearButton: false)
                }
                if let issue = plugin.shortcutIssue { FrogRowNote(text: issue, tone: FrogStyle.warning) }
            }
            CommandChoicesSection(plugin: plugin, choices: model.commandChoices)
            CommandBarSetupView()
        }
    }
}

/// Learn from your choices, and how much was learned. The count comes from the store, which the page observes.
private struct CommandChoicesSection: View {
    let plugin: CommandBarPlugin
    @ObservedObject var choices: CommandChoiceStore
    @State private var confirmingForget = false
    private var remembered: String {
        switch choices.count {
        case 0: "Nothing learned yet"
        case 1: "1 choice learned"
        default: "\(choices.count.formatted()) choices learned"
        }
    }

    var body: some View {
        FrogSection("Ranking") {
            FrogRow("Learn from your choices", caption: "Rows you pick move up. Kept on this Mac.") {
                Toggle("Learn from your choices", isOn: Binding(get: { plugin.settings.learnChoices }, set: { on in
                    plugin.save { $0.learnChoices = on }
                })).labelsHidden().toggleStyle(.switch)
            }
            if plugin.settings.learnChoices || choices.issue != nil {
                FrogRow(remembered) {
                    Button("Forget…", role: .destructive) { confirmingForget = true }
                        .buttonStyle(.frog(.destructive)).disabled(choices.count == 0 && choices.issue == nil)
                }
                if let issue = choices.issue { FrogRowNote(text: issue, tone: FrogStyle.warning) }
            }
        }
        .confirmationDialog("Forget learned choices?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { choices.forget() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The command bar goes back to its usual order.") }
    }
}
