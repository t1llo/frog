import AppKit
import SwiftUI
import FrogCore
import UniformTypeIdentifiers

struct RecommendedModelBadge: View {
    var body: some View { FrogBadge(text: "Recommended", active: true) }
}

/// Where the assistant is: a segment per step, filled up to the current one.
private struct SetupProgress: View {
    let step: Int
    let count: Int
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { index in
                Capsule().fill(index <= step ? FrogStyle.accent : FrogStyle.border)
                    .frame(width: 22, height: 4)
            }
        }
        .accessibilityElement().accessibilityLabel("Step \(step + 1) of \(count)")
    }
}

struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    /// Which way the last move went, so the next step comes in from that side.
    @State private var forward = true
    @State private var external = false
    @State private var provider: ProviderConfiguration?
    @State private var browse = false
    @State private var kind: LocalModelDescriptor.Kind = .audio
    @State private var issue: String?
    @State private var pendingImport: Configuration?
    @State private var microphoneAllowed = false
    /// The AI agents step offers its own button; until it is used, moving on says Not now.
    @State private var agentsOffered = false
    private let titles = ["Welcome to Frog", "Choose your models", "Permissions", "Your command bar", "AI agents", "You're ready"]

    /// `step` opens the assistant at a later step, for pictures of it.
    init(step: Int = 0) { _step = State(initialValue: step) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                FrogMark()
                VStack(alignment: .leading, spacing: 10) {
                    Text(titles[step]).font(FrogType.title).tracking(-0.4)
                    SetupProgress(step: step, count: titles.count)
                }
                Spacer()
            }.padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ZStack(alignment: .topLeading) { page.id(step).transition(stepTransition) }
                    if let issue { InlineIssue(message: issue) }
                    if let error = model.errorMessage { InlineIssue(message: error) }
                }.padding(.horizontal, 24).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading).minimalScrollbars()
            }
            HStack(spacing: 10) {
                Button("Skip setup") { model.finishSetup() }.buttonStyle(.frog(.ghost))
                Spacer()
                if step > 0 { Button("Back") { go(to: step - 1) } }
                if step > 0 && step < titles.count - 1 && !notNow { Button("Skip this step") { go(to: step + 1) }.buttonStyle(.frog(.ghost)) }
                Button(step == titles.count - 1 ? "Open Frog" : notNow ? "Not now" : "Continue") {
                    if step == titles.count - 1 { model.finishSetup() } else { go(to: step + 1) }
                }.buttonStyle(.frog(notNow ? .secondary : .primary)).keyboardShortcut(notNow ? nil : .defaultAction)
            }.padding(20)
        }.frame(width: 620, height: 610).foregroundStyle(FrogStyle.ink).background(FrogStyle.canvas).background(FrogWindowMaterial())
            .buttonStyle(.frog()).controlSize(.small).tint(FrogStyle.accent)
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

    private let agentsStep = 4
    /// On the AI agents step, moving on without its button leaves agents off.
    private var notNow: Bool { step == agentsStep && agentsOffered }

    @ViewBuilder private var page: some View {
        switch step {
        case 0: welcome
        case 1: models
        case 2: permissions
        case 3: CommandBarSetupView()
        case agentsStep: AgentSetupStep(offering: $agentsOffered)
        default: summary
        }
    }

    private func go(to next: Int) {
        forward = next > step
        issue = nil
        withAnimation(reduceMotion ? FrogMotion.reveal : FrogMotion.step) { step = next }
    }

    /// The next step slides in from the side it lies on while the last one fades; Reduce Motion only fades.
    private var stepTransition: AnyTransition {
        let removal = AnyTransition.opacity.animation(FrogMotion.exit)
        let insertion = reduceMotion ? AnyTransition.opacity : .offset(x: forward ? 16 : -16).combined(with: .opacity)
        return .asymmetric(insertion: insertion, removal: removal)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: "How would you like to use Frog?") {
                SetupChoice(title: "An offline experience", detail: "Download models once, then process text and recordings on your Mac. Apple silicon required.", symbol: "desktopcomputer", selected: !external) { external = false }
                SetupChoice(title: "External providers too", detail: "Connect a cloud API, Ollama or LM Studio. You can also use local models.", symbol: "network", selected: external) { external = true }
            }
            FrogCard {
                CompactRow(title: "Already have a configuration?", detail: "Import a file and skip the assistant.") { Button("Import settings…") { chooseImport() } }
            }
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 20) {
            if external {
                SettingsSection(title: "External providers") {
                    Text("Choose a service, add your API key if needed, and select its models. Keys stay in Keychain.").font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                    ForEach(model.configuration.providers) { item in
                        CompactRow(title: item.name, detail: "\(item.models.count) models configured") { Button("Edit…") { provider = item } }
                    }
                    Button("Connect provider…") { provider = ProviderConfiguration() }
                }
            }
            SettingsSection(title: "Recommended offline pair") {
                Text("Whisper Turbo for broad multilingual dictation and Qwen3 1.7B for writing or optional cleanup. No model account required.")
                    .font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                ForEach(LocalModelDescriptor.recommendedPair) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        CompactRow(title: item.name, detail: item.kind == .audio ? "Speech-to-text · \(item.downloadSize)" : "Text · \(item.downloadSize)") {
                            if model.localModels.installed.contains(item.id) {
                                Label("Downloaded", systemImage: "checkmark.circle.fill").font(FrogType.small).foregroundStyle(FrogStyle.accent)
                            } else if let progress = model.localModels.progress[item.id] {
                                HStack { ModelDownloadProgress(fraction: progress.fraction, preparing: model.localModels.preparing.contains(item.id), width: 90); Button("Cancel") { model.localModels.cancelDownload(item.id) } }
                            } else {
                                Button("Download") { model.localModels.download(item) }.disabled(!LocalModels.supported)
                            }
                        }
                        ModelDownloadSummary(progress: model.localModels.progress[item.id], preparing: model.localModels.preparing.contains(item.id))
                        if let error = model.localModels.errors[item.id] { Text(error).font(FrogType.caption).foregroundStyle(FrogStyle.warning) }
                    }
                }
                Button("Download recommended pair") {
                    for item in LocalModelDescriptor.recommendedPair where !model.localModels.installed.contains(item.id) && model.localModels.progress[item.id] == nil {
                        model.localModels.download(item)
                    }
                }.disabled(!LocalModels.supported || LocalModelDescriptor.recommendedPair.allSatisfy { model.localModels.installed.contains($0.id) || model.localModels.progress[$0.id] != nil })
                // The size is the catalog's, like the sizes in the rows above.
                Text("For faster dictation in 25 European languages, choose Parakeet v3\(LocalModelDescriptor.find("parakeet-v3").map { " (\($0.downloadSize))" } ?? "") under other local models below.")
                    .font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                if !LocalModels.supported { Text("Internal inference requires Apple silicon. Use an external provider on this Mac, or skip for now.").font(FrogType.caption).foregroundStyle(FrogStyle.warning) }
                Text("Downloads continue if you move to the next step. You can cancel them in Models.").font(FrogType.caption).foregroundStyle(FrogStyle.muted)
            }
            DisclosureGroup("Choose other local models", isExpanded: $browse) {
                VStack(alignment: .leading, spacing: 12) {
                    CompactSegments(values: [LocalModelDescriptor.Kind.audio, .text], selected: kind, title: { $0 == .audio ? "Speech" : "Text" }) { kind = $0 }
                    ModelInventory(kind: kind)
                }.padding(.top, 10)
            }.font(FrogType.body)
            if !external { Button("Set up an external provider instead…") { external = true }.buttonStyle(.frog(.ghost)) }
        }
    }

    private var permissions: some View {
        SettingsSection(title: "Allow only what you need") {
            permission("Accessibility", detail: "Replace selected text and switch windows with Command–Tab.", allowed: model.accessibilityGranted) {
                SelectionService.requestAccess(); SelectionService.openAccessibilitySettings()
            }
            permission("Microphone", detail: "Record speech when you run an audio rule.", allowed: microphoneAllowed) {
                Task {
                    if !DictationController.microphoneGranted { _ = await DictationController.requestMicrophone() }
                    if !DictationController.microphoneGranted { DictationController.openMicrophoneSettings() }
                    await refreshPermissions()
                }
            }
        }
    }

    private var summary: some View {
        SettingsSection(title: "Your setup is saved as you go.") {
            Text("\(model.localModels.installed.count) local models downloaded · \(model.configuration.providers.count) external providers").font(FrogType.bodyMedium)
            if !model.localModels.progress.isEmpty { Text("Model downloads are still running. See progress in Models.").foregroundStyle(FrogStyle.muted) }
            Text("Choose a model and shortcut for each action in Writing and Dictation. Option–Space is the built-in Dictate shortcut.")
            Text("Models and Settings are always available. You can mix local and external models, import settings, or reopen this assistant later.")
            Text("History is optional. Local models keep your text and recordings on this Mac; external providers receive what you send them.").font(FrogType.caption).foregroundStyle(FrogStyle.muted)
        }.font(FrogType.body)
    }

    private func permission(_ title: String, detail: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        CompactRow(title: title, detail: detail) {
            HStack(spacing: 8) {
                Label(allowed ? "Allowed" : "Not allowed", systemImage: allowed ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(FrogType.small).foregroundStyle(allowed ? FrogStyle.accent : FrogStyle.warning)
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

/// One answer to the welcome question: a block inside the card that highlights on hover and when chosen.
private struct SetupChoice: View {
    let title: String
    let detail: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(FrogStyle.accent).frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(FrogType.bodyMedium).foregroundStyle(FrogStyle.ink)
                    Text(detail).font(FrogType.small).foregroundStyle(FrogStyle.muted).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? FrogStyle.accent : FrogStyle.muted)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .frogRowHighlight(hovering: hovering, selected: selected)
                .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
        }.buttonStyle(.plain).onHover { hovering = $0 }.accessibilityAddTraits(selected ? .isSelected : [])
    }
}
