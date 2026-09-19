import SwiftUI
import FrogCore

struct ProvidersView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: ProviderConfiguration?
    @State private var deleting: ProviderConfiguration?

    var body: some View {
        VStack(spacing: 0) {
            EditorHeading(title: "Providers", subtitle: "Bring your own cloud credentials or use a local model with Ollama.")
            HStack {
                Picker("Default provider", selection: Binding(get: { model.configuration.defaultProviderID }, set: { id in
                    do { try model.setDefaultProvider(id: id) } catch { model.report(error) }
                })) {
                    Text("None selected").tag(UUID?.none)
                    ForEach(model.configuration.providers) { Text($0.name).tag(Optional($0.id)) }
                }.frame(maxWidth: 420)
                Spacer()
            }.padding(.horizontal).padding(.bottom)
            List(model.configuration.providers) { provider in
                HStack(spacing: 12) {
                    Image(systemName: provider.kind == .ollama ? "desktopcomputer" : "cloud")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(provider.name).font(.headline)
                        Text("\(provider.kind.title) · \(provider.model)").foregroundStyle(.secondary)
                        Text(provider.endpoint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if model.hasAPIKey(provider.id) {
                        Label("Key saved", systemImage: "key.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Edit") { editing = provider }.accessibilityLabel("Edit \(provider.name)")
                    Button(role: .destructive) { deleting = provider } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Delete \(provider.name)")
                }.padding(.vertical, 8)
            }
            .overlay {
                if model.configuration.providers.isEmpty {
                    ContentUnavailableView("Connect your first provider", systemImage: "server.rack", description: Text("Choose a cloud service or a running local Ollama server. Credentials are stored in macOS Keychain."))
                }
            }
            HStack {
                Button { editing = ProviderConfiguration() } label: { Label("Add provider", systemImage: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
                Spacer()
                Text("Rules can override the default provider and model.").font(.caption).foregroundStyle(.secondary)
            }.padding()
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
            EditorHeading(title: "Provider connection", subtitle: "Test this draft before saving. The test sends a short sample request to the endpoint below.")
            Form {
                Section("Connection") {
                    Picker("Service", selection: $provider.kind) {
                        ForEach(ProviderKind.allCases) { Text($0.title).tag($0) }
                    }.onChange(of: provider.kind) { old, new in
                        if provider.name == old.title || provider.name == "OpenAI" { provider.name = new.title }
                        provider.endpoint = new.endpoint; provider.model = new.defaultModel
                        testResult = nil
                    }
                    TextField("Name", text: $provider.name)
                    TextField("Base endpoint", text: $provider.endpoint)
                    TextField("Default model", text: $provider.model)
                    if provider.kind == .ollama {
                        Text("Run Ollama locally and install the model first. Frog connects to its native /api/chat API.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if provider.kind == .compatible {
                        Text("Use the API base URL, usually ending in /v1. Local compatible servers may not require a key.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Use service defaults") {
                        provider.endpoint = provider.kind.endpoint; provider.model = provider.kind.defaultModel
                    }
                }.disabled(testing)
                Section("Credentials") {
                    SecureField(model.hasAPIKey(provider.id) ? "Replacement API key" : "API key", text: $apiKey)
                        .disabled(clearKey)
                    if model.hasAPIKey(provider.id) {
                        Toggle("Remove saved API key on save", isOn: $clearKey)
                            .onChange(of: clearKey) { _, remove in if remove { apiKey = "" } }
                        Text("Leave the key field blank to keep the saved key. A new key replaces it only when you save.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Keys are stored in macOS Keychain. Local-only providers can leave this blank.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let credentialHint { InlineIssue(message: credentialHint) }
                }.disabled(testing)
                Section("Connection test") {
                    HStack {
                        Button(testing ? "Testing…" : "Test connection") { test() }
                            .disabled(validation != nil || testing || model.isTestingProvider)
                        if testing {
                            ProgressView().controlSize(.small)
                            Button("Cancel test") { testTask?.cancel() }
                        }
                    }
                    if let testResult { Label(testResult, systemImage: "checkmark.circle").foregroundStyle(.green).textSelection(.enabled) }
                    if let issue { InlineIssue(message: issue) }
                }
                if let validation { InlineIssue(message: validation) }
            }.formStyle(.grouped)
            HStack {
                Button("Cancel") { testTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save provider") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(validation != nil || testing)
            }.padding()
        }
        .frame(width: 600, height: 690)
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
