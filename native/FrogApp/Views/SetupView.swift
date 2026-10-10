import AppKit
import SwiftUI
import FrogCore
import UniformTypeIdentifiers

struct RecommendedModelBadge: View {
    var body: some View {
        Text("Recommended").font(.system(size: 9, weight: .medium)).foregroundStyle(FrogStyle.accent)
            .padding(.horizontal, 6).padding(.vertical, 3).background(FrogStyle.accentSoft, in: Capsule())
    }
}

struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var step = 0
    @State private var external = false
    @State private var provider: ProviderConfiguration?
    @State private var browse = false
    @State private var kind: LocalModelDescriptor.Kind = .audio
    @State private var issue: String?
    @State private var pendingImport: Configuration?
    @State private var microphoneAllowed = false
    private let titles = ["Welcome to Frog", "Choose your models", "Permissions", "You're ready"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                FrogMark()
                VStack(alignment: .leading, spacing: 4) {
                    Text(titles[step]).font(.system(size: 23, weight: .semibold))
                    Text("Step \(step + 1) of 4 · Everything can be changed later").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                }
                Spacer()
            }.padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch step {
                    case 0: welcome
                    case 1: models
                    case 2: permissions
                    default: summary
                    }
                    if let issue { InlineIssue(message: issue) }
                    if let error = model.errorMessage { InlineIssue(message: error) }
                }.padding(.horizontal, 24).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading).minimalScrollbars()
            }
            HStack(spacing: 10) {
                Button("Skip setup") { model.finishSetup() }
                Spacer()
                if step > 0 { Button("Back") { step -= 1; issue = nil } }
                if step == 1 || step == 2 { Button("Skip this step") { step += 1; issue = nil } }
                Button(step == 3 ? "Open Frog" : "Continue") {
                    if step == 3 { model.finishSetup() } else { step += 1; issue = nil }
                }.buttonStyle(FrogButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
            }.padding(20).overlay(alignment: .top) { Rectangle().fill(FrogStyle.border.opacity(0.5)).frame(height: 1) }
        }.frame(width: 620, height: 610).foregroundStyle(FrogStyle.ink).background(FrogStyle.canvas).background(FrogWindowMaterial())
            .buttonStyle(FrogButtonStyle()).controlSize(.small).tint(FrogStyle.accent)
            .sheet(item: $provider) { ProviderEditor(provider: $0).environmentObject(model) }
            .confirmationDialog("Import settings and skip setup?", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
                Button("Import settings") {
                    guard let configuration = pendingImport else { return }
                    do { try model.importConfiguration(configuration); pendingImport = nil; model.finishSetup() }
                    catch { pendingImport = nil; issue = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) { pendingImport = nil }
            } message: { Text("This replaces the current configuration after making a backup. API keys, downloaded models and macOS permissions are not included; configure these later in Models and Settings.") }
            .task { await refreshPermissions() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refreshPermissions() } } }
            .onChange(of: step) { _, _ in Task { await refreshPermissions() } }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How would you like to use Frog?").font(.headline)
            choice("An offline experience", detail: "Download models once, then process text and recordings on your Mac. Apple silicon required.", symbol: "desktopcomputer", selected: !external) { external = false }
            choice("External providers too", detail: "Connect a cloud API, Ollama or LM Studio. You can also use internal models.", symbol: "network", selected: external) { external = true }
            Text("This only chooses your next setup step. You can add either kind of model at any time.").font(.caption).foregroundStyle(FrogStyle.muted)
            Divider()
            CompactRow(title: "Already have a configuration?", detail: "Import a file and skip the assistant.") { Button("Import settings…") { chooseImport() } }
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 16) {
            if external {
                SettingsSection(title: "External providers") {
                    Text("Choose a service, add your API key if needed, and select its models. Keys stay in Keychain.").font(.caption).foregroundStyle(FrogStyle.muted)
                    ForEach(model.configuration.providers) { item in
                        CompactRow(title: item.name, detail: "\(item.models.count) models configured") { Button("Edit…") { provider = item } }
                    }
                    Button("Connect provider…") { provider = ProviderConfiguration() }
                }
            }
            SettingsSection(title: "Recommended offline pair") {
                Text("Whisper Turbo for broad multilingual dictation and Qwen3 1.7B for writing or optional cleanup. Approximately 1.6 GB to download; no model account required.")
                    .font(.caption).foregroundStyle(FrogStyle.muted)
                ForEach(LocalModelDescriptor.recommendedPair) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        CompactRow(title: item.name, detail: item.kind == .audio ? "Speech-to-text · \(item.size)" : "Text · \(item.size)") {
                            if model.localModels.installed.contains(item.id) {
                                Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(FrogStyle.accent)
                            } else if let progress = model.localModels.progress[item.id] {
                                HStack { ProgressView(value: progress).frame(width: 90); Button("Cancel") { model.localModels.cancelDownload(item.id) } }
                            } else {
                                Button("Download") { model.localModels.download(item) }.disabled(!LocalModels.supported)
                            }
                        }
                        if let error = model.localModels.errors[item.id] { Text(error).font(.caption).foregroundStyle(.orange) }
                    }
                }
                Button("Download recommended pair") {
                    for item in LocalModelDescriptor.recommendedPair where !model.localModels.installed.contains(item.id) && model.localModels.progress[item.id] == nil {
                        model.localModels.download(item)
                    }
                }.disabled(!LocalModels.supported || LocalModelDescriptor.recommendedPair.allSatisfy { model.localModels.installed.contains($0.id) || model.localModels.progress[$0.id] != nil })
                Text("For faster dictation in 25 European languages, choose Parakeet v3 (≈483 MB) under other internal models below.")
                    .font(.caption).foregroundStyle(FrogStyle.muted)
                if !LocalModels.supported { Text("Internal inference requires Apple silicon. Use an external provider on this Mac, or skip for now.").font(.caption).foregroundStyle(.orange) }
                Text("Downloads continue if you move to the next step. You can cancel them in Models.").font(.caption).foregroundStyle(FrogStyle.muted)
            }
            DisclosureGroup("Choose other internal models", isExpanded: $browse) {
                VStack(alignment: .leading, spacing: 12) {
                    CompactSegments(values: [LocalModelDescriptor.Kind.audio, .text], selected: kind, title: { $0 == .audio ? "Speech" : "Text" }) { kind = $0 }
                    ModelInventory(kind: kind)
                }.padding(.top, 10)
            }
            if !external { Button("Set up an external provider instead…") { external = true } }
        }
    }

    private var permissions: some View {
        SettingsSection(title: "Allow only what you need") {
            permission("Accessibility", detail: "Replace selected text and switch windows with Command–Tab.", allowed: model.accessibilityGranted) {
                SelectionService.requestAccess(); SelectionService.openAccessibilitySettings()
            }
            Divider()
            permission("Microphone", detail: "Record speech when you run an audio rule.", allowed: microphoneAllowed) {
                Task {
                    if !DictationController.microphoneGranted { _ = await DictationController.requestMicrophone() }
                    if !DictationController.microphoneGranted { DictationController.openMicrophoneSettings() }
                    await refreshPermissions()
                }
            }
            Divider()
            Text("You can skip any permission and enable it later in Settings. Features needing it stay unavailable until allowed.").font(.caption).foregroundStyle(FrogStyle.muted)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your setup is saved as you go.").font(.headline)
            Text("\(model.localModels.installed.count) internal models downloaded · \(model.configuration.providers.count) external providers")
            if !model.localModels.progress.isEmpty { Text("Model downloads are still running. See progress in Models.").foregroundStyle(FrogStyle.muted) }
            Text("Open Rules to choose a model and shortcut for each action. Option–Space is the built-in Dictate shortcut.")
            Text("Models and Settings are always available. You can mix local and external models, import settings, or reopen this assistant later.")
            Text("History is optional. Local models keep your text and recordings on this Mac; external providers receive what you send them.").font(.caption).foregroundStyle(FrogStyle.muted)
        }.font(.system(size: 13))
    }

    private func choice(_ title: String, detail: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title2).foregroundStyle(FrogStyle.accent).frame(width: 32)
                VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(FrogStyle.muted).multilineTextAlignment(.leading) }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? FrogStyle.accent : FrogStyle.muted)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? AnyShapeStyle(FrogStyle.accentSoft) : FrogStyle.inset, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? FrogStyle.accent.opacity(0.5) : FrogStyle.border))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func permission(_ title: String, detail: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        CompactRow(title: title, detail: detail) {
            HStack(spacing: 8) {
                Label(allowed ? "Allowed" : "Not allowed", systemImage: allowed ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 10)).foregroundStyle(allowed ? FrogStyle.accent : .orange)
                if !allowed { Button("Allow…", action: action) }
            }
        }
    }
    private func refreshPermissions() async {
        model.refreshSystemStatus()
        microphoneAllowed = DictationController.microphoneGranted
    }
    private func chooseImport() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { pendingImport = try ConfigurationFile.read(from: url) } catch { issue = error.localizedDescription }
    }
}
