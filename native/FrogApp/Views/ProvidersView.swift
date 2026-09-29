import SwiftUI
import FrogCore

struct ProvidersView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: ProviderConfiguration?
    @State private var addingLocal = false
    @State private var revealedModelID: String?
    @State private var deleting: ProviderConfiguration?
    @State private var filter = "External providers"
    @State private var kind: LocalModelDescriptor.Kind = .audio
    @State private var search = ""
    private var providers: [ProviderConfiguration] {
        model.configuration.providers.filter { search.isEmpty || ($0.name + " " + $0.models.map(\.name).joined(separator: " ")).localizedStandardContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Models", subtitle: "") {
                if filter == "Internal models" {
                    Button("Add model…", systemImage: "plus") { addingLocal = true }
                } else {
                Button { editing = ProviderConfiguration() } label: { Label("Connect provider", systemImage: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
                }
            }
            ListToolbar(placeholder: "Search models", search: $search) {
                ForEach(["External providers", "Internal models"], id: \.self) { name in FilterTag(title: name, selected: filter == name) { filter = name } }
            }
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            if filter == "Internal models" {
                Text("Downloaded and run by Frog on this Mac.").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    FilterTag(title: "Audio", selected: kind == .audio) { kind = .audio }
                    FilterTag(title: "Text", selected: kind == .text) { kind = .text }
                    Spacer()
                    if !LocalModels.supported { Text("Requires Apple silicon").font(.caption).foregroundStyle(.secondary) }
                }
                ModelInventory(kind: kind, search: search, revealedModelID: revealedModelID)
            } else {
                Text("Cloud APIs, Ollama and LM Studio run outside Frog.").font(.caption).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(providers) { provider in
                        HStack(spacing: 10) {
                            Image(systemName: provider.kind.isLocal ? "desktopcomputer" : "cloud").foregroundStyle(.secondary)
                            Button { editing = provider } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(provider.name).font(.system(size: 12, weight: .medium))
                                    Text("\(provider.models.filter { $0.category == .text }.count) text · \(provider.models.filter { $0.category == .audio }.count) speech").font(.system(size: 10)).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            IconAction(title: "Edit provider", symbol: "pencil") { editing = provider }
                            Menu {
                                Button("Duplicate") { var copy = provider; copy.id = UUID(); copy.name += " copy"; editing = copy }
                                Button("Delete…", role: .destructive) { deleting = provider }
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }.padding(12)
                        if provider.id != providers.last?.id { Divider().opacity(0.5) }
                    }
                    if model.configuration.providers.isEmpty { Text("Connect a cloud provider, Ollama or LM Studio.").font(.caption).foregroundStyle(.secondary).padding(14) }
                }.frogTableSurface()
            }
            }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(20)
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
        } message: { Text("The saved API key will also be removed. Choose a new model in affected rules.") }
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
    @State private var step = 0
    @State private var customCategory: ProviderModel.Category = .text

    private var validation: String? {
        if provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a provider name." }
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
           clearKey || !model.hasAPIKey(provider.id) {
            return "This cloud service needs an API key before it can process text."
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("External provider").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                TextField("Connection name", text: $provider.name).textFieldStyle(.plain).font(.system(size: 23, weight: .semibold))
                CompactSegments(values: [0, 1, 2], selected: step, title: { ["Service", "Connection", "Models"][$0] }) { step = $0 }.padding(.top, 12)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if step == 0 {
                    SettingsSection(title: "Service") {
                        VStack(alignment: .leading, spacing: 16) {
                            FrogMenu(title: "Service", value: provider.kind.title) {
                                ForEach(ProviderKind.allCases) { kind in
                                    Button { provider.kind = kind } label: {
                                        Label(kind.title, systemImage: kind.isLocal ? "desktopcomputer" : "cloud")
                                    }
                                }
                            }.onChange(of: provider.kind) { old, new in
                                if provider.name == old.title || provider.name == "OpenAI" { provider.name = new.title }
                                provider.endpoint = new.endpoint; provider.model = new.defaultModel
                                provider.models = new.suggestedModels
                                apiKey = ""; clearKey = model.hasAPIKey(provider.id)
                                discovered = []; discoveryMessage = nil; customModelID = ""; customModelName = ""
                                testResult = nil; issue = nil
                            }
                            if provider.kind.isLocal {
                                Link(destination: provider.kind.setupURL) {
                                    Label(provider.kind.isLocal ? "\(provider.kind.title) setup guide" : "Get an API key for \(provider.kind.title)", systemImage: "arrow.up.right.square")
                                }.foregroundStyle(FrogStyle.accent).font(.system(size: 12))
                            }
                        }
                    }.disabled(testing || discovering)
                    Text("Cloud APIs and services such as Ollama and LM Studio run outside Frog.").font(.caption).foregroundStyle(FrogStyle.muted)
                    }
                    if step == 1 {
                    SettingsSection(title: "Connection") {
                        VStack(alignment: .leading, spacing: 16) {
                            CompactRow(title: "Base endpoint") { TextField("Base endpoint", text: $provider.endpoint).textFieldStyle(.roundedBorder).labelsHidden().font(.system(size: 12, design: .monospaced)) }
                            HStack(alignment: .top, spacing: 16) {
                                Text(endpointHint)
                                    .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).lineSpacing(3)
                                Spacer(minLength: 0)
                                Button("Reset endpoint") {
                                    provider.endpoint = provider.kind.endpoint
                                }.fixedSize()
                            }
                        }
                    }.disabled(testing || discovering)
                    SettingsSection(title: "Credentials") {
                        VStack(alignment: .leading, spacing: 14) {
                            LabeledField(title: model.hasAPIKey(provider.id) ? "Replacement API key" : "API key") {
                                SecureField("API key", text: $apiKey).disabled(clearKey)
                            }
                            if !provider.kind.isLocal && provider.kind != .compatible {
                                Link(destination: provider.kind.setupURL) {
                                    Label(provider.kind == .gemini ? "Get an API key in Google AI Studio" : "Get an API key for \(provider.kind.title)", systemImage: "arrow.up.right.square")
                                }.foregroundStyle(FrogStyle.accent)
                            }
                            if model.hasAPIKey(provider.id) {
                                SettingRow(title: "Remove saved key", description: "Leave the field blank to keep your existing key. A replacement is stored only when you save.") {
                                    Toggle("Remove saved API key on save", isOn: $clearKey).toggleStyle(.switch).labelsHidden().controlSize(.small)
                                        .onChange(of: clearKey) { _, remove in if remove { apiKey = "" } }
                                }
                            } else {
                                Label("Saved securely in Keychain. Optional for local-only services.", systemImage: "lock.shield")
                                    .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                            }
                            if let credentialHint { InlineIssue(message: credentialHint) }
                        }
                    }.disabled(testing || discovering)
                    }
                    if step == 2 {
                    SectionCaption(text: "Your models")
                    modelSettings.disabled(testing)
                    SectionCaption(text: "Take it for a spin")
                    FrogCard {
                        VStack(alignment: .leading, spacing: 14) {
                            SettingRow(title: "Connection test", description: "Send a short sample request using this draft configuration.") {
                                HStack {
                                    if testing { ProgressView().controlSize(.small) }
                                    Button(testing ? "Testing…" : "Test connection") { test() }
                                        .disabled(validation != nil || testing || discovering || model.isTestingProvider)
                                    if testing { Button("Cancel") { testTask?.cancel() } }
                                }
                            }
                            if let testResult {
                                Label(testResult, systemImage: "checkmark.circle.fill").font(.system(size: 12))
                                    .foregroundStyle(FrogStyle.accent).textSelection(.enabled)
                            }
                            if let issue { InlineIssue(message: issue) }
                        }
                    }
                    }
                    if let validation { InlineIssue(message: validation) }
                }.padding(.horizontal, 20).padding(.bottom, 12)
            }
            HStack {
                Button("Cancel") { testTask?.cancel(); discoveryTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                Button(step < 2 ? "Continue" : "Save") { if step < 2 { step += 1 } else { save() } }.buttonStyle(FrogButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled((step == 2 && validation != nil) || testing || discovering)
            }.padding(20).background(FrogStyle.surface)
                .overlay(alignment: .top) { Rectangle().fill(FrogStyle.border).frame(height: 1) }
        }
        .frame(width: 540, height: 560).background(FrogWindowMaterial()).background(FrogStyle.canvas)
        .foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).buttonStyle(FrogButtonStyle())
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
        FrogCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose the models available to your rules.").font(.system(size: 12)).foregroundStyle(FrogStyle.muted)
                if provider.kind.isLocal {
                    HStack {
                        Button(discovering ? "Finding models…" : "Find installed models", systemImage: "arrow.clockwise") { discover() }.disabled(discovering)
                        if discovering { ProgressView().controlSize(.small) }
                    }
                    if let discoveryMessage { Text(discoveryMessage).font(.system(size: 11)).foregroundStyle(FrogStyle.muted) }
                }
                ForEach(availableModels) { choice in
                    Toggle(isOn: Binding(get: { provider.models.contains { $0.id == choice.id } }, set: { selected in
                        if selected { provider.models.append(choice) }
                        else { provider.models.removeAll { $0.id == choice.id } }
                        if !provider.models.contains(where: { $0.id == provider.model }) { provider.model = provider.models.first?.id ?? "" }
                    })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(choice.name).font(.system(size: 12, weight: .medium))
                            if choice.name != choice.id { Text(choice.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(FrogStyle.muted) }
                        }
                    }.toggleStyle(.checkbox)
                }
                if availableModels.isEmpty {
                    Text(provider.kind.isLocal ? "Find installed models or add a model ID below." : "Add your service’s model IDs below.")
                        .font(.system(size: 12)).foregroundStyle(FrogStyle.muted)
                }
                Divider()
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
        } catch { issue = error.localizedDescription }
    }
}
