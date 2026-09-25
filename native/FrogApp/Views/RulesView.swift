import SwiftUI
import FrogCore
import AppKit
import UniformTypeIdentifiers

struct RulesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: Rule?
    @State private var deleting: Rule?
    @State private var filter: RuleCategory?

    var body: some View {
        PageScroll {
            PageHeader(title: "Rules", subtitle: "Your shortcuts for text, speech and apps.") {
                Button { editing = Rule() } label: { Label("New rule", systemImage: "plus") }
                    .buttonStyle(FrogButtonStyle(primary: true)).keyboardShortcut("n", modifiers: .command)
            }
            Picker("Category", selection: $filter) {
                Text("All").tag(RuleCategory?.none)
                ForEach(RuleCategory.allCases) { Text($0.title).tag($0 as RuleCategory?) }
            }.pickerStyle(.segmented)
            LazyVStack(spacing: 8) {
                ForEach(model.configuration.rules.filter { filter == nil || $0.category == filter }) { rule in ruleCard(rule) }
                if model.configuration.rules.isEmpty {
                    FrogCard {
                        FrogEmptyState(symbol: "square.stack.3d.up", title: "Your words, your way", message: "Create a rule with your own instructions and shortcut.")
                    }
                }
            }
        }
        .sheet(item: $editing) { rule in RuleEditor(rule: rule).environmentObject(model) }
        .confirmationDialog("Delete \(deleting?.name ?? "rule")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete rule", role: .destructive) {
                guard let rule = deleting else { return }
                do { try model.deleteRule(id: rule.id) } catch { model.report(error) }
                deleting = nil
            }
        } message: { Text("Its global shortcut will also be removed.") }
    }

    private func ruleCard(_ rule: Rule) -> some View {
        let provider = model.configuration.providers.first { $0.id == (rule.providerID ?? model.configuration.defaultProviderID) }
        return FrogCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(rule.name).font(.system(size: 13, weight: .semibold))
                        Text(rule.category == .application ? "Open or focus the selected application" : (rule.targetLanguage.isEmpty ? rule.instructions : rule.instructions.replacingOccurrences(of: "{{language}}", with: rule.targetLanguage)))
                            .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).lineLimit(1)
                        Text(rule.category == .application ? (rule.action?.applicationBundleID ?? "Choose app") : "\(rule.category.title) · \(rule.action?.localTextModelID.flatMap { LocalModelDescriptor.find($0)?.name } ?? provider?.name ?? "Default model")")
                            .font(.system(size: 10)).foregroundStyle(FrogStyle.muted).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    ShortcutBadge(text: rule.hotkey.map(HotkeyManager.display) ?? "No shortcut")
                    Toggle("Enable \(rule.name)", isOn: Binding(get: { rule.enabled }, set: { enabled in
                        var updated = rule; updated.enabled = enabled
                        do { try model.saveRule(updated) } catch { model.report(error) }
                    })).toggleStyle(.switch).labelsHidden().controlSize(.small)
                        .help(rule.enabled ? "Rule enabled" : "Rule disabled")
                    HStack(spacing: 4) {
                        IconAction(title: "Edit \(rule.name)", symbol: "pencil") { editing = rule }
                        IconAction(title: "Duplicate \(rule.name)", symbol: "doc.on.doc") { duplicate(rule) }
                        IconAction(title: "Delete \(rule.name)", symbol: "trash", destructive: true) { deleting = rule }
                    }
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

    init(rule: Rule) {
        var draft = rule
        // Preserve legacy translation behavior while removing the separate language field.
        if !draft.targetLanguage.isEmpty {
            draft.instructions = draft.instructions.replacingOccurrences(of: "{{language}}", with: draft.targetLanguage)
            draft.targetLanguage = ""
        }
        _rule = State(initialValue: draft)
    }

    private var modelLabel: String {
        if let id = rule.action?.localTextModelID { return LocalModelDescriptor.find(id)?.name ?? id }
        guard let id = rule.providerID else {
            if rule.model.isEmpty { return "Use default provider & model" }
            return rule.model
        }
        guard let provider = model.configuration.providers.first(where: { $0.id == id }) else { return "Unavailable model — choose another" }
        return "\(provider.name) · \(provider.modelName(rule.model.isEmpty ? provider.model : rule.model))"
    }

    private var validation: String? {
        if rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give this rule a name." }
        if rule.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter instructions for the model." }
        if rule.instructions.contains("{{language}}") { return "Write the language directly in your instructions." }
        if rule.enabled, let hotkey = rule.hotkey, model.configuration.rules.contains(where: { $0.id != rule.id && $0.enabled && $0.hotkey == hotkey }) { return "Another enabled rule already uses this shortcut." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorHeading(title: "Rule settings", subtitle: "Choose instructions, a model, and a shortcut.")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FrogCard {
                        VStack(alignment: .leading, spacing: 18) {
                            LabeledField(title: "Rule name") { TextField("Rule name", text: $rule.name).labelsHidden() }
                            Picker("Action", selection: Binding(get: { rule.category }, set: { category in rule.action = RuleAction(category: category); rule.providerID = nil; rule.model = "" })) {
                                ForEach(RuleCategory.allCases) { Text($0.title).tag($0) }
                            }
                            if rule.category == .application {
                                HStack {
                                    Text(rule.action?.applicationPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No application selected")
                                    Spacer()
                                    Button("Choose app…") { chooseApplication() }
                                }
                            } else {
                            LabeledField(title: "Instructions") {
                                TextEditor(text: $rule.instructions).font(.system(size: 13)).scrollContentBackground(.hidden)
                                    .frame(minHeight: 100).accessibilityLabel("Rule instructions")
                            }
                            }
                        }
                    }
                    if rule.category != .application {
                    SectionCaption(text: rule.category == .audio ? "Cleanup model" : "Model")
                    FrogCard {
                        VStack(alignment: .leading, spacing: 16) {
                            FrogMenu(title: "Model override", value: modelLabel) {
                                Button("Use default") { rule.providerID = nil; rule.model = ""; rule.action?.localTextModelID = nil }
                                Section("Built-in local models") {
                                    ForEach(LocalModelDescriptor.catalog.filter { $0.kind == .text }) { item in
                                        Button(item.name) {
                                            if rule.action == nil { rule.action = RuleAction() }
                                            rule.action?.localTextModelID = item.id; rule.providerID = nil; rule.model = ""
                                        }
                                    }
                                }
                                ForEach(model.configuration.providers) { provider in
                                    Section(provider.name) {
                                        ForEach(provider.models) { choice in
                                            Button(choice.name) { rule.providerID = provider.id; rule.model = choice.id; rule.action?.localTextModelID = nil }
                                        }
                                    }
                                }
                            }
                            if model.configuration.providers.isEmpty {
                                Text("Add a provider and choose its models in Providers first.")
                                    .font(.system(size: 12)).foregroundStyle(FrogStyle.muted)
                            }
                        }
                    }
                    }
                    if rule.category == .audio {
                        FrogCard {
                            VStack(spacing: 12) {
                                Picker("Speech model", selection: actionBinding(\.audioModelID, fallback: nil)) {
                                    Text("Default").tag(String?.none)
                                    ForEach(LocalModelDescriptor.catalog.filter { $0.kind == .audio }) { Text($0.name).tag($0.id as String?) }
                                }
                                Picker("Recording", selection: actionBinding(\.recordingMode, fallback: nil)) {
                                    Text("Default").tag(RecordingMode?.none)
                                    ForEach(RecordingMode.allCases, id: \.self) { Text($0.title).tag($0 as RecordingMode?) }
                                }
                                Picker("Output", selection: actionBinding(\.output, fallback: nil)) {
                                    Text("Default").tag(TranscriptOutput?.none)
                                    ForEach(TranscriptOutput.allCases, id: \.self) { Text($0.title).tag($0 as TranscriptOutput?) }
                                }
                                Toggle("Clean up transcript", isOn: actionBinding(\.cleanup, fallback: true))
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
        }.frame(width: 600, height: 620).background(FrogStyle.canvas)
            .foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).buttonStyle(FrogButtonStyle())
    }
    private func actionBinding<T>(_ key: WritableKeyPath<RuleAction, T>, fallback: T) -> Binding<T> {
        Binding(get: { rule.action?[keyPath: key] ?? fallback }, set: { value in
            if rule.action == nil { rule.action = RuleAction(category: rule.category) }
            rule.action?[keyPath: key] = value
        })
    }
    private func chooseApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        rule.action?.applicationPath = url.path; rule.action?.applicationBundleID = id
        if rule.name == "Custom rule" { rule.name = "Open " + url.deletingPathExtension().lastPathComponent }
    }
}
