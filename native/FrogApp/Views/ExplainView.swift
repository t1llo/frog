import SwiftUI
import FrogCore

/// Answer rules and how answers behave.
struct ExplainView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        RulesView(fixedCategory: .text, output: .panel) {
            SettingsSection(title: "Settings") {
                CompactRow(title: "Include surrounding text",
                           detail: "Sends the sentence or paragraph around the selection, up to 1,000 characters, so the answer fits the context.") {
                    Toggle("Include surrounding text", isOn: Binding(get: { model.configuration.preferences.explainSettings.includeContext }, set: { value in
                        update { $0.includeContext = value }
                    })).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }

    private func update(_ change: (inout ExplainSettings) -> Void) {
        do {
            try model.updateToolkit { toolkit in
                var settings = toolkit.explain ?? ExplainSettings()
                change(&settings)
                toolkit.explain = settings.normalized
            }
        } catch { model.report(error) }
    }
}
