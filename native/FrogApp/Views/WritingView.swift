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
            FrogPageHeader(title: "Writing") {
                Button("New rule", systemImage: "plus") {
                    editing = model.configuration.newRule(category: .text, installed: model.localModels.installed)
                }.buttonStyle(.frog(.primary)).keyboardShortcut("n", modifiers: .command)
            }
            rules
            WritingBubbleSection(plugin: plugin)
        }
        .sheet(item: $editing) { rule in
            WritingRuleEditor(rule: rule, bubble: plugin.settings.bubble.on) { copy in editing = copy }.environmentObject(model)
        }
        .sheet(item: $trying) { rule in WritingTryView(rule: rule).environmentObject(model) }
        .onChange(of: model.ruleEditRequest, initial: true) { _, id in openRequested(id) }
    }

    @ViewBuilder private var rules: some View {
        let rules = plugin.rules
        if rules.isEmpty {
            FrogEmptyState(symbol: "text.cursor", title: "No rules yet", message: "A rule rewrites selected text in any app.")
        } else {
            FrogSection("Rules") {
                ForEach(rules) { rule in row(rule) }
            }
        }
    }

    private func row(_ rule: Rule) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FrogRow(rule.name, caption: caption(rule)) {
                HStack(spacing: 8) {
                    Button("Try") { trying = rule }.buttonStyle(.frog(compact: true))
                        .disabled(!rule.enabled || model.isProcessing).accessibilityLabel("Try \(rule.name)")
                    Toggle("Enable \(rule.name)", isOn: Binding(get: { rule.enabled }, set: { value in
                        var updated = rule; updated.enabled = value
                        do { try model.saveRule(updated) } catch { model.report(error) }
                    })).labelsHidden().toggleStyle(.switch)
                    IconAction(title: "Edit \(rule.name)", symbol: "pencil") { editing = rule }
                }
            }
            if let issue = model.hotkeyErrors[rule.id] { FrogRowNote(text: issue, tone: FrogStyle.warning) }
        }.contentShape(Rectangle()).onTapGesture(count: 2) { editing = rule }
    }

    /// What the rule does, its shortcut and its model, in one line.
    private func caption(_ rule: Rule) -> String {
        var parts = [rule.textOutput.title]
        if let hotkey = rule.hotkey { parts.append(HotkeyManager.display(hotkey)) }
        parts.append(model.ruleModelLabel(rule))
        return parts.joined(separator: " · ")
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
                })).labelsHidden().toggleStyle(.switch)
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
                    toggle("In Chrome and Electron apps", \.chromiumApps)
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

    private func toggle(_ title: String, _ key: WritableKeyPath<WritingConfig.Bubble, Bool>) -> some View {
        FrogRow(title) {
            Toggle(title, isOn: Binding(get: { bubble[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } }))
                .labelsHidden().toggleStyle(.switch)
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
    /// The selection bubble is on, so the rule can choose whether it offers itself there.
    private let bubble: Bool
    private let onSaveCopy: (Rule) -> Void

    init(rule: Rule, bubble: Bool, onSaveCopy: @escaping (Rule) -> Void) {
        var draft = rule
        if !draft.targetLanguage.isEmpty {
            draft.instructions = draft.instructions.replacingOccurrences(of: "{{language}}", with: draft.targetLanguage)
            draft.targetLanguage = ""
        }
        if draft.action == nil { draft.action = RuleAction(category: .text) }
        _rule = State(initialValue: draft)
        self.bubble = bubble
        self.onSaveCopy = onSaveCopy
    }

    private var existing: Bool { model.configuration.rules.contains { $0.id == rule.id } }
    private var named: Bool { !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                TextField("Name your rule", text: $rule.name).textFieldStyle(.plain).font(FrogType.title)
                    .accessibilityLabel("Rule name")
                Toggle("On", isOn: $rule.enabled).toggleStyle(.switch).controlSize(.mini).font(FrogType.small)
            }.padding(20)
            ScrollView {
                VStack(alignment: .leading, spacing: FrogStyle.sectionSpacing) {
                    FrogSection("Instructions") {
                        TextEditor(text: $rule.instructions).font(FrogType.body).scrollContentBackground(.hidden)
                            .frame(height: 90).padding(.vertical, 8).accessibilityLabel("Instructions")
                    }
                    FrogSection("Starts from") {
                        FrogRow("Shortcut") { HotkeyRecorder(hotkey: $rule.hotkey) }
                        if bubble {
                            FrogRow("Selection bubble") { Toggle("Selection bubble", isOn: $rule.showsInBubble).labelsHidden().toggleStyle(.switch) }
                        }
                        FrogRow("Command bar") { Toggle("Command bar", isOn: $rule.showsInCommandBar).labelsHidden().toggleStyle(.switch) }
                    }
                    FrogSection("Then") {
                        FrogRow("Result") {
                            CompactSegments(values: TextOutput.allCases, selected: rule.textOutput, title: { $0.title }) { output in
                                rule.action?.textOutput = output == .replace ? nil : output
                            }
                        }
                        FrogRow("Model") { RuleModelPicker(rule: $rule) }
                    }
                }.padding(.horizontal, 20).padding(.bottom, 16).minimalScrollbars()
            }
            if let issue { InlineIssue(message: issue).padding(.horizontal, 20).padding(.bottom, 10) }
            HStack(spacing: 8) {
                if existing {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = true }.buttonStyle(.frog(.destructive))
                    Button("Save as copy", systemImage: "square.on.square") { saveCopy() }.buttonStyle(.frog(.ghost)).disabled(!named)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do { try model.saveRule(rule); dismiss() } catch { issue = error.localizedDescription }
                }.buttonStyle(.frog(.primary)).keyboardShortcut(.defaultAction).disabled(!named)
            }.padding(.horizontal, 20).padding(.vertical, 16)
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

/// Runs a rule on text typed here, without touching any app or the clipboard.
struct WritingTryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let rule: Rule
    @State private var input = ""
    @State private var result = ""
    @State private var issue: String?
    @State private var run: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FrogPageHeader(title: rule.name, subtitle: model.ruleModelLabel(rule))
            TextEditor(text: $input).font(FrogType.body).scrollContentBackground(.hidden)
                .padding(8).frame(height: 120).frogControlSurface(height: nil)
                .accessibilityLabel("Text to try").disabled(run != nil)
            if let issue { InlineIssue(message: issue) }
            if !result.isEmpty {
                ScrollView { Text(result).font(FrogType.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .padding(8).frogControlSurface(height: nil)
            } else { Spacer(minLength: 0) }
            HStack {
                if run != nil {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { run?.cancel() }
                } else if !result.isEmpty {
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Run", systemImage: "play.fill", action: start).buttonStyle(.frog(.primary))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || run != nil || model.isProcessing)
            }
        }.padding(20).frame(width: 520, height: 460).foregroundStyle(FrogStyle.ink).background(FrogStyle.canvas)
            .background(FrogWindowMaterial()).buttonStyle(FrogButtonStyle()).tint(FrogStyle.accent)
            .onDisappear { run?.cancel() }
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
