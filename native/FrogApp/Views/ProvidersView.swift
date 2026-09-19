import SwiftUI
import FrogCore

struct ProvidersView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: ProviderConfiguration?
    @State private var deleting: ProviderConfiguration?

    var body: some View {
        PageScroll {
            PageHeader(title: "Choose your intelligence.", subtitle: "Cloud or local. Your models, your keys, your choice.") {
                Button { editing = ProviderConfiguration() } label: { Label("Add provider", systemImage: "plus") }
                    .buttonStyle(FrogButtonStyle(primary: true)).keyboardShortcut("n", modifiers: .command)
            }
            FrogCard {
                SettingRow(title: "Your go-to provider", description: "Used by any rule without its own provider.") {
                    Picker("Default provider", selection: Binding(get: { model.configuration.defaultProviderID }, set: { id in
                        do { try model.setDefaultProvider(id: id) } catch { model.report(error) }
                    })) {
                        Text("Choose a provider").tag(UUID?.none)
                        ForEach(model.configuration.providers) { Text($0.name).tag(Optional($0.id)) }
                    }.labelsHidden().frame(width: 210)
                }
            }
            SectionCaption(text: "Connections · \(model.configuration.providers.count)")
            LazyVStack(spacing: 14) {
                ForEach(model.configuration.providers) { provider in
                    FrogCard {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(spacing: 14) {
                                SymbolTile(symbol: provider.kind == .ollama ? "desktopcomputer" : "cloud")
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(provider.name).font(.system(size: 15, weight: .semibold))
                                    Text(provider.kind.title).font(.system(size: 12)).foregroundStyle(FrogStyle.muted)
                                }
                                Spacer()
                                if model.configuration.defaultProviderID == provider.id { FrogBadge(text: "Default", active: true) }
                            }
                            HStack(spacing: 8) {
                                Label(provider.model, systemImage: "cpu").font(.system(size: 12, weight: .medium))
                                Spacer()
                                Label(model.hasAPIKey(provider.id) ? "Key secured" : "No saved key", systemImage: model.hasAPIKey(provider.id) ? "lock.shield" : "key")
                                    .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                            }
                            Rectangle().fill(FrogStyle.border).frame(height: 1)
                            HStack {
                                Text(provider.endpoint).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(FrogStyle.muted).lineLimit(1).textSelection(.enabled)
                                Spacer(minLength: 16)
                                Button("Configure") { editing = provider }.accessibilityLabel("Configure \(provider.name)")
                                Menu {
                                    Button("Make default") {
                                        do { try model.setDefaultProvider(id: provider.id) } catch { model.report(error) }
                                    }.disabled(model.configuration.defaultProviderID == provider.id)
                                    Button("Delete provider…", role: .destructive) { deleting = provider }
                                } label: { Image(systemName: "ellipsis") }
                                    .menuStyle(.borderlessButton).frame(width: 20).accessibilityLabel("Actions for \(provider.name)")
                            }
                        }
                    }
                }
                if model.configuration.providers.isEmpty {
                    FrogCard {
                        FrogEmptyState(symbol: "cpu", title: "Meet your writing partner", message: "Connect OpenAI, Claude, Gemini, or your own local model. Your API keys stay in macOS Keychain.")
                    }
                }
            }
            Label("Cloud credentials live in Keychain. Local models can work without a key.", systemImage: "lock.shield")
                .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
        }
        .sheet(item: $editing) { provider in ProviderEditor(provider: provider).environmentObject(model) }
        .confirmationDialog("Delete \(deleting?.name ?? "provider")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete provider", role: .destructive) {
                guard let provider = deleting else { return }
                do { try model.deleteProvider(id: provider.id) } catch { model.report(error) }
                deleting = nil
            }
        } message: { Text("The saved API key will also be removed. Review rules that use this provider afterward.") }
    }
}

private struct ProviderEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var provider: ProviderConfiguration
    @State private var apiKey = ""
    @State private var clearKey = false
    @State private var issue: String?
    @State private var testResult: String?
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?

    private var validation: String? {
        if provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a provider name." }
        guard let url = URL(string: provider.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), let host = url.host, !host.isEmpty else {
            return "Enter a full HTTP or HTTPS endpoint, including its host."
        }
        if url.user != nil || url.password != nil || url.query != nil || url.fragment != nil { return "Use an endpoint without credentials, query parameters, or a fragment." }
        if provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a model name available from this provider." }
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
            EditorHeading(title: "Connect your model.", subtitle: "A home for your favorite intelligence. Test it before saving.")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FrogCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Picker("Service", selection: $provider.kind) {
                                ForEach(ProviderKind.allCases) { Text($0.title).tag($0) }
                            }.onChange(of: provider.kind) { old, new in
                                if provider.name == old.title || provider.name == "OpenAI" { provider.name = new.title }
                                provider.endpoint = new.endpoint; provider.model = new.defaultModel
                                testResult = nil
                            }
                            LabeledField(title: "Connection name") { TextField("Connection name", text: $provider.name).labelsHidden() }
                            LabeledField(title: "Base endpoint") { TextField("Base endpoint", text: $provider.endpoint).labelsHidden().font(.system(size: 12, design: .monospaced)) }
                            LabeledField(title: "Default model") { TextField("Default model", text: $provider.model).labelsHidden() }
                            HStack(alignment: .top, spacing: 16) {
                                Text(provider.kind == .ollama ? "Run Ollama and install your model first. Frog uses its native /api/chat API." : "Use the API base URL. Compatible services usually end in /v1.")
                                    .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).lineSpacing(3)
                                Spacer(minLength: 0)
                                Button("Reset defaults") {
                                    provider.endpoint = provider.kind.endpoint; provider.model = provider.kind.defaultModel
                                }.fixedSize()
                            }
                        }
                    }.disabled(testing)
                    SectionCaption(text: "Credentials")
                    FrogCard {
                        VStack(alignment: .leading, spacing: 14) {
                            LabeledField(title: model.hasAPIKey(provider.id) ? "Replacement API key" : "API key") {
                                SecureField("API key", text: $apiKey).disabled(clearKey)
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
                    }.disabled(testing)
                    SectionCaption(text: "Take it for a spin")
                    FrogCard {
                        VStack(alignment: .leading, spacing: 14) {
                            SettingRow(title: "Connection test", description: "Send a short sample request using this draft configuration.") {
                                HStack {
                                    if testing { ProgressView().controlSize(.small) }
                                    Button(testing ? "Testing…" : "Test connection") { test() }
                                        .disabled(validation != nil || testing || model.isTestingProvider)
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
                    if let validation { InlineIssue(message: validation) }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
            HStack {
                Button("Cancel") { testTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save provider") { save() }.buttonStyle(FrogButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(validation != nil || testing)
            }.padding(20).background(FrogStyle.surface)
                .overlay(alignment: .top) { Rectangle().fill(FrogStyle.border).frame(height: 1) }
        }
        .frame(width: 640, height: 700).background(FrogStyle.canvas)
        .foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).buttonStyle(FrogButtonStyle())
        .onDisappear { testTask?.cancel(); apiKey = "" }
        .onChange(of: provider) { _, _ in testResult = nil }
        .onChange(of: apiKey) { _, _ in testResult = nil }
        .onChange(of: clearKey) { _, _ in testResult = nil }
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
