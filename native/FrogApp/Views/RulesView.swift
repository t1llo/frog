import SwiftUI
import FrogCore
import AppKit
import UniformTypeIdentifiers

struct RulesView: View {
    @EnvironmentObject private var model: AppModel
    var applications = false
    @State private var editing: Rule?
    @State private var filter: RuleCategory = .text
    @State private var search = ""
    private var category: RuleCategory { applications ? .application : filter }
    private var rules: [Rule] {
        model.configuration.rules.filter { $0.category == category && (search.isEmpty || ($0.name + " " + $0.instructions).localizedStandardContains(search)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: applications ? "Shortcuts" : "Rules", subtitle: "") {
                Button(applications ? "Add application" : "New rule", systemImage: "plus") {
                    editing = model.configuration.newRule(category: category, installed: model.localModels.installed)
                }.keyboardShortcut("n", modifiers: .command)
            }
            if applications {
                SettingsSection(title: "Window switcher") {
                    CompactRow(title: "Switch windows with ⌘Tab", detail: "Hold ⌘ and type to search. Release to switch; Esc cancels.") {
                        Toggle("Window switcher", isOn: Binding(get: { model.configuration.preferences.windowSwitcherEnabled }, set: { value in
                            var prefs = model.configuration.preferences; prefs.windowSwitcherEnabled = value
                            do { try model.savePreferences(prefs) } catch { model.report(error) }
                        })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    Text(model.windowSwitcherStatus).font(.caption).foregroundStyle(FrogStyle.muted)
                }
            }
            ListToolbar(placeholder: applications ? "Search applications" : "Search rules", search: $search) {
                if !applications { ForEach([RuleCategory.text, .audio]) { category in FilterTag(title: category.title, selected: filter == category) { filter = category } } }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rules) { rule in
                        HStack(spacing: 10) {
                            if applications { Image(nsImage: NSWorkspace.shared.icon(forFile: rule.action?.applicationPath ?? "")).resizable().frame(width: 28, height: 28) }
                            Button { editing = rule } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(rule.name).font(.system(size: 12, weight: .medium))
                                    Text(model.ruleModelLabel(rule)).font(.system(size: 10)).foregroundStyle(FrogStyle.muted).lineLimit(1)
                                    if let issue = model.hotkeyErrors[rule.id] { Text(issue).font(.caption2).foregroundStyle(.orange) }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Toggle("Enable \(rule.name)", isOn: Binding(get: { rule.enabled }, set: { value in
                                var updated = rule; updated.enabled = value
                                do { try model.saveRule(updated) } catch { model.report(error) }
                            })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            HotkeyRecorder(hotkey: Binding(get: { rule.hotkey }, set: { value in
                                var updated = rule; updated.hotkey = value
                                do { try model.saveRule(updated) } catch { model.report(error) }
                            }), showsClearButton: false)
                            IconAction(title: "Edit rule", symbol: "pencil", bordered: true) { editing = rule }
                        }.padding(12)
                        if rule.id != rules.last?.id { Divider().opacity(0.5) }
                    }
                    if rules.isEmpty { Text("No matching rules").font(.caption).foregroundStyle(FrogStyle.muted).padding(24) }
                }
            }.frogTableSurface()
        }.padding(20).sheet(item: $editing) { RuleEditor(rule: $0).environmentObject(model) }
    }
}

@MainActor
extension AppModel {
    func localModelLabel(_ id: String) -> String {
        (configuration.localModel(id)?.name ?? id) + (localModels.installed.contains(id) ? "" : " · Not downloaded")
    }
    var defaultTextLabel: String { "Choose a model" }
    func ruleModelLabel(_ rule: Rule) -> String {
        if rule.category == .application { return rule.action?.applicationPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Choose application" }
        if rule.category == .audio {
            guard let id = rule.action?.audioModelID else { return "Choose a speech model" }
            if let provider = configuration.providers.first(where: { $0.id == rule.action?.audioProviderID }) { return provider.name + " · " + provider.modelName(id) }
            return localModelLabel(id)
        }
        guard let provider = try? resolved(rule) else { return "Choose a text model" }
        return provider.id == Self.localProviderID ? localModelLabel(provider.model) : provider.name + " · " + provider.modelName(provider.model)
    }
}

struct RuleEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var rule: Rule
    @State private var issue: String?
    @State private var deleting = false
    @State private var step = 0
    init(rule: Rule) {
        var draft = rule
        if !draft.targetLanguage.isEmpty { draft.instructions = draft.instructions.replacingOccurrences(of: "{{language}}", with: draft.targetLanguage); draft.targetLanguage = "" }
        if draft.action == nil { draft.action = RuleAction(category: draft.category) }
        _rule = State(initialValue: draft)
    }
    private var existing: Bool { model.configuration.rules.contains { $0.id == rule.id } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(rule.category == .application ? "Application shortcut" : rule.category == .audio ? "Audio rule" : "Text rule").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                    TextField("Name your rule", text: $rule.name).textFieldStyle(.plain).font(.system(size: 23, weight: .semibold)).accessibilityLabel("Rule name")
                }
                Toggle("Enabled", isOn: $rule.enabled).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
            }.padding(24)
            if rule.category == .audio {
                CompactSegments(values: [0, 1], selected: step, title: { $0 == 0 ? "Recording" : "Cleanup" }) { step = $0 }.padding(.bottom, 16)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if rule.category == .audio && step == 1 {
                        CompactRow(title: "Improve transcript", detail: "A text model cleans up the transcript. Adds processing time.") {
                            Toggle("Improve transcript", isOn: Binding(get: { rule.action?.cleanup ?? false }, set: { rule.action?.cleanup = $0 })).labelsHidden().toggleStyle(.switch)
                        }
                        if rule.action?.cleanup == true {
                            CompactRow(title: "Cleanup model") { RuleModelPicker(rule: $rule) }
                            instructions
                        }
                    } else {
                        VStack(spacing: 10) {
                            if rule.category == .application {
                                CompactRow(title: "Application") { Button(rule.action?.applicationPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Choose application") { chooseApplication() } }
                            } else {
                                CompactRow(title: rule.category == .audio ? "Speech model" : "Text model") { RuleModelPicker(rule: $rule, speech: rule.category == .audio) }
                            }
                            Divider()
                            CompactRow(title: "Shortcut") { HotkeyRecorder(hotkey: $rule.hotkey) }
                            if rule.category == .audio { audioOptions }
                        }.padding(13).frogTableSurface()
                        if rule.category == .text { instructions }
                    }
                    if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
            HStack(spacing: 8) {
                if existing {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = true }.buttonStyle(.plain).foregroundStyle(.red.opacity(0.8))
                    Button("Duplicate", systemImage: "square.on.square") { rule.id = UUID(); rule.name += " copy"; rule.hotkey = nil; rule.preset = false }.buttonStyle(.plain).foregroundStyle(FrogStyle.muted).padding(.leading, 8)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { do { try model.saveRule(rule); dismiss() } catch { issue = error.localizedDescription } }
                    .buttonStyle(FrogButtonStyle(primary: true)).keyboardShortcut(.defaultAction).disabled(rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 15)
                .overlay(alignment: .top) { Rectangle().fill(FrogStyle.border.opacity(0.5)).frame(height: 1) }
        }.frame(width: 544, height: rule.category == .application ? 320 : rule.category == .audio ? 590 : 490)
            .foregroundStyle(FrogStyle.ink).background(FrogStyle.canvas).tint(FrogStyle.accent).buttonStyle(FrogButtonStyle()).controlSize(.small)
            .confirmationDialog("Delete this rule?", isPresented: $deleting) {
                Button("Delete rule", role: .destructive) { do { try model.deleteRule(id: rule.id); dismiss() } catch { issue = error.localizedDescription } }
            }
    }
    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Instructions").font(.system(size: 12, weight: .medium)); Spacer(); if rule.category == .text { Text("Applied to selected text").font(.system(size: 10)).foregroundStyle(FrogStyle.muted) } }
            TextEditor(text: $rule.instructions).font(.system(size: 12)).scrollContentBackground(.hidden).padding(9).frame(height: 145)
                .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(FrogStyle.border.opacity(0.6)))
        }
    }
    private var audioOptions: some View {
        Group {
            Divider()
            CompactRow(title: "Language") {
                CompactMenu(value: languageName(rule.action?.transcriptionLanguage ?? languageChoices.first ?? "auto")) {
                    ForEach(languageChoices, id: \.self) { language in Button(languageName(language)) { rule.action?.transcriptionLanguage = language } }
                }
            }
            Divider()
            CompactRow(title: "Recording") { CompactSegments(values: RecordingMode.allCases, selected: rule.action?.recordingMode ?? .toggle, title: { $0.title }) { rule.action?.recordingMode = $0 } }
            Divider()
            CompactRow(title: "Output") { CompactSegments(values: TranscriptOutput.allCases, selected: rule.action?.output ?? .copy, title: { $0.title }) { rule.action?.output = $0 } }
            Divider()
            CompactRow(title: "Recording popup") { Toggle("Recording popup", isOn: Binding(get: { rule.action?.showRecordingPopup ?? true }, set: { rule.action?.showRecordingPopup = $0 })).labelsHidden().toggleStyle(.switch) }
        }
    }
    private var languageChoices: [String] {
        if rule.action?.audioProviderID == nil, let id = rule.action?.audioModelID, let item = model.configuration.localModel(id) {
            if item.englishOnly { return ["en"] }
            if !item.supportsLanguageSelection { return ["auto"] }
        }
        return WorkflowPreferences.speechLanguages
    }
    private func languageName(_ code: String) -> String { code == "auto" ? "Auto" : Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code }
    private func chooseApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        rule.action?.applicationPath = url.path; rule.action?.applicationBundleID = id
        if rule.name == "Open application" { rule.name = "Open " + url.deletingPathExtension().lastPathComponent }
    }
}
