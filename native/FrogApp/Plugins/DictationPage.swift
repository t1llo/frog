import SwiftUI
import FrogCore

/// The Dictation page: one section per dictation rule, then the settings every recording shares.
struct DictationPage: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: DictationFeature
    let dictation: DictationController

    private var rules: [Rule] { model.configuration.rules.filter { $0.category == .audio } }
    @State private var pickerRequest = ModelPickerOpenRequest()

    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Dictation", subtitle: "Press a shortcut, speak, and Frog types it.") {
                // Only the page's own action; each rule's Record sits on its card's heading.
                FrogAddButton("Add rule") { add() }
            }
            if let missing = rules.first(where: { $0.enabled && !model.ruleHasModel($0) }) {
                ModelMissingNotice(feature: "Dictation", speech: true) { pickerRequest.open(missing.id) }
            }
            if rules.isEmpty {
                FrogEmptyState(symbol: DictationPlugin.info.symbol, title: "No dictation rules", message: "Add one to choose its shortcut and model.",
                               tint: DictationPlugin.info.tint)
            }
            ForEach(rules) { rule in
                DictationRuleSection(rule: rule, dictation: dictation, feature: feature)
            }
            FrogSection("Recording") {
                MicrophoneRow(dictation: dictation, selection: feature.settings.microphone) { feature.selectMicrophone($0) }
                FrogRow("Mute Mac audio") {
                    Toggle("Mute Mac audio", isOn: Binding(get: { feature.settings.muteAudio },
                                                           set: { value in feature.update { $0.muteAudio = value } })).labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
                }
                FrogRow("Cancel shortcut", caption: "Escape always cancels.") {
                    HotkeyRecorder(hotkey: Binding(get: { feature.settings.cancelShortcut?.hotkey }, set: { value in
                        do { try feature.setCancelShortcut(value) } catch { model.report(error) }
                    }), purpose: .recordingCancel)
                }
            }
        }.toggleStyle(.frogSwitch).controlSize(.small)
        .environment(\.modelPickerOpenRequest, pickerRequest)
    }

    private func add() {
        var rule = model.configuration.newRule(category: .audio, output: .replace, installed: model.localModels.installed)
        let names = Set(rules.map(\.name))
        var number = 1
        rule.name = "Dictation"
        while names.contains(rule.name) { number += 1; rule.name = "Dictation \(number)" }
        do { try model.saveRule(rule) } catch { model.report(error) }
    }
}

/// One dictation rule as a section: Record beside its heading, its switch as the first row, its settings below it and
/// Rename and Delete at its foot.
private struct DictationRuleSection: View {
    @EnvironmentObject private var model: AppModel
    let rule: Rule
    let dictation: DictationController
    let feature: DictationFeature
    @State private var renaming = false

    var body: some View {
        FrogSection(rule.name, accessory: {
            RecordButton(rule: rule, dictation: dictation, feature: feature)
        }) {
            FrogRow("Turned on") {
                Toggle("Enable \(rule.name)", isOn: binding(\.enabled)).labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
            }
            rows
            // Managing the rule itself comes last, as words on the row's trailing edge rather than a menu on the heading.
            HStack(spacing: FrogStyle.space8) {
                Spacer()
                Button("Rename…") { renaming = true }.buttonStyle(.frog(.ghost))
                Button("Delete rule", role: .destructive) {
                    do { try model.deleteRule(id: rule.id) } catch { model.report(error) }
                }.buttonStyle(.frog(.destructiveGhost))
            }.frame(minHeight: FrogStyle.rowHeight)
        }
        .sheet(isPresented: $renaming) {
            RenameSheet(name: rule.name, kind: "dictation rule") { name in save { $0.name = name } }
        }
    }

    /// The rule's settings; a rule that is off keeps them, still changeable, so they are not dimmed.
    @ViewBuilder private var rows: some View {
        FrogRow("Shortcut") { HotkeyRecorder(hotkey: binding(\.hotkey)) }
        if let issue = model.hotkeyErrors[rule.id] { FrogRowNote(text: issue, tone: FrogStyle.warning) }
        // Its own row, so the shortcut's chip is not read as a third segment.
        FrogRow("Hold to talk", caption: "Records only while you hold the shortcut down.") {
            Toggle("Hold to talk", isOn: Binding(get: { rule.action?.recordingMode == .hold },
                                                 set: { hold in save { $0.action?.recordingMode = hold ? .hold : .toggle } })).labelsHidden()
        }
        // The page's notice already says Dictation cannot type yet, so the picker asks without a second mark.
        FrogRow("Speech model") {
            RuleModelPicker(rule: Binding(get: { rule }, set: { save(reconciling: $0) }), speech: true, marksMissing: !rule.enabled)
        }
        FrogRow("Language") {
            FrogDropdown(selected: rule.action?.transcriptionLanguage ?? languages.first ?? "auto", options: languages,
                         searchPrompt: languages.count > 8 ? "Find a language" : nil,
                         title: Self.languageName) { code in save { $0.action?.transcriptionLanguage = code } }
        }
        FrogRow("Clean up") {
            FrogDropdown(selected: cleanup, sections: cleanupSections, searchPrompt: textRules.count > 8 ? "Find a rule" : nil,
                         item: cleanupItem) { choice in save { choice.apply(to: &$0) } }
        }
        FrogRow("Output") {
            CompactSegments(values: TranscriptOutput.allCases, selected: rule.action?.output ?? .copy,
                            title: { $0 == .copy ? "Copy" : "Paste" }) { output in save { $0.action?.output = output } }
        }
        FrogRow("Popup while recording") {
            Toggle("Popup while recording", isOn: Binding(get: { rule.action?.showRecordingPopup ?? true },
                                                           set: { value in save { $0.action?.showRecordingPopup = value } })).labelsHidden()
        }
    }

    // MARK: Saving

    private func binding<Value>(_ path: WritableKeyPath<Rule, Value>) -> Binding<Value> {
        Binding(get: { rule[keyPath: path] }, set: { value in save { $0[keyPath: path] = value } })
    }

    private func save(_ change: (inout Rule) -> Void) {
        var updated = rule
        change(&updated)
        guard updated != rule else { return }
        do { try model.saveRule(updated) } catch { model.report(error) }
    }

    /// A new speech model may know fewer languages; the rule keeps one it can recognise.
    private func save(reconciling updated: Rule) {
        save { $0 = model.configuration.reconcilingModels(in: updated, installed: model.localModels.installed) }
    }

    // MARK: Language

    private var languages: [String] {
        if rule.action?.audioProviderID == nil, let id = rule.action?.audioModelID, let item = model.configuration.localModel(id) {
            if item.englishOnly { return ["en"] }
            if !item.supportsLanguageSelection { return ["auto"] }
        }
        return WorkflowPreferences.speechLanguages
    }

    static func languageName(_ code: String) -> String {
        code == "auto" ? "Detect" : Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    // MARK: Cleanup

    private var textRules: [Rule] { model.configuration.rules.filter { $0.category == .text && !$0.answersInPanel } }

    private var cleanup: CleanupChoice {
        if let id = rule.action?.cleanupRuleID { return .rule(id) }
        return rule.action?.cleanup == true ? .own : .off
    }

    private var cleanupSections: [FrogDropdownSection<CleanupChoice>] {
        // "Own instructions" stays only for a rule that already cleans up that way.
        let first: [CleanupChoice] = cleanup == .own ? [.off, .own] : [.off]
        return [.init(values: first), .init("Writing rules", values: textRules.map { .rule($0.id) })]
    }

    private func cleanupItem(_ choice: CleanupChoice) -> FrogDropdownItem {
        switch choice {
        case .off: FrogDropdownItem("Off")
        case .own: FrogDropdownItem("Own instructions", symbol: "text.alignleft")
        case .rule(let id): FrogDropdownItem(textRules.first { $0.id == id }?.name ?? "Deleted rule", symbol: "text.alignleft")
        }
    }
}

enum CleanupChoice: Hashable {
    case off, own, rule(UUID)

    func apply(to rule: inout Rule) {
        switch self {
        case .off: rule.action?.cleanup = false; rule.action?.cleanupRuleID = nil
        case .own: rule.action?.cleanup = true; rule.action?.cleanupRuleID = nil
        case .rule(let id): rule.action?.cleanup = false; rule.action?.cleanupRuleID = id
        }
    }
}

/// Record, or Stop while this rule records. Its own view, so the recording's timer redraws only this button.
private struct RecordButton: View {
    @EnvironmentObject private var model: AppModel
    let rule: Rule
    @ObservedObject var dictation: DictationController
    let feature: DictationFeature
    var compact = true

    var body: some View {
        let mine = dictation.ruleID == rule.id && dictation.active
        Button(mine ? "Stop" : "Record", systemImage: mine ? "stop.fill" : "mic") { mine ? feature.stop() : feature.start(rule) }
            .buttonStyle(.frog(compact: compact))
            .disabled(mine ? dictation.phase != .recording : !rule.enabled || dictation.active || model.isProcessing)
            .accessibilityLabel(mine ? "Stop recording" : "Record with \(rule.name)")
    }
}

struct RenameSheet: View {
    @State var name: String
    /// What is renamed, in lower case ("dictation rule"), for the title.
    let kind: String
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    private let original: String

    init(name: String, kind: String, save: @escaping (String) -> Void) {
        _name = State(initialValue: name); self.kind = kind; self.save = save; original = name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FrogStyle.space16) {
            // A sheet is its own window, so its header keeps the title.
            // Says what is renamed and what it is called now, since the field below is already edited.
            FrogPageHeader(title: "Rename \(kind)", subtitle: "Now called “\(original)”").environment(\.frogToolbarTitle, false)
            FrogTextField(placeholder: original, text: $name).textFieldStyle(.plain).font(FrogType.body)
                .padding(.horizontal, FrogStyle.space10).frogControlSurface()
                .accessibilityLabel("Name").onSubmit(done)
            FrogSheetButtons(padded: false) {
                FrogCancelButton { dismiss() }
                FrogPrimaryButton("Rename", disabledReason: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter a name first" : nil) { done() }
            }
        }.padding(FrogStyle.sheetPadding).frame(width: 340).foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent)
    }

    private func done() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        save(trimmed); dismiss()
    }
}

/// The microphone dropdown. Reading the microphones asks Core Audio about every device, so the list is read when
/// the row appears and when a device comes or goes, not on every redraw.
struct MicrophoneRow: View {
    @ObservedObject var dictation: DictationController
    let selection: String?
    var deviceChanges: () -> AsyncStream<Void> = AudioDeviceChanges.stream
    let choose: (String?) -> Void

    var body: some View {
        FrogRow("Microphone") {
            FrogDropdown(selected: selection, options: [nil] + dictation.microphones.map { String($0.id) },
                         searchPrompt: dictation.microphones.count > 6 ? "Find a microphone" : nil,
                         title: { id in id.flatMap { id in dictation.microphones.first { String($0.id) == id }?.name } ?? "System default" },
                         symbol: { $0 == nil ? "mic" : "mic.fill" }, choose: choose)
        }
        // Read before the first frame, so the row does not show the default first.
        .onAppear { dictation.refreshMicrophones() }
        .task { for await _ in deviceChanges() { dictation.refreshMicrophones() } }
    }
}
