import SwiftUI
import FrogCore
import AppKit
import UniformTypeIdentifiers

struct RulesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: Rule?
    @State private var deleting: Rule?
    @State private var filter: RuleCategory? = .text
    @State private var search = ""
    private var rules: [Rule] {
        model.configuration.rules.filter { rule in
            (filter == nil || rule.category == filter) && (search.isEmpty ||
                [rule.name, rule.instructions, rule.action?.applicationBundleID ?? "", rule.category.title].contains { $0.localizedStandardContains(search) })
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Rules", subtitle: "") {
                Button("New rule", systemImage: "plus") {
                    var draft = filter == .audio ? Rule.dictationPreset : Rule()
                    draft.id = UUID(); draft.preset = false; draft.hotkey = nil
                    if filter == .application { draft.action = RuleAction(category: .application); draft.instructions = "" }
                    editing = draft
                }.keyboardShortcut("n", modifiers: .command)
            }
            ListToolbar(placeholder: "Search rules", search: $search) {
                ForEach(RuleCategory.allCases) { category in
                    FilterTag(title: category.title, selected: filter == category) { filter = filter == category ? nil : category }
                }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rules) { rule in
                        ruleRow(rule)
                        if rule.id != rules.last?.id { Divider().opacity(0.5) }
                    }
                    if rules.isEmpty { Text("No matching rules").font(.system(size: 12)).foregroundStyle(.secondary).padding(24) }
                }
            }.frogTableSurface()
        }.padding(20)
            .sheet(item: $editing) { RuleEditor(rule: $0).environmentObject(model) }
            .confirmationDialog("Delete \(deleting?.name ?? "rule")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete rule", role: .destructive) {
                    if let deleting { do { try model.deleteRule(id: deleting.id) } catch { model.report(error) } }
                    deleting = nil
                }
            }
    }
    private func ruleRow(_ rule: Rule) -> some View {
        HStack(spacing: 10) {
            Button { editing = rule } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(rule.name).font(.system(size: 12, weight: .medium)).foregroundStyle(FrogStyle.ink)
                    Text(model.ruleModelLabel(rule)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    if let issue = model.hotkeyErrors[rule.id] { Text(issue).font(.caption2).foregroundStyle(.orange) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if let hotkey = rule.hotkey { ShortcutBadge(text: HotkeyManager.display(hotkey)) }
            Toggle("Enable \(rule.name)", isOn: Binding(get: { rule.enabled }, set: { enabled in
                var updated = rule; updated.enabled = enabled
                do { try model.saveRule(updated) } catch { model.report(error) }
            })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            IconAction(title: "Edit rule", symbol: "pencil") { editing = rule }
            Menu {
                Button("Duplicate") { var copy = rule; copy.id = UUID(); copy.name += " copy"; copy.hotkey = nil; copy.preset = false; editing = copy }
                Button("Delete…", role: .destructive) { deleting = rule }
            } label: { Image(systemName: "ellipsis").frame(width: 16) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }.padding(.horizontal, 12).padding(.vertical, 12)
    }
}

@MainActor
extension AppModel {
    func localModelLabel(_ id: String) -> String {
        (LocalModelDescriptor.find(id)?.name ?? id) + (localModels.installed.contains(id) ? "" : " · " + L10n.text("Not downloaded"))
    }
    var defaultTextLabel: String {
        let prefs = configuration.preferences.workflowSettings
        if prefs.effectiveTextSource == .frog { return localModelLabel(prefs.defaultLocalTextModelID ?? "qwen-0.6b") }
        guard let provider = configuration.providers.first(where: { $0.id == configuration.defaultProviderID }) else { return "Not configured" }
        return provider.name + " · " + provider.modelName(provider.model)
    }
    func ruleModelLabel(_ rule: Rule) -> String {
        if rule.category == .application { return rule.action?.applicationPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Choose application" }
        if rule.category == .audio { return localModelLabel(rule.action?.audioModelID ?? configuration.preferences.workflowSettings.audioModelID) }
        guard let provider = try? resolved(rule) else { return L10n.text("Not configured") }
        if provider.id == Self.localProviderID { return localModelLabel(provider.model) }
        return provider.name + " · " + provider.modelName(provider.model)
    }
}

private struct RuleEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var rule: Rule
    @State private var issue: String?
    init(rule: Rule) {
        var draft = rule
        if !draft.targetLanguage.isEmpty { draft.instructions = draft.instructions.replacingOccurrences(of: "{{language}}", with: draft.targetLanguage); draft.targetLanguage = "" }
        _rule = State(initialValue: draft)
    }
    private var prefs: WorkflowPreferences { model.configuration.preferences.workflowSettings }
    private var defaultModel: String { rule.category == .audio ? model.localModelLabel(prefs.cleanupModelID) : model.defaultTextLabel }
    private var selectedModel: String {
        if rule.category == .text {
            let label = model.ruleModelLabel(rule)
            return rule.providerID == nil && rule.model.isEmpty && rule.action?.localTextModelID == nil ? L10n.text("Default") + " · " + label : label
        }
        if let id = rule.action?.localTextModelID { return model.localModelLabel(id) }
        if let provider = model.configuration.providers.first(where: { $0.id == rule.providerID }) { return provider.name + " · " + provider.modelName(rule.model.isEmpty ? provider.model : rule.model) }
        return L10n.text("Default") + " · " + defaultModel
    }
    var body: some View {
        VStack(spacing: 0) {
            EditorHeading(title: "Edit rule", subtitle: "")
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(title: "Rule") {
                    CompactRow(title: "Name") {
                        TextField("Name", text: $rule.name).textFieldStyle(.plain).padding(7)
                            .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
                    }
                    Divider()
                    CompactRow(title: "Action") {
                        CompactMenu(value: rule.category.title) {
                            ForEach(RuleCategory.allCases) { category in
                                Button(L10n.text(category.title)) {
                                    guard category != rule.category else { return }
                                    rule.action = RuleAction(category: category); rule.providerID = nil; rule.model = ""
                                    rule.instructions = category == .application ? "" : category == .audio ? Rule.dictationPreset.instructions : Rule().instructions
                                }
                            }
                        }
                    }
                    Divider()
                    if rule.category == .application {
                        CompactRow(title: "Application") {
                            Button(rule.action?.applicationPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? L10n.text("Choose…")) { chooseApplication() }
                        }
                    }
                    if rule.category == .audio { audioOptions }
                    if rule.category == .text || (rule.category == .audio && rule.action?.cleanup != false) {
                        CompactRow(title: rule.category == .audio ? "Cleanup model" : "Text model") { modelMenu }
                    }
                    Divider()
                    CompactRow(title: "Shortcut") { HotkeyRecorder(hotkey: $rule.hotkey) }
                }
                if rule.category == .text || (rule.category == .audio && rule.action?.cleanup != false) {
                    SettingsSection(title: rule.category == .audio ? "Cleanup instructions" : "Instructions") {
                        TextEditor(text: $rule.instructions).font(.system(size: 12)).scrollContentBackground(.hidden).frame(height: 105)
                    }
                }
                if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            }.padding(.horizontal, 20).padding(.bottom, 12)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    do { try model.saveRule(rule); dismiss() } catch { issue = error.localizedDescription }
                }.buttonStyle(FrogButtonStyle(primary: true)).keyboardShortcut(.defaultAction).disabled(rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(20).background(FrogStyle.surface)
                .overlay(alignment: .top) { Rectangle().fill(FrogStyle.border).frame(height: 1) }
        }.frame(width: 540, height: rule.category == .application ? 350 : rule.category == .audio ? 600 : 470)
            .background(FrogStyle.canvas).background(FrogWindowMaterial()).tint(FrogStyle.accent)
            .buttonStyle(FrogButtonStyle()).toggleStyle(.switch).controlSize(.small)
    }
    private var modelMenu: some View {
        CompactMenu(value: selectedModel) {
            Button(L10n.text("Default") + " · " + defaultModel) { rule.providerID = nil; rule.model = ""; rule.action?.localTextModelID = nil }
            Section("Downloaded") {
                ForEach(LocalModelDescriptor.catalog.filter { $0.kind == .text && model.localModels.installed.contains($0.id) }) { item in
                    Button(item.name) {
                        if rule.action == nil { rule.action = RuleAction() }
                        rule.action?.localTextModelID = item.id; rule.providerID = nil; rule.model = ""
                    }
                }
            }
            ForEach(model.configuration.providers) { provider in
                Section(provider.name) {
                    ForEach(provider.models) { choice in Button(choice.name) { rule.providerID = provider.id; rule.model = choice.id; rule.action?.localTextModelID = nil } }
                }
            }
        }
    }
    private var audioOptions: some View {
        Group {
            CompactRow(title: "Speech model") {
                CompactMenu(value: rule.action?.audioModelID.map(model.localModelLabel) ?? L10n.text("Default") + " · " + model.localModelLabel(prefs.audioModelID)) {
                    Button(L10n.text("Default") + " · " + model.localModelLabel(prefs.audioModelID)) { rule.action?.audioModelID = nil }
                    ForEach(LocalModelDescriptor.catalog.filter { $0.kind == .audio && model.localModels.installed.contains($0.id) }) { item in
                        Button(item.name) { rule.action?.audioModelID = item.id }
                    }
                }
            }
            CompactRow(title: "Recording") {
                CompactMenu(value: rule.action?.recordingMode.map { L10n.text($0.title) } ?? L10n.text("Default") + " · " + L10n.text(prefs.recordingMode.title)) {
                    Button(L10n.text("Default") + " · " + L10n.text(prefs.recordingMode.title)) { rule.action?.recordingMode = nil }
                    ForEach(RecordingMode.allCases, id: \.self) { mode in Button(L10n.text(mode.title)) { rule.action?.recordingMode = mode } }
                }
            }
            CompactRow(title: "Output") {
                CompactMenu(value: rule.action?.output.map { L10n.text($0.title) } ?? L10n.text("Default") + " · " + L10n.text(prefs.output.title)) {
                    Button(L10n.text("Default") + " · " + L10n.text(prefs.output.title)) { rule.action?.output = nil }
                    ForEach(TranscriptOutput.allCases, id: \.self) { output in Button(L10n.text(output.title)) { rule.action?.output = output } }
                }
            }
            CompactRow(title: "Improve transcript", detail: "Fix wording and punctuation with a text model.") {
                Toggle("Improve transcript", isOn: Binding(get: { rule.action?.cleanup ?? true }, set: { rule.action?.cleanup = $0 })).labelsHidden().toggleStyle(.switch)
            }
        }
    }
    private func chooseApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        rule.action?.applicationPath = url.path; rule.action?.applicationBundleID = id
        if rule.name == "Custom rule" { rule.name = "Open " + url.deletingPathExtension().lastPathComponent }
    }
}
