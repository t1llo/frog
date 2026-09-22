import SwiftUI
import FrogCore

struct RulesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: Rule?
    @State private var deleting: Rule?

    var body: some View {
        PageScroll {
            PageHeader(title: "A shortcut to better words.", subtitle: "Your writing rules, ready wherever you type.") {
                Button { editing = Rule() } label: { Label("New rule", systemImage: "plus") }
                    .buttonStyle(FrogButtonStyle(primary: true)).keyboardShortcut("n", modifiers: .command)
            }
            FrogCard {
                HStack(spacing: 16) {
                    SymbolTile(symbol: "cursorarrow.and.square.on.square.dashed")
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Select. Press. Polished.").font(.system(size: 14, weight: .semibold))
                        Text("Select text in any supported app and press a rule’s shortcut. Frog rewrites it in place and copies the result.")
                            .font(.system(size: 12)).foregroundStyle(FrogStyle.muted).lineSpacing(3)
                    }
                }
            }
            HStack {
                SectionCaption(text: "Your rules · \(model.configuration.rules.count)")
                Spacer()
                Menu("Add preset") {
                    ForEach(Rule.presets) { preset in
                        Button(preset.name) {
                            var draft = preset
                            draft.hotkey = nil
                            editing = draft
                        }
                    }
                }.fixedSize().menuStyle(.borderlessButton).foregroundStyle(FrogStyle.accent)
            }
            LazyVStack(spacing: 12) {
                ForEach(model.configuration.rules) { rule in ruleCard(rule) }
                if model.configuration.rules.isEmpty {
                    FrogCard {
                        FrogEmptyState(symbol: "square.stack.3d.up", title: "Your words, your way", message: "Create a rule with your own instructions, or start with a ready-made preset.")
                    }
                }
            }
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

    private func ruleCard(_ rule: Rule) -> some View {
        let provider = model.configuration.providers.first { $0.id == (rule.providerID ?? model.configuration.defaultProviderID) }
        let modelName = rule.model.isEmpty ? provider?.model : rule.model
        return FrogCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    SymbolTile(symbol: rule.targetLanguage.isEmpty ? "text.badge.checkmark" : "character.bubble")
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Text(rule.name).font(.system(size: 15, weight: .semibold))
                            if rule.preset { FrogBadge(text: "Preset") }
                        }
                        Text(rule.instructions).font(.system(size: 12)).foregroundStyle(FrogStyle.muted)
                            .lineSpacing(3).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("Enable \(rule.name)", isOn: Binding(get: { rule.enabled }, set: { enabled in
                        var updated = rule; updated.enabled = enabled
                        do { try model.saveRule(updated) } catch { model.report(error) }
                    })).toggleStyle(.switch).labelsHidden().controlSize(.small)
                        .help(rule.enabled ? "Rule enabled" : "Rule disabled")
                }
                HStack(spacing: 8) {
                    ShortcutBadge(text: rule.hotkey.map(HotkeyManager.display) ?? "No shortcut")
                    Text(provider?.name ?? "No provider")
                        .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).lineLimit(1)
                    if let modelName {
                        Text("·").foregroundStyle(FrogStyle.muted)
                        Text(modelName).font(.system(size: 11)).foregroundStyle(FrogStyle.muted).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button("Edit rule") { editing = rule }.accessibilityLabel("Edit \(rule.name)")
                    Menu {
                        Button("Duplicate") { duplicate(rule) }
                        Button("Delete…", role: .destructive) { deleting = rule }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).frame(width: 20)
                        .accessibilityLabel("Actions for \(rule.name)")
                }
                if let error = model.hotkeyErrors[rule.id] { InlineIssue(message: error) }
            }
        }
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
            EditorHeading(title: rule.preset ? "Make it your own." : "A little writing magic.", subtitle: "Give your rule a name, a direction, and a shortcut.")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FrogCard {
                        VStack(alignment: .leading, spacing: 18) {
                            LabeledField(title: "Rule name") { TextField("Rule name", text: $rule.name).labelsHidden() }
                            LabeledField(title: "Instructions") {
                                TextEditor(text: $rule.instructions).font(.system(size: 13)).scrollContentBackground(.hidden)
                                    .frame(minHeight: 100).accessibilityLabel("Rule instructions")
                            }
                            Text("Ask for only the revised text. Use {{language}} to insert your target language.")
                                .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                            SettingRow(title: "Rule enabled", description: "Make this rule available for processing.") {
                                Toggle("Rule enabled", isOn: $rule.enabled).toggleStyle(.switch).labelsHidden().controlSize(.small)
                            }
                        }
                    }
                    SectionCaption(text: "Intelligence & language")
                    FrogCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Picker("Provider", selection: $rule.providerID) {
                                Text("Use default provider").tag(UUID?.none)
                                ForEach(model.configuration.providers) { Text($0.name).tag(Optional($0.id)) }
                                if let id = rule.providerID, !model.configuration.providers.contains(where: { $0.id == id }) {
                                    Text("Unavailable provider").tag(Optional(id))
                                }
                            }
                            HStack(alignment: .top, spacing: 14) {
                                LabeledField(title: "Model override") { TextField("Use provider’s model", text: $rule.model).accessibilityLabel("Model override") }
                                LabeledField(title: "Target language") { TextField("Optional, e.g. English", text: $rule.targetLanguage).accessibilityLabel("Target language") }
                            }
                        }
                    }
                    SectionCaption(text: "Global shortcut")
                    FrogCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HotkeyRecorder(hotkey: $rule.hotkey)
                            Text("Include Control, Option, or Command. Escape cancels recording. Choose a shortcut your other apps don’t use.")
                                .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).lineSpacing(3)
                        }
                    }
                    if let validation { InlineIssue(message: validation) }
                    if let saveError { InlineIssue(message: saveError) }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
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
                }.buttonStyle(FrogButtonStyle(primary: true)).keyboardShortcut(.defaultAction).disabled(validation != nil)
            }.padding(20).background(FrogStyle.surface)
                .overlay(alignment: .top) { Rectangle().fill(FrogStyle.border).frame(height: 1) }
        }.frame(width: 640, height: 700).background(FrogStyle.canvas)
            .foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).buttonStyle(FrogButtonStyle())
    }
}
