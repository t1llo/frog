import SwiftUI
import FrogCore

struct ProvidersView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: ProviderConfiguration?
    @State private var addingLocal = false
    @State private var revealedModelID: String?
    @State private var deleting: ProviderConfiguration?
    @State private var filter: String?
    @State private var kind: LocalModelDescriptor.Kind = .audio
    @State private var search = ""
    private var selectedFilter: String { filter ?? (model.localModels.installed.isEmpty ? "Providers" : "Local models") }
    private var providers: [ProviderConfiguration] {
        model.configuration.providers.filter { search.isEmpty || ($0.name + " " + $0.models.map(\.name).joined(separator: " ")).localizedStandardContains(search) }
    }
    private var sourcePicker: some View {
        CompactSegments(values: ["Local models", "Providers", "Installed tools"], selected: selectedFilter, width: 290, title: { $0 }) { filter = $0; search = "" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Models") {
                if selectedFilter == "Local models" {
                    Button("Add model…", systemImage: "plus") { addingLocal = true }.buttonStyle(.frog(.primary))
                } else if selectedFilter == "Providers" {
                    Button { editing = ProviderConfiguration() } label: { Label("Connect provider", systemImage: "plus") }
                        .buttonStyle(.frog(.primary)).keyboardShortcut("n", modifiers: .command)
                }
            }
            if selectedFilter == "Installed tools" { HStack { sourcePicker; Spacer() }.frame(height: FrogStyle.controlHeight) }
            else {
                ListToolbar(placeholder: selectedFilter == "Local models" ? "Search models" : "Search providers", search: $search) { sourcePicker }
            }
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            if selectedFilter == "Installed tools" {
                LocalToolProvidersView(client: model.localTools) { kind, selectedModel in
                    do { try model.useLocalTool(kind, model: selectedModel); filter = "Providers"; search = "" }
                    catch { model.report(error) }
                }
            } else if selectedFilter == "Local models" {
                HStack(spacing: 12) {
                    CompactSegments(values: [LocalModelDescriptor.Kind.audio, .text], selected: kind, title: { $0 == .audio ? "Speech" : "Text" }) { kind = $0 }
                    Spacer()
                    if !LocalModels.supported { Text("Requires Apple silicon").font(FrogType.caption).foregroundStyle(FrogStyle.muted) }
                }
                ModelInventory(kind: kind, search: search, revealedModelID: revealedModelID)
                if search.isEmpty { LocalModelSettingsView().padding(.top, 6) }
            } else {
                VStack(spacing: 2) {
                    ForEach(providers) { provider in
                        ProviderRow(provider: provider, edit: { editing = $0 }, delete: { deleting = $0 })
                    }
                    if providers.isEmpty { Text(search.isEmpty ? "Connect a cloud provider, Ollama or LM Studio." : "No providers match this search.").font(FrogType.caption).foregroundStyle(FrogStyle.muted).padding(8).frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(6).frogTableSurface()
            }
            }.frame(maxWidth: .infinity, alignment: .leading).minimalScrollbars()
            }
        }.padding(20).frame(maxWidth: 1080).frame(maxWidth: .infinity, alignment: .top)
        .buttonStyle(.frog())
        .sheet(item: $editing) { provider in ProviderEditor(provider: provider).environmentObject(model) }
        .sheet(isPresented: $addingLocal) {
            AddLocalModelView { item in kind = item.kind; revealedModelID = item.id; search = "" }.environmentObject(model)
        }
        .confirmationDialog("Delete \(deleting?.name ?? "provider")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete provider", role: .destructive) {
                guard let provider = deleting else { return }
                do { try model.deleteProvider(id: provider.id) } catch { model.report(error) }
                deleting = nil
            }
        } message: { Text("The saved API key will also be removed. Affected rules will use another compatible model when available.") }
    }

}

/// One provider in the Providers list: opens its editor, with its actions at the end.
private struct ProviderRow: View {
    let provider: ProviderConfiguration
    let edit: (ProviderConfiguration) -> Void
    let delete: (ProviderConfiguration) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: provider.kind.localTool != nil ? "terminal" : provider.kind.isLocal ? "desktopcomputer" : "cloud").foregroundStyle(FrogStyle.muted)
            Button { edit(provider) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name).font(FrogType.bodyMedium)
                    Text("\(provider.models.filter { $0.category == .text }.count) text · \(provider.models.filter { $0.category == .audio }.count) speech").font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            IconAction(title: "Edit provider", symbol: "pencil") { edit(provider) }
            IconMenu(title: "Provider actions") {
                Button("Duplicate") { var copy = provider; copy.id = UUID(); copy.name += " copy"; edit(copy) }
                Button("Delete…", role: .destructive) { delete(provider) }
            }
        }.padding(.vertical, 8).padding(.horizontal, 8)
            .frogRowHighlight(hovering: hovering).onHover { hovering = $0 }
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
            VStack(alignment: .leading, spacing: 6) {
                Text("External provider").font(FrogType.small).foregroundStyle(FrogStyle.muted)
                TextField("Connection name", text: $provider.name).textFieldStyle(.plain).font(FrogType.title)
                CompactSegments(values: [0, 1, 2], selected: step, title: { ["Service", "Connection", "Models"][$0] }) { step = $0 }.padding(.top, 12)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if step == 0 {
                    SettingsSection(title: "Service") {
                        CompactRow(title: "Service") {
                            FrogDropdown(selection: $provider.kind, options: ProviderKind.allCases, title: { $0.title },
                                         symbol: { $0.isLocal ? "desktopcomputer" : "cloud" })
                        }.onChange(of: provider.kind) { old, new in
                            if provider.name == old.title || provider.name == "OpenAI" { provider.name = new.title }
                            provider.endpoint = new.endpoint; provider.model = new.defaultModel
                            provider.models = new.suggestedModels
                            apiKey = ""; clearKey = hasSavedKey
                            discovered = []; discoveryMessage = nil; customModelID = ""; customModelName = ""
                            testResult = nil; issue = nil
                        }
                        if provider.kind.isLocal {
                            Link(destination: provider.kind.setupURL) {
                                Label(provider.kind.isLocal ? "\(provider.kind.title) setup guide" : "Get an API key for \(provider.kind.title)", systemImage: "arrow.up.right.square")
                            }.buttonStyle(.frog(.ghost))
                        }
                        Text(provider.kind.localTool != nil ? "Requests run invisibly through your installed tool and its existing login." : "Cloud APIs and services such as Ollama and LM Studio run outside Frog.").font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                    }.disabled(testing || discovering)
                    }
                    if step == 1 {
                    if let tool = provider.kind.localTool {
                        SettingsSection(title: "Existing tool login") {
                            Text("Frog uses \(tool.title)'s saved login. No endpoint or API key is needed here.")
                                .font(FrogType.body).foregroundStyle(FrogStyle.muted)
                            Text(tool.loginInstructions).font(FrogType.small).foregroundStyle(FrogStyle.muted)
                            if tool == .opencode {
                                Text("OpenCode keeps its own CLI history, independently of Frog's history setting.")
                                    .font(FrogType.small).foregroundStyle(FrogStyle.muted)
                            }
                        }
                    } else {
                    SettingsSection(title: "Connection") {
                        LabeledField(title: "Base endpoint") { TextField("Base endpoint", text: $provider.endpoint).labelsHidden() }
                        HStack(alignment: .top, spacing: 16) {
                            Text(endpointHint)
                                .font(FrogType.small).foregroundStyle(FrogStyle.muted).lineSpacing(3)
                            Spacer(minLength: 0)
                            Button("Reset endpoint") {
                                provider.endpoint = provider.kind.endpoint
                            }.buttonStyle(.frog(.ghost)).fixedSize()
                        }
                    }.disabled(testing || discovering)
                    SettingsSection(title: "Credentials") {
                        LabeledField(title: hasSavedKey ? "Replacement API key" : "API key") {
                            SecureField("API key", text: $apiKey).disabled(clearKey)
                        }
                        if !provider.kind.isLocal && provider.kind != .compatible {
                            Link(destination: provider.kind.setupURL) {
                                Label(provider.kind == .gemini ? "Get an API key in Google AI Studio" : "Get an API key for \(provider.kind.title)", systemImage: "arrow.up.right.square")
                            }.buttonStyle(.frog(.ghost))
                        }
                        if hasSavedKey {
                            SettingRow(title: "Remove saved key", description: "Leave the field blank to keep your existing key. A replacement is stored only when you save.") {
                                Toggle("Remove saved API key on save", isOn: $clearKey).toggleStyle(.switch).labelsHidden().controlSize(.small)
                                    .onChange(of: clearKey) { _, remove in if remove { apiKey = "" } }
                            }
                        } else {
                            Label("Saved securely in Keychain. Optional for local-only services.", systemImage: "lock.shield")
                                .font(FrogType.small).foregroundStyle(FrogStyle.muted)
                        }
                        if let credentialHint { InlineIssue(message: credentialHint) }
                    }.disabled(testing || discovering)
                    }
                    }
                    if step == 2 {
                    SettingsSection(title: "Your models") {
                        modelSettings
                    }.disabled(testing)
                    SettingsSection(title: "Take it for a spin") {
                        SettingRow(title: "Connection test", description: "Send a short sample request using this draft configuration.") {
                            HStack {
                                if testing { ProgressView().controlSize(.small) }
                                Button(testing ? "Testing…" : "Test connection") { test() }
                                    .disabled(validation != nil || testing || discovering || model.isTestingProvider)
                                if testing { Button("Cancel") { testTask?.cancel() } }
                            }
                        }
                        if let testResult {
                            Label(testResult, systemImage: "checkmark.circle.fill").font(FrogType.body)
                                .foregroundStyle(FrogStyle.accent).textSelection(.enabled)
                        }
                        if let issue { InlineIssue(message: issue) }
                    }
                    }
                    if let validation { InlineIssue(message: validation) }
                }.padding(.horizontal, 20).padding(.bottom, 12).minimalScrollbars()
            }
            HStack {
                Button("Cancel") { testTask?.cancel(); discoveryTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                Button(step < 2 && !isSaved ? "Continue" : "Save") { if step < 2 && !isSaved { step += 1 } else { save() } }.buttonStyle(.frog(.primary)).keyboardShortcut(.defaultAction)
                    .disabled(((step == 2 || isSaved) && validation != nil) || testing || discovering)
            }.padding(20)
        }
        .frame(width: 540, height: 560).background(FrogStyle.canvas).background(FrogWindowMaterial())
        .foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).buttonStyle(.frog())
        // Read before the first frame, so the Connection step does not change its labels once shown.
        .onAppear { hasSavedKey = model.hasAPIKey(provider.id); isSaved = model.configuration.providers.contains { $0.id == provider.id } }
        .onDisappear { testTask?.cancel(); discoveryTask?.cancel(); apiKey = "" }
        .onChange(of: provider) { _, _ in testResult = nil }
        .onChange(of: apiKey) { _, _ in testResult = nil }
        .onChange(of: clearKey) { _, _ in testResult = nil }
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
            Text("Choose the models available to your rules.").font(FrogType.body).foregroundStyle(FrogStyle.muted)
            if provider.kind.isLocal || provider.kind.localTool != nil {
                HStack {
                    Button(discovering ? "Finding models…" : "Find installed models", systemImage: "arrow.clockwise") { discover() }.disabled(discovering)
                    if discovering { ProgressView().controlSize(.small) }
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
            CompactRow(title: "Model type") {
                CompactSegments(values: provider.kind.supportsTranscription ? ProviderModel.Category.allCases : [.text], selected: customCategory, title: { $0 == .text ? "Text" : "Speech-to-text" }) { customCategory = $0 }
            }
            HStack(alignment: .bottom, spacing: 10) {
                LabeledField(title: "Model ID") { TextField("Exact API model ID", text: $customModelID).accessibilityLabel("Custom model ID") }
                LabeledField(title: "Display name") { TextField("Optional friendly name", text: $customModelName).accessibilityLabel("Custom model display name") }
                Button("Add") { addCustomModel() }.disabled(customModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
