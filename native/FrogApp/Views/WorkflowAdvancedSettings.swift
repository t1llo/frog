import SwiftUI
import FrogCore

struct WorkflowAdvancedSettings: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        FrogCard {
            VStack(alignment: .leading, spacing: 12) {
                Menu {
                    ForEach(LocalModelDescriptor.catalog.filter { $0.kind == .text }) { item in
                        Button(item.name) { update { $0.defaultLocalTextModelID = item.id } }
                    }
                    ForEach(model.configuration.providers) { provider in
                        Button(provider.name + " · " + provider.model) { do { try model.setDefaultProvider(id: provider.id) } catch { model.report(error) } }
                    }
                } label: {
                    HStack { Text("Default text"); Spacer(); Text(defaultText).foregroundStyle(.secondary); Image(systemName: "chevron.down") }
                }
                Picker("Unload idle models", selection: Binding(get: { model.configuration.preferences.workflowSettings.idleUnloadSeconds }, set: { seconds in update { $0.idleUnloadSeconds = seconds } })) {
                    Text("Immediately").tag(0); Text("After 2 minutes").tag(120); Text("After 5 minutes").tag(300); Text("After 15 minutes").tag(900)
                }
                HStack { Text("Shortcut reference panel"); Spacer(); HotkeyRecorder(hotkey: Binding(get: { model.configuration.preferences.workflowSettings.shortcutPanelHotkey }, set: { key in update { $0.shortcutPanelHotkey = key } })) }
                if let error = model.hotkeyErrors[AppModel.shortcutPanelID] { Text(error).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button("Show shortcuts") { model.showShortcuts() }
                    Button("Unload models now") { Task { await model.localModels.unload() } }.disabled(model.localModels.busy || model.dictation.active)
                }
            }.font(.system(size: 12))
        }
    }
    private var defaultText: String {
        if let id = model.configuration.preferences.workflowSettings.defaultLocalTextModelID { return LocalModelDescriptor.find(id)?.name ?? id }
        return model.configuration.providers.first { $0.id == model.configuration.defaultProviderID }?.name ?? "Choose model"
    }
    private func update(_ body: (inout WorkflowPreferences) -> Void) {
        var value = model.configuration.preferences.workflowSettings; body(&value)
        do { try model.saveWorkflowPreferences(value) } catch { model.report(error) }
    }
}
