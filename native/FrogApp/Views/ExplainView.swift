import AppKit
import SwiftUI
import FrogCore

/// Answer rules and how answers behave.
struct ExplainView: View {
    @EnvironmentObject private var model: AppModel
    @State private var notesFile = ""
    @State private var notesFileIssue: String?
    @FocusState private var editingFile: Bool

    private var settings: ExplainSettings { model.configuration.preferences.explainSettings }

    var body: some View {
        RulesView(fixedCategory: .text, output: .panel) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsSection(title: "Settings") {
                    CompactRow(title: "Include surrounding text",
                               detail: "Sends the sentence or paragraph around the selection, up to 1,000 characters, so the answer fits the context.") {
                        Toggle("Include surrounding text", isOn: Binding(get: { settings.includeContext }, set: { value in
                            update { $0.includeContext = value }
                        })).labelsHidden().toggleStyle(.switch)
                    }
                    Divider()
                    CompactRow(title: "Save answers to notes",
                               detail: "Adds Save to note to the answer panel and to answers in History. Notes are Markdown files in a folder you choose, such as an Obsidian vault.") {
                        Toggle("Save answers to notes", isOn: Binding(get: { settings.notes }, set: { value in
                            update { $0.notes = value }
                        })).labelsHidden().toggleStyle(.switch)
                    }
                }
                if settings.notes { notesSection }
                bubbleSection
            }
        }
    }

    private var notesSection: some View {
        SettingsSection(title: "Notes") {
            CompactRow(title: "Folder", detail: settings.notesFolder ?? "No folder chosen") {
                Button("Choose…") {
                    Task {
                        do { try await model.chooseAnswerNotesFolder() } catch { model.report(error) }
                    }
                }
            }
            Divider()
            CompactRow(title: "Save as") {
                CompactSegments(values: ExplainSettings.NotesMode.allCases, selected: settings.notesMode, width: 260,
                                title: { $0 == .perAnswer ? "One note per answer" : "Add to one note" }) { mode in
                    update { $0.notesMode = mode }
                }
            }
            if settings.notesMode == .append {
                Divider()
                CompactRow(title: "File", detail: notesFileIssue ?? "Inside the notes folder. YYYY, MM and DD become today's date.") {
                    TextField("Daily/YYYY-MM-DD.md", text: $notesFile)
                        .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced))
                        .frame(width: 200).padding(6)
                        .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 5))
                        .focused($editingFile)
                        .onSubmit(saveNotesFile)
                        .onChange(of: editingFile) { _, editing in if !editing { saveNotesFile() } }
                        .onAppear { notesFile = settings.notesFile }
                        .onChange(of: settings.notesFile) { _, value in notesFile = value }
                        .accessibilityLabel("Notes file")
                }
            }
            Divider()
            CompactRow(title: "Open the note after saving",
                       detail: "In Obsidian when the folder is inside a vault, otherwise in your Markdown app.") {
                Toggle("Open the note after saving", isOn: Binding(get: { settings.notesOpen }, set: { value in
                    update { $0.notesOpen = value }
                })).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    // MARK: Selection bubble

    private var bubbleSection: some View {
        SettingsSection(title: "Selection bubble") {
            CompactRow(title: "Show a bubble when you select text",
                       detail: "After you select text in another app, a small bubble offers Explain and your other answer rules, and in text fields your Writing rules. Frog reads the selection through Accessibility and never copies it; Explain's shortcut works without the bubble.") {
                Toggle("Show a bubble when you select text", isOn: Binding(get: { settings.selectionBubble }, set: { value in
                    update { $0.selectionBubble = value }
                })).labelsHidden().toggleStyle(.switch)
            }
            if let status = SelectionBubblePolicy.status(explainEnabled: model.configuration.preferences.featureEnabled(.explain),
                                                         bubbleEnabled: settings.selectionBubble,
                                                         accessibilityTrusted: model.accessibilityGranted) {
                HStack(spacing: 10) {
                    Text(L10n.text(status)).font(FrogType.caption)
                        .foregroundStyle(model.accessibilityGranted ? FrogStyle.muted : FrogStyle.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if !model.accessibilityGranted {
                        Button("Open System Settings") {
                            SelectionService.requestAccess(); SelectionService.openAccessibilitySettings()
                        }.controlSize(.small)
                    }
                }
            }
            if settings.selectionBubble {
                bubbleRules
                Divider()
                CompactRow(title: "Chrome and Electron apps",
                           detail: "Chrome, Arc, Helium, Slack and similar apps hide their text from Accessibility until an app asks. Frog asks each once, so the bubble appears there too; they use a little more memory afterwards. VS Code, Cursor and other editors built on VS Code are never asked, because they would switch to their screen reader mode.") {
                    Toggle("Chrome and Electron apps", isOn: Binding(get: { settings.bubbleExposeText }, set: { value in
                        update { $0.bubbleExposeText = value }
                    })).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                CompactRow(title: "Double-click selects", detail: "Also show after a double- or triple-click.") {
                    Toggle("Double-click selects", isOn: Binding(get: { settings.bubbleDoubleClick }, set: { value in
                        update { $0.bubbleDoubleClick = value }
                    })).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                CompactRow(title: "Keyboard selections", detail: "Also show after selecting with Shift and the arrow keys.") {
                    Toggle("Keyboard selections", isOn: Binding(get: { settings.bubbleKeyboard }, set: { value in
                        update { $0.bubbleKeyboard = value }
                    })).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                CompactRow(title: "Longest selection", detail: "Longer selections show no bubble.") {
                    CompactMenu(value: characters(settings.bubbleMaxCharacters), width: 150) {
                        ForEach(Self.characterChoices(including: settings.bubbleMaxCharacters), id: \.self) { count in
                            Button(characters(count)) { update { $0.bubbleMaxCharacters = count } }
                                .accessibilityAddTraits(count == settings.bubbleMaxCharacters ? .isSelected : [])
                        }
                    }
                }
                Divider()
                CompactRow(title: "Never show in", detail: "The bubble never appears in these apps.") {
                    Menu {
                        Button("Choose an App…", action: chooseExcludedApp)
                        let running = runningApps
                        if !running.isEmpty {
                            Divider()
                            ForEach(running, id: \.id) { app in
                                Button(app.name) { addExcludedApp(app.id) }
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(L10n.text("Add an app")).accessibilityLabel(L10n.text("Add an app"))
                }
                ForEach(settings.bubbleExcludedApps, id: \.self) { id in
                    HStack(spacing: 8) {
                        Image(nsImage: Self.icon(id)).resizable().frame(width: 18, height: 18).accessibilityHidden(true)
                        Text(Self.name(id)).font(.system(size: 12))
                        Text(id).font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        IconAction(title: "Remove \(Self.name(id))", symbol: "minus.circle") {
                            update { $0.bubbleExcludedApps.removeAll { $0 == id } }
                        }
                    }.padding(.leading, 4)
                }
            }
        }
    }

    /// The rules the bubble can offer, each with a switch; the first four show in the bar, the rest under More.
    @ViewBuilder private var bubbleRules: some View {
        let preferences = model.configuration.preferences
        let rules = SelectionBubbleItems.candidates(rules: model.configuration.rules, explainEnabled: preferences.featureEnabled(.explain),
                                                    writingEnabled: preferences.featureEnabled(.writing))
        let hidden = Set(settings.bubbleHiddenRules)
        Divider()
        CompactRow(title: "Rules in the bubble",
                   detail: "Answer rules show everywhere, Writing rules only in text fields, in this order. Past four, the rest open from the arrow at the end.") {
            EmptyView()
        }
        ForEach(rules) { rule in
            HStack(spacing: 8) {
                Image(systemName: rule.answersInPanel ? SelectionBubbleItems.answerSymbol : SelectionBubbleItems.writingSymbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(rule.answersInPanel ? FrogStyle.accent : FrogStyle.muted)
                    .frame(width: 18).accessibilityHidden(true)
                Text(rule.name).font(.system(size: 12)).lineLimit(1)
                Text(L10n.text(rule.answersInPanel ? "Answer" : "Replace selection")).font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                Spacer(minLength: 8)
                if let hotkey = rule.hotkey {
                    Text(HotkeyManager.display(hotkey)).font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                }
                Toggle(rule.name, isOn: Binding(get: { !hidden.contains(rule.id) }, set: { shown in
                    update { settings in
                        settings.bubbleHiddenRules.removeAll { $0 == rule.id }
                        if !shown { settings.bubbleHiddenRules.append(rule.id) }
                    }
                })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }.padding(.leading, 4)
        }
        if rules.isEmpty {
            Text(L10n.text("Turn on a rule on this page or in Writing to offer it in the bubble.")).font(FrogType.caption)
                .foregroundStyle(FrogStyle.muted).padding(.leading, 4)
        }
    }

    private func characters(_ count: Int) -> String {
        "\(count.formatted(.number.locale(L10n.locale))) " + L10n.text("characters")
    }

    static func characterChoices(including current: Int) -> [Int] {
        Set([500, 1_000, 2_000, 4_000, 8_000, 12_000, 20_000, current]).sorted()
    }

    /// Regular apps that are running now, apart from Frog and those already left out.
    private var runningApps: [(id: String, name: String)] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set(settings.bubbleExcludedApps)
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
        guard !settings.bubbleExcludedApps.contains(id) else { return }
        update { $0.bubbleExcludedApps = ($0.bubbleExcludedApps + [id]).sorted() }
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

    private static func icon(_ id: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: .application)
    }

    /// Keeps a valid path; an invalid one stays in the field with the reason below it.
    private func saveNotesFile() {
        let value = notesFile.trimmingCharacters(in: .whitespaces)
        guard value != settings.notesFile else { notesFileIssue = nil; return }
        do {
            _ = try AnswerNote.expand(pattern: value, date: Date(), calendar: .current)
            notesFileIssue = nil
            update { $0.notesFile = value }
        } catch {
            notesFileIssue = error.localizedDescription
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
