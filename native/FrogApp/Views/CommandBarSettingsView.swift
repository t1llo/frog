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
            // Two cards, both headed: the keys that open the bar, then the order of what it finds.
            FrogSection("Shortcut") {
                FrogRow("Open the bar", caption: "Works in any app.") {
                    HotkeyRecorder(hotkey: Binding(get: { plugin.settings.shortcut.hotkey }, set: { key in
                        guard let key, let shortcut = try? Shortcut(key) else { return }
                        plugin.save { $0.shortcut = shortcut }
                    }), showsClearButton: false)
                }
                // Using ⌘Space instead of Spotlight is part of choosing the shortcut, so it shares the card as a
                // sub-group; its own rows say a shortcut problem, so the note is not repeated above them.
                SectionCaption(text: "⌘Space instead of Spotlight").padding(.top, FrogStyle.space6)
                CommandBarSetupView()
            }
            FrogSection("Results") {
                CommandChoicesRows(plugin: plugin, choices: model.commandChoices)
            }
        }
    }
}

/// Learn from your choices, and how much was learned, as rows of the page's one card. The count comes from the
/// store, which the page observes.
private struct CommandChoicesRows: View {
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
        VStack(alignment: .leading, spacing: FrogStyle.space2) {
            FrogRow("Learn from your choices", caption: "Rows you pick move up. Kept on this Mac.") {
                Toggle("Learn from your choices", isOn: Binding(get: { plugin.settings.learnChoices }, set: { on in
                    plugin.save { $0.learnChoices = on }
                })).labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
            }
            // What was learned stays until it is forgotten, whether learning is on or not, so the row always shows.
            FrogRow(remembered) {
                Button("Forget…", role: .destructive) { confirmingForget = true }
                    .buttonStyle(.frog(.destructive)).disabled(choices.count == 0 && choices.issue == nil)
                    .help(choices.count == 0 && choices.issue == nil ? L10n.text("Nothing to forget yet") : "")
            }
            if let issue = choices.issue { FrogRowNote(text: issue, tone: FrogStyle.warning) }
        }
        .confirmationDialog("Forget learned choices?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { choices.forget() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The command bar goes back to its usual order.") }
    }
}
