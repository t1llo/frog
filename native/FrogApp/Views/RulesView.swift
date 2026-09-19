import SwiftUI
import FrogCore

struct RulesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: Rule?
    @State private var deleting: Rule?

    var body: some View {
        VStack(spacing: 0) {
            EditorHeading(title: "Writing rules", subtitle: "Select text in another app, then press a rule’s shortcut to rewrite it in place.")
            List {
                ForEach(model.configuration.rules) { rule in
                    HStack(spacing: 12) {
                        Image(systemName: rule.preset ? "sparkles" : "text.badge.plus")
                            .foregroundStyle(rule.enabled ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(rule.name).font(.headline)
                                if !rule.enabled { Text("Disabled").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(rule.instructions).lineLimit(2).foregroundStyle(.secondary)
                            if let error = model.hotkeyErrors[rule.id] { InlineIssue(message: error) }
                        }
                        Spacer()
                        Text(rule.hotkey.map(HotkeyManager.display) ?? "No shortcut")
                            .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                        Button("Edit") { editing = rule }
                            .accessibilityLabel("Edit \(rule.name)")
                        Menu {
                            Button("Duplicate") { duplicate(rule) }
                            Button(rule.enabled ? "Disable" : "Enable") {
                                var updated = rule; updated.enabled.toggle()
                                do { try model.saveRule(updated) } catch { model.report(error) }
                            }
                            Button("Delete…", role: .destructive) { deleting = rule }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).frame(width: 24)
                        .accessibilityLabel("Actions for \(rule.name)")
                    }.padding(.vertical, 8)
                }
            }
            .overlay {
                if model.configuration.rules.isEmpty {
                    ContentUnavailableView("No rules yet", systemImage: "text.badge.plus", description: Text("Create a custom rule or add a preset below."))
                }
            }
            HStack {
                Button { editing = Rule() } label: { Label("New rule", systemImage: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
                Menu("Add preset") {
                    ForEach(Rule.presets) { preset in
                        Button(preset.name) {
                            var draft = preset
                            draft.hotkey = nil
                            editing = draft
                        }
                    }
                }
                Spacer()
                Text("Output is copied and safely replaces the original selection.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding()
        }
        .sheet(item: $editing) { rule in RuleEditor(rule: rule).environmentObject(model) }
        .confirmationDialog("Delete \(deleting?.name ?? "rule")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete rule", role: .destructive) {
                guard let rule = deleting else { return }
                do { try model.deleteRule(id: rule.id) } catch { model.report(error) }
                deleting = nil
            }
        } message: { Text("Its global shortcut will also be removed.") }
    }

    private func duplicate(_ rule: Rule) {
        var copy = rule
        copy.id = UUID(); copy.name += " copy"; copy.preset = false; copy.hotkey = nil
        editing = copy
    }
}

private struct RuleEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var rule: Rule
    @State private var saveError: String?

    private var validation: String? {
        if rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give this rule a name." }
        if rule.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter instructions for the model." }
        if rule.instructions.contains("{{language}}") && rule.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Set a target language for the {{language}} placeholder." }
        if rule.enabled, let hotkey = rule.hotkey, model.configuration.rules.contains(where: { $0.id != rule.id && $0.enabled && $0.hotkey == hotkey }) { return "Another enabled rule already uses this shortcut." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorHeading(title: rule.preset ? "Edit preset" : "Edit rule", subtitle: "Instructions describe the transformation; selected text is sent separately.")
            Form {
                Section("Rule") {
                    TextField("Name", text: $rule.name)
                    Toggle("Enabled", isOn: $rule.enabled)
                    VStack(alignment: .leading) {
                        Text("Instructions")
                        TextEditor(text: $rule.instructions).font(.body).frame(minHeight: 120)
                            .accessibilityLabel("Rule instructions")
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                        Text("Use {{language}} to insert the target language. Ask for only the revised text for in-place replacement.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Model and language") {
                    Picker("Provider", selection: $rule.providerID) {
                        Text("Use default provider").tag(UUID?.none)
                        ForEach(model.configuration.providers) { Text($0.name).tag(Optional($0.id)) }
                        if let id = rule.providerID, !model.configuration.providers.contains(where: { $0.id == id }) {
                            Text("Unavailable provider").tag(Optional(id))
                        }
                    }
                    TextField("Model override", text: $rule.model, prompt: Text("Use provider’s model"))
                    TextField("Target language", text: $rule.targetLanguage, prompt: Text("Optional, e.g. English"))
                }
                Section("Global shortcut") {
                    HotkeyRecorder(hotkey: $rule.hotkey)
                    Text("Click Record, then press a key with Control, Option, or Command. Escape cancels recording. Avoid shortcuts used by your other apps.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let validation { InlineIssue(message: validation) }
                if let saveError { InlineIssue(message: saveError) }
            }.formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save rule") {
                    do {
                        rule.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        rule.model = rule.model.trimmingCharacters(in: .whitespacesAndNewlines)
                        rule.targetLanguage = rule.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
                        try model.saveRule(rule); dismiss()
                    } catch { saveError = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(validation != nil)
            }.padding()
        }.frame(width: 600, height: 700)
    }
}
