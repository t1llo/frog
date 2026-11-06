import AppKit
import SwiftUI
import FrogCore

/// The Writing page: your rules, then the selection bubble that offers them.
struct WritingView: View {
    @ObservedObject var plugin: WritingPlugin
    @EnvironmentObject private var model: AppModel
    @State private var editing: Rule?
    @State private var trying: Rule?

    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Writing", subtitle: "Select text in any app and press a rule's shortcut to rewrite it.") {
                // The same add button as Add rule on Dictation.
                FrogAddButton("Add rule") {
                    editing = model.configuration.newRule(category: .text, installed: model.localModels.installed)
                }.keyboardShortcut("n", modifiers: .command)
            }
            rules
            WritingBubbleSection(plugin: plugin)
        }
        .sheet(item: $editing) { rule in
            WritingRuleEditor(rule: rule) { copy in editing = copy }.environmentObject(model)
        }
        .sheet(item: $trying) { rule in WritingTryView(rule: rule).environmentObject(model) }
        .onChange(of: model.ruleEditRequest, initial: true) { _, id in openRequested(id) }
    }

    @ViewBuilder private var rules: some View {
        let rules = plugin.rules
        if rules.isEmpty {
            FrogEmptyState(symbol: WritingPlugin.info.symbol, title: "No rules yet", message: "A rule rewrites selected text in any app.",
                           tint: WritingPlugin.info.tint)
        } else {
            let missing = rules.filter { $0.enabled && !model.ruleHasModel($0) }
            if !missing.isEmpty {
                let choices = model.hasModelChoices(speech: false)
                ProblemNotice(title: missing.count == 1 ? "\(missing[0].name) won't run yet" : "\(missing.count) rules won't run yet",
                              message: choices ? "Choose a text model for \(missing.count == 1 ? "it" : "each")."
                                               : "Download a text model or connect a provider first.") {
                    if choices {
                        Button("Choose model") { editing = missing[0] }.buttonStyle(.frog(.primary))
                    } else {
                        Button("Open Models") { model.toolkit.select(.models) }.buttonStyle(.frog(.primary))
                    }
                }
            }
            FrogSection("Rules") {
                ForEach(rules) { rule in row(rule) }
            }
        }
    }

    private var everyEnabledRuleMissing: Bool {
        let enabled = plugin.rules.filter(\.enabled)
        return !enabled.isEmpty && enabled.allSatisfy { !model.ruleHasModel($0) }
    }

    private func row(_ rule: Rule) -> some View {
        WritingRuleRow(rule: rule, caption: caption(rule), markMissing: rule.enabled && !model.ruleHasModel(rule) && !everyEnabledRuleMissing,
                       canTry: rule.enabled && !model.isProcessing, issue: model.hotkeyErrors[rule.id],
                       edit: { editing = rule }, tryIt: { trying = rule }, setEnabled: { value in
                           var updated = rule; updated.enabled = value
                           do { try model.saveRule(updated) } catch { model.report(error) }
                       })
    }

    /// Its model, and what it does with the result when that is not the usual replacing ("Copy · Llama 3.2"), in one
    /// line; the shortcut is drawn as caps beside the controls. A rule without a model names none: the mark beside its
    /// controls says so once.
    private func caption(_ rule: Rule) -> String? {
        var parts: [String] = []
        if rule.textOutput != .replace { parts.append(rule.textOutput.title) }
        if model.ruleHasModel(rule) { parts.append(model.ruleModelLabel(rule)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Edit rule in the answer panel opens that rule's editor here.
    private func openRequested(_ id: UUID?) {
        guard let id, let rule = plugin.rules.first(where: { $0.id == id }) else { return }
        model.ruleEditRequest = nil
        editing = rule
    }
}

// MARK: Selection bubble

/// The bubble's switch, and when it shows once it is on.
struct WritingBubbleSection: View {
    @ObservedObject var plugin: WritingPlugin
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var bubble: WritingConfig.Bubble { plugin.settings.bubble }

    var body: some View {
        FrogSection("Selection bubble") {
            FrogRow("Show after you select text") {
                Toggle("Show after you select text", isOn: Binding(get: { bubble.on }, set: { value in
                    withAnimation(reduceMotion ? nil : FrogMotion.reveal) { update { $0.on = value } }
                })).labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
            }
            if let status = SelectionBubblePolicy.status(bubbleEnabled: bubble.on, accessibilityTrusted: model.accessibilityGranted) {
                HStack(spacing: 10) {
                    FrogRowNote(text: status, tone: FrogStyle.warning)
                    Button("Open System Settings") {
                        SelectionService.requestAccess(); SelectionService.openAccessibilitySettings()
                    }.buttonStyle(.frog(compact: true))
                }
            }
            if bubble.on {
                Group {
                    toggle("After a double-click", \.doubleClick)
                    toggle("After selecting with the keyboard", \.keyboard)
                    toggle("In Chrome and Electron apps", \.chromiumApps,
                           caption: "Offers the bubble there without reading the text, so it can also show after dragging a tab or a window.")
                    FrogRow("Longest selection") {
                        FrogDropdown(selected: bubble.maxCharacters, options: Self.characterChoices(including: bubble.maxCharacters),
                                     width: 150, title: Self.characters) { count in update { $0.maxCharacters = count } }
                    }
                    FrogRow("Never show in", caption: excludedCaption) {
                        IconMenu(title: "Change apps", symbol: "plus") {
                            Section("Add") {
                                Button("Choose an App…", action: chooseExcludedApp)
                                ForEach(runningApps, id: \.id) { app in Button(app.name) { addExcludedApp(app.id) } }
                            }
                            if !bubble.excludedApps.isEmpty {
                                Section("Remove") {
                                    ForEach(bubble.excludedApps, id: \.self) { id in
                                        Button(Self.name(id)) { update { $0.excludedApps.removeAll { $0 == id } } }
                                    }
                                }
                            }
                        }
                    }
                }.transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
    }

    /// The left-out apps by name, a few of them and how many more.
    private var excludedCaption: String {
        let names = bubble.excludedApps.map(Self.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard !names.isEmpty else { return "No apps" }
        return names.count <= 3 ? names.formatted(.list(type: .and)) : names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more"
    }

    private func toggle(_ title: String, _ key: WritableKeyPath<WritingConfig.Bubble, Bool>, caption: String? = nil) -> some View {
        FrogRow(title, caption: caption) {
            Toggle(title, isOn: Binding(get: { bubble[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } }))
                .labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
        }
    }

    private func update(_ change: (inout WritingConfig.Bubble) -> Void) {
        var settings = plugin.settings
        change(&settings.bubble)
        do { try plugin.save(settings) } catch { model.report(error) }
    }

    static func characters(_ count: Int) -> String {
        "\(count.formatted(.number.locale(L10n.locale))) " + L10n.text("characters")
    }

    static func characterChoices(including current: Int) -> [Int] {
        Set([500, 1_000, 2_000, 4_000, 8_000, 12_000, 20_000, current]).sorted()
    }

    /// Regular apps running now, apart from Frog and those already left out.
    private var runningApps: [(id: String, name: String)] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set(bubble.excludedApps)
        return NSWorkspace.shared.runningApplications.compactMap { app -> (id: String, name: String)? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != own, seen.insert(id).inserted else { return nil }
            return (id, app.localizedName ?? id)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func chooseExcludedApp() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let id = Bundle(url: url)?.bundleIdentifier else {
            model.report(FrogError.message("That app has no bundle identifier.")); return
        }
        addExcludedApp(id)
    }

    private func addExcludedApp(_ id: String) {
        guard !bubble.excludedApps.contains(id) else { return }
        update { $0.excludedApps = ($0.excludedApps + [id]).sorted() }
    }

    private static let knownNames = [
        "com.1password.1password": "1Password", "com.agilebits.onepassword7": "1Password 7",
        "com.bitwarden.desktop": "Bitwarden", "com.apple.keychainaccess": "Keychain Access", "com.apple.Passwords": "Passwords",
    ]

    private static func name(_ id: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return knownNames[id] ?? id
    }

}

// MARK: Rule editor

/// One Writing rule: what it does, what starts it, and where the result goes.
struct WritingRuleEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var rule: Rule
    @State private var issue: String?
    @State private var deleting = false
    /// Set by screenshots; otherwise the bubble's switch as it is now.
    private let bubbleShown: Bool?
    private let onSaveCopy: (Rule) -> Void
    /// The selection bubble is on, so the rule can choose whether it offers itself there. Follows the switch while
    /// the editor is open.
    private var bubble: Bool { bubbleShown ?? model.offersBubbleChoice }

    init(rule: Rule, bubble: Bool? = nil, onSaveCopy: @escaping (Rule) -> Void) {
        var draft = rule
        if !draft.targetLanguage.isEmpty {
            draft.instructions = draft.instructions.replacingOccurrences(of: "{{language}}", with: draft.targetLanguage)
            draft.targetLanguage = ""
        }
        if draft.action == nil { draft.action = RuleAction(category: .text) }
        _rule = State(initialValue: draft)
        self.bubbleShown = bubble
        self.onSaveCopy = onSaveCopy
    }

    private var existing: Bool { model.configuration.rules.contains { $0.id == rule.id } }
    private var named: Bool { !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                FrogTextField(placeholder: "Name your rule", text: $rule.name).textFieldStyle(.plain).font(FrogType.title)
                    .accessibilityLabel("Rule name")
                Toggle("On", isOn: $rule.enabled).toggleStyle(.frogSwitch).controlSize(.small).font(FrogType.small)
            }.padding(FrogStyle.sheetPadding)
            ScrollView {
                VStack(alignment: .leading, spacing: FrogStyle.sectionSpacing) {
                    FrogSection("Instructions") {
                        TextEditor(text: $rule.instructions).font(FrogType.body).scrollContentBackground(.hidden)
                            .frame(height: 90).padding(.vertical, 8).accessibilityLabel("Instructions")
                    }
                    FrogSection("Starts from") {
                        FrogRow("Shortcut") { HotkeyRecorder(hotkey: $rule.hotkey) }
                        if bubble {
                            FrogRow("Selection bubble") { Toggle("Selection bubble", isOn: $rule.showsInBubble).labelsHidden().toggleStyle(.frogSwitch).controlSize(.small) }
                        }
                        FrogRow("Command bar") { Toggle("Command bar", isOn: $rule.showsInCommandBar).labelsHidden().toggleStyle(.frogSwitch).controlSize(.small) }
                    }
                    FrogSection("Then") {
                        FrogRow("Result") {
                            CompactSegments(values: TextOutput.allCases, selected: rule.textOutput, title: { $0.title }) { output in
                                rule.action?.textOutput = output == .replace ? nil : output
                            }
                        }
                        FrogRow("Model") { RuleModelPicker(rule: $rule) }
                    }
                }.padding(.horizontal, FrogStyle.sheetPadding).padding(.bottom, FrogStyle.space16).minimalScrollbars()
            }
            if let issue { InlineIssue(message: issue).padding(.horizontal, FrogStyle.sheetPadding).padding(.bottom, FrogStyle.space10) }
            FrogSheetButtons {
                if existing {
                    // Two pills like Cancel and Save beside them, words only: the colour alone says which one removes.
                    Button("Delete", role: .destructive) { deleting = true }.buttonStyle(.frog(.destructive))
                    Button("Save as copy") { saveCopy() }.buttonStyle(.frog()).frogDisabled(named ? nil : "Name the rule first")
                }
            } trailing: {
                FrogCancelButton { dismiss() }
                FrogPrimaryButton("Save", disabledReason: named ? nil : "Name the rule first") {
                    do { try model.saveRule(rule); dismiss() } catch { issue = error.localizedDescription }
                }
            }
        }.frame(width: 540, height: 610)
            .foregroundStyle(FrogStyle.ink).background(FrogStyle.canvas).background(FrogWindowMaterial())
            .tint(FrogStyle.accent).buttonStyle(FrogButtonStyle()).controlSize(.small)
            .onChange(of: model.configuration, initial: true) { reconcileModels() }
            .onChange(of: model.localModels.installed) { reconcileModels() }
            .confirmationDialog("Delete this rule?", isPresented: $deleting) {
                Button("Delete rule", role: .destructive) {
                    do { try model.deleteRule(id: rule.id); dismiss() } catch { issue = error.localizedDescription }
                }
            }
    }

    /// Saves the draft as a new rule without a shortcut; the original stays as it was saved.
    private func saveCopy() {
        let copy = rule.copy()
        do { try model.saveRule(copy); onSaveCopy(copy) } catch { issue = error.localizedDescription }
    }

    private func reconcileModels() {
        let updated = model.configuration.reconcilingModels(in: rule, installed: model.localModels.installed)
        if updated != rule { rule = updated }
    }
}

// MARK: Try

/// Runs a rule on text typed here, without touching any app or the clipboard. The rule's model can be chosen here;
/// that choice is saved to the rule, since the rule runs as saved.
struct WritingTryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var rule: Rule
    @State private var input = ""
    @State private var result = ""
    @State private var issue: String?
    @State private var run: Task<Void, Never>?

    init(rule: Rule) { _rule = State(initialValue: rule) }

    private var hasModel: Bool { (try? model.resolved(rule)) != nil }
    private var hasText: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Why Run is not available, or nil when it is.
    private var runBlocked: String? {
        if run != nil { return "Running…" }
        if model.isProcessing { return "Frog is finishing another rule" }
        if !hasModel { return "Choose a model for this rule first" }
        if !hasText { return "Type or paste some text first" }
        return nil
    }
    /// Why Run waits, said beside it rather than left to a greyed button.
    private var waiting: String? {
        if run != nil || !hasModel { return nil }
        if !hasText { return "Type some text first" }
        if model.isProcessing { return "Frog is busy with another rule" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FrogStyle.space16) {
            // A sheet is its own window, so its header keeps the title.
            FrogPageHeader(title: "Try \(rule.name)") {
                RuleModelPicker(rule: Binding(get: { rule }, set: { choose($0) }))
            }.environment(\.frogToolbarTitle, false)
            // Both boxes are the same card surface with their text on the same inset, under the shared heading.
            VStack(alignment: .leading, spacing: FrogStyle.space8) {
                FrogSectionHeader("Text")
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $input).font(FrogType.body).scrollContentBackground(.hidden)
                        .accessibilityLabel("Text to try").disabled(run != nil)
                    if input.isEmpty {
                        // The editor sets its text 5 in from its edge; the placeholder starts there too.
                        Text("Type or paste text to try the rule on").font(FrogType.body).foregroundStyle(FrogStyle.placeholder)
                            .padding(.leading, 5).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .padding(.leading, FrogStyle.rowInset - 5).padding(.trailing, FrogStyle.space4).padding(.vertical, FrogStyle.space10)
                .frame(height: 120).frogTableSurface()
            }
            VStack(alignment: .leading, spacing: FrogStyle.space8) {
                FrogSectionHeader("Result") {
                    if !result.isEmpty {
                        CopyAction { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string) }
                    }
                }
                Group {
                    if let issue {
                        InlineIssue(message: issue).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else if run != nil {
                        FrogLoadingNote(text: "Running…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else if result.isEmpty {
                        Text("The result shows here. Nothing is pasted or copied.").font(FrogType.body)
                            .foregroundStyle(FrogStyle.placeholder)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        ScrollView {
                            Text(result).font(FrogType.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, FrogStyle.rowInset).padding(.vertical, FrogStyle.space10)
                .frame(height: 120).frogTableSurface()
            }
            FrogSheetButtons(padded: false) {
                // A missing model is marked once, on the model menu above, not again here.
                if let waiting {
                    Text(L10n.text(waiting)).font(FrogType.body).foregroundStyle(FrogStyle.muted)
                }
            } trailing: {
                if run != nil {
                    // Escape stops the run first; once it has stopped, Escape closes the sheet.
                    FrogCancelButton("Stop") { run?.cancel() }
                } else {
                    FrogCancelButton("Done") { dismiss() }
                }
                Button("Run", systemImage: "play.fill", action: start).buttonStyle(.frog(.primary))
                    .keyboardShortcut(.return, modifiers: .command)
                    // frogDisabled's tooltip, with the shortcut while it can run.
                    .disabled(runBlocked != nil)
                    .help(runBlocked.map { L10n.text($0) } ?? "Run (⌘↩)")
                    .accessibilityHint(runBlocked.map { L10n.text($0) } ?? "")
            }
        }.padding(FrogStyle.sheetPadding).frame(width: 540).foregroundStyle(FrogStyle.ink).background(FrogStyle.canvas)
            .background(FrogWindowMaterial()).buttonStyle(FrogButtonStyle()).tint(FrogStyle.accent)
            .onDisappear { run?.cancel() }
    }

    /// A model picked here is saved to the rule, which runs as it is saved.
    private func choose(_ updated: Rule) {
        rule = updated
        do { try model.saveRule(updated) } catch { issue = error.localizedDescription }
    }

    private func start() {
        issue = nil; result = ""
        let text = input, rule = rule
        run = Task {
            do {
                result = rule.answersInPanel ? try await model.answer(text, rule: rule) : try await model.runRule(rule.id, on: text).result
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
            run = nil
        }
    }
}

/// One rule: its tile, name and model, its shortcut and its switch. Clicking the row opens its editor; Try and Edit
/// appear where the pointer is, so a list of rules reads as names and shortcuts rather than a column of buttons.
private struct WritingRuleRow: View {
    let rule: Rule
    let caption: String?
    let markMissing: Bool
    let canTry: Bool
    let issue: String?
    let edit: () -> Void
    let tryIt: () -> Void
    let setEnabled: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FrogRow(rule.name, caption: caption, icon: {
                // The tile the rule wears in the selection bubble and the command bar: Writing's, or Explain's for a
                // rule that answers in the panel.
                PluginIconTile(symbol: SelectionBubbleItems.symbol(for: rule),
                               tint: (rule.answersInPanel ? ExplainPlugin.info.tint : WritingPlugin.info.tint).color, size: .list)
            }) {
                HStack(spacing: 8) {
                    // Hover actions lead, so the caps and the switch keep their place whether or not they show.
                    HStack(spacing: 4) {
                        Button("Try") { tryIt() }.buttonStyle(.frog(compact: true))
                            .disabled(!canTry).accessibilityLabel("Try \(rule.name)")
                        IconAction(title: "Edit \(rule.name)", symbol: "pencil") { edit() }
                    }.opacity(hovering ? 1 : 0).animation(hovering ? nil : FrogMotion.hoverOut, value: hovering)
                    // The notice above names the problem; a row is marked only to single out which rules it means.
                    if markMissing {
                        Button { edit() } label: { ProblemMark(help: "No model chosen: click to choose one") }
                            .buttonStyle(.plain)
                    }
                    if let hotkey = rule.hotkey { KeyCaps(hotkey: hotkey) }
                    Toggle("Enable \(rule.name)", isOn: Binding(get: { rule.enabled }, set: setEnabled))
                        .labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
                }
            }
            if let issue { FrogRowNote(text: issue, tone: FrogStyle.warning) }
        }
        .padding(.horizontal, FrogStyle.space8)
        .contentShape(Rectangle())
        .frogRowHighlight(hovering: hovering)
        .padding(.horizontal, -FrogStyle.space8)
        .onHover { hovering = $0 }
        .onTapGesture { edit() }
        .contextMenu {
            Button("Edit…", systemImage: "pencil") { edit() }
            Button("Try…", systemImage: "play") { tryIt() }.disabled(!canTry)
        }
        .accessibilityAction(named: Text("Edit")) { edit() }
        .accessibilityAction(named: Text("Try")) { if canTry { tryIt() } }
    }
}
