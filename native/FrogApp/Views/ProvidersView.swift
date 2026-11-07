import SwiftUI
import FrogCore

struct ProvidersView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: ProviderConfiguration?
    /// The editor's first step: a provider added from the list of services opens on its connection.
    @State private var editingStep = 0
    @State private var addingLocal = false
    @State private var revealedModelID: String?
    @State private var deleting: ProviderConfiguration?
    @State private var filter: String?
    @State private var search = ""

    /// `filter` opens the page on one of its sources, for pictures of each.
    init(filter: String? = nil) { _filter = State(initialValue: filter) }

    private var selectedFilter: String { filter ?? (model.localModels.installed.isEmpty ? "Providers" : "Local models") }
    private var providers: [ProviderConfiguration] {
        model.configuration.providers.filter { search.isEmpty || ($0.name + " " + $0.models.map(\.name).joined(separator: " ")).localizedStandardContains(search) }
    }
    private var sourcePicker: some View {
        // "Installed tools" stays the key the page is opened with; the segment calls them coding tools, as their section does.
        CompactSegments(values: ["Local models", "Providers", "Installed tools"], selected: selectedFilter,
                        title: { $0 == "Installed tools" ? "Coding tools" : $0 }) { filter = $0; search = "" }
    }

    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Models", subtitle: subtitle) {
                if selectedFilter == "Local models" {
                    FrogAddButton("Add model") { addingLocal = true }
                } else if selectedFilter == "Providers" {
                    FrogAddButton("Add provider") { editingStep = 0; editing = ProviderConfiguration() }
                        .keyboardShortcut("n", modifiers: .command)
                }
            }
            VStack(alignment: .leading, spacing: FrogStyle.sectionSpacing) {
                // Searching a handful of providers finds nothing a glance would not.
                ListToolbar(placeholder: selectedFilter == "Local models" ? "Search models" : "Search providers", search: $search,
                            showsSearch: selectedFilter == "Local models" || (selectedFilter == "Providers" && model.configuration.providers.count >= 6)) { sourcePicker }
                if selectedFilter == "Installed tools" {
                    LocalToolProvidersView(client: model.localTools) { kind, selectedModel in
                        do { try model.useLocalTool(kind, model: selectedModel); filter = "Providers"; search = "" }
                        catch { model.report(error) }
                    }
                } else if selectedFilter == "Local models" {
                    if !LocalModels.supported {
                        ProblemNotice(title: "Local models need Apple silicon",
                                      message: "This Mac cannot run them. Add a provider instead.") {
                            Button("Add provider") { filter = "Providers"; search = ""; editingStep = 0; editing = ProviderConfiguration() }.buttonStyle(.frog(compact: true))
                        }
                    }
                    // Speech and text models in one list, under their own headings, rather than a second switch.
                    ModelInventory(search: search, revealedModelID: revealedModelID)
                    if search.isEmpty { LocalModelSettingsView() }
                } else {
                    if !providers.isEmpty {
                        // Headed like the lists of the other tabs.
                        VStack(alignment: .leading, spacing: FrogStyle.space8) {
                            FrogSectionHeader("Connected")
                            VStack(spacing: 2) {
                                ForEach(providers) { provider in
                                    ProviderRow(provider: provider, edit: { editingStep = 0; editing = $0 }, delete: { deleting = $0 })
                                }
                            }.padding(FrogStyle.listInset).frogTableSurface()
                        }
                    } else if !search.isEmpty {
                        FrogEmptyState(symbol: "magnifyingglass", title: "No matches", message: "No provider matches this search.")
                            .frogTableSurface()
                    }
                    if search.isEmpty { addableProviders }
                }
            }
        }
        .buttonStyle(.frog())
        .sheet(item: $editing) { provider in ProviderEditor(provider: provider, step: editingStep).environmentObject(model) }
        .sheet(isPresented: $addingLocal) {
            AddLocalModelView { item in revealedModelID = item.id; search = "" }.environmentObject(model)
        }
        .confirmationDialog("Delete \(deleting?.name ?? "provider")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete provider", role: .destructive) {
                guard let provider = deleting else { return }
                do { try model.deleteProvider(id: provider.id) } catch { model.report(error) }
                deleting = nil
            }
        } message: { Text("The saved API key will also be removed. Affected rules will use another compatible model when available.") }
    }

    /// The services Frog can connect to, each added with one click that opens its connection step. Coding tools
    /// are added from their own tab, which checks they are installed.
    private var addableProviders: some View {
        let connected = Set(model.configuration.providers.map(\.kind))
        let kinds = ProviderKind.addable.filter { $0 == .compatible || !connected.contains($0) }
        return FrogSection(connected.isEmpty ? "Connect a provider" : "Add another") {
            ForEach(kinds, id: \.self) { kind in
                FrogRow(kind.shortTitle, caption: kind.pitch, icon: { PluginIconTile(mark: .provider(kind)) }) {
                    Button("Add") {
                        editingStep = 1
                        editing = ProviderConfiguration(name: kind.shortTitle, kind: kind)
                    }.buttonStyle(.frog(compact: true)).accessibilityLabel("Add \(kind.shortTitle)")
                }
            }
        }
    }

    /// A tabbed page keeps one subtitle for the whole page; what one tab needs to say goes in that tab.
    private var subtitle: String { "Models on this Mac, cloud providers and the coding tools you use." }
}

/// One provider in the Providers list: opens its editor, with its actions at the end.
private struct ProviderRow: View {
    let provider: ProviderConfiguration
    let edit: (ProviderConfiguration) -> Void
    let delete: (ProviderConfiguration) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            PluginIconTile(mark: .provider(provider.kind))
            Button { edit(provider) } label: {
                VStack(alignment: .leading, spacing: FrogStyle.space2) {
                    Text(provider.name).font(FrogType.row)
                    Text(Self.caption(provider)).font(FrogType.small).foregroundStyle(FrogStyle.muted)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            // One overflow control: editing is the row's own click and the first item here.
            IconMenu(title: "Provider actions", bordered: false) {
                Button("Edit…", systemImage: "pencil") { edit(provider) }
                Button("Duplicate", systemImage: "plus.square.on.square") { var copy = provider; copy.id = UUID(); copy.name += " copy"; edit(copy) }
                Button("Delete…", systemImage: "trash", role: .destructive) { delete(provider) }
            }
        }.padding(.vertical, 8).padding(.horizontal, FrogStyle.rowPadding).frame(minHeight: FrogStyle.rowHeight)
            .frogRowHighlight(hovering: hovering).onHover { hovering = $0 }
    }

    /// Where it runs and what it offers, without repeating its name: "Local server · 1 text model",
    /// "Cloud API · 3 text models", or the service's name when the provider was given a name of its own.
    static func caption(_ provider: ProviderConfiguration) -> String {
        let text = provider.models.filter { $0.category == .text }.count
        let speech = provider.models.filter { $0.category == .audio }.count
        let service = provider.kind.title.replacingOccurrences(of: " (local)", with: "")
        let named = !provider.name.localizedCaseInsensitiveContains(service)
        let place = provider.kind.isLocal ? "Local server" : provider.kind.localTool != nil ? "Coding tool" : "Cloud API"
        var parts = [named ? service : place]
        if text > 0 { parts.append(text == 1 ? "1 text model" : "\(text) text models") }
        if speech > 0 { parts.append(speech == 1 ? "1 speech model" : "\(speech) speech models") }
        if text == 0, speech == 0 { parts.append("No models yet") }
        return parts.joined(separator: " · ")
    }
}

/// The provider sheet's steps in a row, each a numbered dot and its name: done steps carry a checkmark, the open
/// one is filled with the accent, the ones ahead are muted. A step that can be reached is a button.
private struct ProviderSteps: View {
    let titles: [String]
    let current: Int
    /// The furthest step a click may open.
    let reachable: Int
    let choose: (Int) -> Void

    var body: some View {
        HStack(spacing: FrogStyle.space8) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                if index > 0 {
                    // The track between two steps, filled once the step before it is done.
                    Capsule(style: .continuous).fill(index <= current ? FrogStyle.accent : FrogStyle.track)
                        .frame(width: 20, height: 2).accessibilityHidden(true)
                }
                // The open step stays clickable-looking but does nothing; disabling it would dim the step you are on.
                Button { if index != current { choose(index) } } label: { step(index, title) }
                    .buttonStyle(.plain)
                    .disabled(index > reachable)
                    .accessibilityLabel(String(format: L10n.text("Step %d of %d: %@"), index + 1, titles.count, L10n.text(title)))
                    .accessibilityAddTraits(index == current ? .isSelected : [])
            }
        }
        .frame(minHeight: FrogStyle.compactHeight)
    }

    private func step(_ index: Int, _ title: String) -> some View {
        let done = index < current
        let open = index == current
        return HStack(spacing: FrogStyle.space6) {
            ZStack {
                Circle().fill(open || done ? FrogStyle.accent : FrogStyle.control)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(FrogStyle.onAccent)
                } else {
                    Text("\(index + 1)").font(FrogType.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(open ? FrogStyle.onAccent : FrogStyle.muted)
                }
            }.frame(width: 18, height: 18)
            Text(L10n.text(title)).font(open ? FrogType.bodyMedium : FrogType.small)
                .foregroundStyle(open || done ? FrogStyle.ink : FrogStyle.muted).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

/// A link's title with its arrow after it, as in "Open ↗", like the links of a model's information sheet.
private struct ProviderLinkLabel: View {
    let title: String
    var body: some View {
        HStack(spacing: FrogStyle.space4) {
            Text(L10n.text(title))
            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
        }
    }
}

struct ProviderEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var provider: ProviderConfiguration
    @State private var apiKey = ""
    @State private var clearKey = false
    @State private var issue: String?
    @State private var testResult: String?
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?
    @State private var customModelID = ""
    @State private var customModelName = ""
    @State private var discovered: [ProviderModel] = []
    @State private var discovering = false
    @State private var discoveryTask: Task<Void, Never>?
    @State private var discoveryMessage: String?
    @State private var step: Int
    @State private var customCategory: ProviderModel.Category = .text
    /// Whether the Keychain holds a key for this provider. Each look is a Keychain query, and the editor
    /// draws again for every keystroke and every change in Frog, so it is read when the editor opens.
    @State private var hasSavedKey = false
    /// Whether this provider is already saved; its editor then saves from any step. Read when the editor opens.
    @State private var isSaved = false

    init(provider: ProviderConfiguration, step: Int = 0) {
        _provider = State(initialValue: provider); _step = State(initialValue: step)
    }

    private var validation: String? {
        if provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a provider name." }
        if provider.kind.localTool != nil {
            do { try ConfigurationFile.validate(provider: normalized()); return nil }
            catch { return error.localizedDescription }
        }
        guard let url = URL(string: provider.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), let host = url.host, !host.isEmpty else {
            return "Enter a full HTTP or HTTPS endpoint, including its host."
        }
        if url.user != nil || url.password != nil || url.query != nil || url.fragment != nil { return "Use an endpoint without credentials, query parameters, or a fragment." }
        do { try ConfigurationFile.validate(provider: normalized()) }
        catch { return error.localizedDescription }
        return nil
    }

    private var credentialHint: String? {
        if [.openAI, .anthropic, .gemini].contains(provider.kind), apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           clearKey || !hasSavedKey {
            return "This cloud service needs an API key before it can process text."
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: FrogStyle.space16) {
                // A new provider is "New provider" until a service is chosen; from then on the title is its name, to rename.
                if !isSaved && step == 0 {
                    Text("New provider").font(FrogType.title).tracking(-0.4).frame(minHeight: FrogStyle.controlHeight)
                        .accessibilityAddTraits(.isHeader)
                } else {
                    FrogTextField(placeholder: "Connection name", text: $provider.name).textFieldStyle(.plain).font(FrogType.title).tracking(-0.4)
                        .accessibilityLabel("Connection name").help("Click to rename. Rules and menus show this name.")
                        .frame(minHeight: FrogStyle.controlHeight)
                }
                // Where the sheet is in its three steps, rather than tabs: a saved provider can jump to any step,
                // a new one back to the steps it has done.
                ProviderSteps(titles: Self.stepTitles, current: step, reachable: isSaved ? Self.stepTitles.count - 1 : step) { step = $0 }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(FrogStyle.sheetPadding)
            // As tall as the step, up to a limit: the short steps leave no empty half, the long one scrolls and
            // fades out above the buttons rather than cutting a line in half.
            FrogSheetScroll {
                VStack(alignment: .leading, spacing: 20) {
                    if step == 0 {
                    // The Service step lists every service with its mark, rather than one menu on an empty step.
                    FrogSection(footer: serviceNote) {
                        ForEach(Self.serviceGroups, id: \.title) { group in
                            SectionCaption(text: group.title).padding(.top, FrogStyle.space6)
                            ForEach(group.kinds, id: \.self) { kind in serviceChoice(kind) }
                        }
                    }
                    .onChange(of: provider.kind) { old, new in
                        if provider.name == old.title || provider.name == old.shortTitle || provider.name == "OpenAI" { provider.name = new.shortTitle }
                        provider.endpoint = new.endpoint; provider.model = new.defaultModel
                        provider.models = new.suggestedModels
                        apiKey = ""; clearKey = hasSavedKey
                        discovered = []; discoveryMessage = nil; customModelID = ""; customModelName = ""
                        testResult = nil; issue = nil
                    }
                    .disabled(testing || discovering)
                    if provider.kind.isLocal {
                        FrogSection {
                            FrogRow("Setup guide", caption: "Install \(provider.kind.shortTitle) and download a model.") {
                                Link(destination: provider.kind.setupURL) { ProviderLinkLabel(title: "Open") }
                                    .buttonStyle(.frog(compact: true))
                            }
                        }
                    }
                    }
                    if step == 1 {
                    if let tool = provider.kind.localTool {
                        FrogSection("Sign-in", footer: tool == .opencode ? "OpenCode keeps its own history, whatever Frog's history setting." : nil) {
                            FrogRow("Uses \(tool.title)'s own sign-in", caption: "No endpoint or API key is needed.", icon: {
                                PluginIconTile(mark: .provider(provider.kind))
                            }, control: { EmptyView() })
                            FrogRowNote(text: tool.loginInstructions)
                        }
                    } else {
                    FrogSection("Connection") {
                        LabeledField(title: "Base endpoint") { FrogTextField(placeholder: "Base endpoint", text: $provider.endpoint).labelsHidden() }
                        HStack(alignment: .top, spacing: 16) {
                            Text(endpointHint)
                                .font(FrogType.small).foregroundStyle(FrogStyle.muted).lineSpacing(3)
                            Spacer(minLength: 0)
                            Button("Reset endpoint") {
                                provider.endpoint = provider.kind.endpoint
                            }.buttonStyle(.frog()).fixedSize()
                        }
                    }.disabled(testing || discovering)
                    FrogSection("Credentials") {
                        LabeledField(title: hasSavedKey ? "Replacement API key" : "API key") {
                            SecureField("API key", text: $apiKey).disabled(clearKey)
                        }
                        if !provider.kind.isLocal && provider.kind != .compatible {
                            Link(destination: provider.kind.setupURL) {
                                ProviderLinkLabel(title: provider.kind == .gemini ? "Get an API key in Google AI Studio" : "Get an API key for \(provider.kind.title)")
                            }.buttonStyle(.frog())
                        }
                        if hasSavedKey {
                            FrogRow("Remove saved key", caption: "Leave the field blank to keep the saved key.") {
                                Toggle("Remove saved API key on save", isOn: $clearKey).toggleStyle(.frogSwitch).labelsHidden().controlSize(.small)
                                    .onChange(of: clearKey) { _, remove in if remove { apiKey = "" } }
                            }
                        } else {
                            Label("Kept in the Keychain. Local services need none.", systemImage: "lock.shield")
                                .font(FrogType.small).foregroundStyle(FrogStyle.muted).padding(.vertical, FrogStyle.space8)
                        }
                        if let credentialHint { InlineIssue(message: credentialHint) }
                    }.disabled(testing || discovering)
                    }
                    }
                    if step == 2 {
                    FrogSection("Your models") {
                        modelSettings
                    }.disabled(testing)
                    FrogSection("Take it for a spin") {
                        FrogRow("Connection test", caption: "Sends a short sample request with these settings.") {
                            HStack(spacing: FrogStyle.space8) {
                                if testing { FrogSpinner() }
                                Button(testing ? "Testing…" : "Test connection") { test() }
                                    .disabled(validation != nil || testing || discovering || model.isTestingProvider)
                                if testing { Button("Cancel") { testTask?.cancel() } }
                            }
                        }
                        if let testResult {
                            Label(testResult, systemImage: "checkmark.circle.fill").font(FrogType.small)
                                .foregroundStyle(FrogStyle.good).textSelection(.enabled).padding(.vertical, FrogStyle.space8)
                        }
                        if let issue { InlineIssue(message: issue) }
                    }
                    }
                    if let validation { InlineIssue(message: validation) }
                }.padding(.horizontal, FrogStyle.sheetPadding).padding(.bottom, FrogStyle.space4).minimalScrollbars()
            }
            // A multi-step sheet: Back between Cancel and the main button.
            FrogSheetButtons {
                FrogCancelButton { testTask?.cancel(); discoveryTask?.cancel(); dismiss() }
                if step > 0 { Button("Back") { step -= 1 } }
                FrogPrimaryButton(step < 2 && !isSaved ? "Continue" : "Save",
                                  disabledReason: testing ? "Testing the connection…" : discovering ? "Finding models…"
                                  : (step == 2 || isSaved) ? validation : nil) {
                    if step < 2 && !isSaved { step += 1 } else { save() }
                }
            }
        }
        .frame(width: 540).background(FrogStyle.canvas).background(FrogWindowMaterial())
        .foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).buttonStyle(.frog())
        // Read before the first frame, so the Connection step does not change its labels once shown.
        .onAppear { hasSavedKey = model.hasAPIKey(provider.id); isSaved = model.configuration.providers.contains { $0.id == provider.id } }
        .onDisappear { testTask?.cancel(); discoveryTask?.cancel(); apiKey = "" }
        .onChange(of: provider) { _, _ in testResult = nil }
        .onChange(of: apiKey) { _, _ in testResult = nil }
        .onChange(of: clearKey) { _, _ in testResult = nil }
    }

    static let stepTitles = ["Service", "Connection", "Models"]

    static let serviceGroups: [(title: String, kinds: [ProviderKind])] = [
        ("Cloud", [.openAI, .anthropic, .gemini, .compatible]),
        ("On this Mac", [.ollama, .lmStudio]),
        ("Coding tools", [.claudeCode, .codex, .opencode]),
    ]

    /// One service to choose, marked as chosen like a list's selected row.
    private func serviceChoice(_ kind: ProviderKind) -> some View {
        let chosen = provider.kind == kind
        return Button { provider.kind = kind } label: {
            HStack(spacing: FrogStyle.space12) {
                PluginIconTile(mark: .provider(kind))
                VStack(alignment: .leading, spacing: FrogStyle.space2) {
                    Text(kind.shortTitle).font(FrogType.row)
                    Text(kind.pitch).font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1)
                }
                Spacer(minLength: FrogStyle.space8)
                if chosen {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(FrogStyle.accentText)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, FrogStyle.space8).padding(.vertical, FrogStyle.space2).frame(minHeight: FrogStyle.rowHeight)
            .contentShape(Rectangle())
            .frogRowHighlight(hovering: false, selected: chosen)
        }
        .buttonStyle(.plain).padding(.horizontal, -FrogStyle.space8)
        .accessibilityLabel(kind.shortTitle).accessibilityHint(kind.pitch)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private var serviceNote: String {
        if provider.kind.localTool != nil { return "Requests run in the background through your installed tool and its own sign-in." }
        if provider.kind.isLocal { return "\(provider.kind.shortTitle) runs outside Frog; start it before you use it." }
        return "Frog sends the text you run a rule on to \(provider.kind.title), with your API key."
    }

    private var endpointHint: String {
        switch provider.kind {
        case .ollama: "Open Ollama and download a text model (for example: ollama pull llama3.2). Then find installed models below. Frog uses /api/chat."
        case .lmStudio: "In LM Studio, download a text model and start the server in Developer. Then find installed models below. The default server port is 1234."
        case .compatible: "Enter your service’s OpenAI-compatible base URL, usually ending in /v1, and add its exact model IDs below. Get API credentials from that service."
        default: "The default is the official API base URL. Change it only if your connection uses a gateway."
        }
    }

    private var availableModels: [ProviderModel] {
        var choices = provider.kind.suggestedModels
        for choice in discovered + provider.models where !choices.contains(where: { $0.id == choice.id }) { choices.append(choice) }
        return choices.map { choice in provider.models.first(where: { $0.id == choice.id }) ?? choice }
    }

    private var modelSettings: some View {
        Group {
            FrogRowNote(text: "Choose the models your rules can use.")
            if provider.kind.isLocal || provider.kind.localTool != nil {
                HStack {
                    Button(discovering ? "Finding models…" : "Find installed models", systemImage: "arrow.clockwise") { discover() }.disabled(discovering)
                    if discovering { FrogSpinner() }
                }
                if let discoveryMessage { Text(discoveryMessage).font(FrogType.small).foregroundStyle(FrogStyle.muted) }
            }
            ForEach(availableModels) { choice in
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(choice.name).font(FrogType.body)
                        if choice.name != choice.id { Text(choice.id).font(FrogType.mono).foregroundStyle(FrogStyle.muted) }
                    }
                    Spacer(minLength: 12)
                    Toggle(choice.name, isOn: Binding(get: { provider.models.contains { $0.id == choice.id } }, set: { selected in
                        if selected { provider.models.append(choice) }
                        else { provider.models.removeAll { $0.id == choice.id } }
                        if !provider.models.contains(where: { $0.id == provider.model }) { provider.model = provider.models.first?.id ?? "" }
                    })).labelsHidden().toggleStyle(.frogCheckbox)
                }.frame(minHeight: FrogStyle.controlHeight)
            }
            if availableModels.isEmpty {
                Text(provider.kind.isLocal ? "Find installed models or add a model ID below." : "Add your service’s model IDs below.")
                    .font(FrogType.body).foregroundStyle(FrogStyle.muted)
            }
            SectionCaption(text: "Add a model").padding(.top, 6)
            FrogRow("Model type") {
                CompactSegments(values: provider.kind.supportsTranscription ? ProviderModel.Category.allCases : [.text], selected: customCategory, title: { $0 == .text ? "Text" : "Speech-to-text" }) { customCategory = $0 }
            }
            HStack(alignment: .bottom, spacing: 10) {
                LabeledField(title: "Model ID") { FrogTextField(placeholder: "Exact API model ID", text: $customModelID).accessibilityLabel("Custom model ID") }
                LabeledField(title: "Display name") { FrogTextField(placeholder: "Optional friendly name", text: $customModelName).accessibilityLabel("Custom model display name") }
                Button("Add") { addCustomModel() }.frogDisabled(customModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Enter the model ID first" : nil)
            }
        }
    }

    private func addCustomModel() {
        let id = customModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = customModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.utf8.count <= 256, name.utf8.count <= 256,
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            issue = "Use a model ID and display name of at most 256 bytes, without control characters in the ID."; return
        }
        let choice = ProviderModel(id: id, name: name.isEmpty ? id : name, category: customCategory)
        if let index = provider.models.firstIndex(where: { $0.id == id }) { provider.models[index] = choice }
        else { provider.models.append(choice) }
        if provider.model.isEmpty { provider.model = id }
        customModelID = ""; customModelName = ""; issue = nil
    }

    private func discover() {
        discovering = true; issue = nil; discoveryMessage = nil
        var draft = normalized()
        if clearKey { draft.id = UUID() }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        discoveryTask = Task { @MainActor in
            defer { discovering = false; discoveryTask = nil }
            do {
                discovered = try await model.discoverModels(draft, apiKey: key.isEmpty ? nil : key)
                try Task.checkCancellation()
                discoveryMessage = discovered.isEmpty ? "No models found. Download a text model in your local app first." : "Found \(discovered.count) models. Select the ones you want to use."
            } catch is CancellationError { }
            catch { issue = error.localizedDescription }
        }
    }

    private func normalized() -> ProviderConfiguration {
        var value = provider
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.endpoint = value.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        value.model = value.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    private func test() {
        testing = true; issue = nil; testResult = nil
        // A new identity prevents the model from falling back to a saved key when testing its removal.
        var draft = normalized()
        if clearKey { draft.id = UUID() }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        testTask = Task { @MainActor in
            defer { testing = false; testTask = nil }
            do {
                let result = try await model.testProvider(draft, apiKey: key.isEmpty ? nil : key)
                try Task.checkCancellation()
                testResult = "Connection successful. \(result)"
            } catch is CancellationError {
                issue = "Connection test cancelled."
            } catch { issue = error.localizedDescription }
        }
    }

    private func save() {
        do {
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            try model.saveProvider(normalized(), apiKey: key.isEmpty ? nil : key, clearKey: clearKey)
            dismiss()
        } catch {
            issue = error.localizedDescription
            // A save that fails after changing the key puts the previous key back, or may not manage to.
            hasSavedKey = model.hasAPIKey(provider.id)
        }
    }
}

extension ProviderKind {
    /// What the Providers tab offers to add: cloud services first, then local servers.
    static let addable: [ProviderKind] = [.openAI, .anthropic, .gemini, .ollama, .lmStudio, .compatible]

    /// The name without "(local)", where a heading already says where it runs.
    var shortTitle: String { title.replacingOccurrences(of: " (local)", with: "") }

    /// One line on what the service is, for the list of services to add and the editor's first step.
    var pitch: String {
        switch self {
        case .openAI: "GPT models in the cloud, with your API key"
        case .anthropic: "Claude models in the cloud, with your API key"
        case .gemini: "Gemini models in the cloud, with your API key"
        case .ollama: "Runs open models on this Mac"
        case .lmStudio: "Runs open models on this Mac, from its own app"
        case .compatible: "Any service with an OpenAI-style API"
        case .claudeCode: "Your Claude plan, through Claude Code on this Mac"
        case .codex: "Your ChatGPT plan, through Codex on this Mac"
        case .opencode: "Any provider you connect in OpenCode on this Mac"
        }
    }
}
