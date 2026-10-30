import AppKit
import ApplicationServices
import SwiftUI
import UserNotifications
import FrogCore

/// The first run: which plugins, the permissions they need, the recommended local models, and the providers and agents
/// already on this Mac. Every step can be skipped; everything here is also in Plugins, Models and Settings.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case plugins, permissions, models, providers

        var title: String {
            switch self {
            case .plugins: "Welcome to Frog"
            case .permissions: "Permissions"
            case .models: "Local models"
            case .providers: "Providers and agents"
            }
        }
        var subtitle: String {
            switch self {
            case .plugins: "Pick what you want. Change it any time in Plugins."
            case .permissions: "Only what your plugins need."
            case .models: "Private and offline, on your Mac."
            case .providers: "Found on this Mac."
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step
    /// Which way the last move went, so the next step comes in from that side.
    @State private var forward = true
    @State private var issue: String?
    @State private var pendingImport: Configuration?

    /// `step` opens at a later step, for pictures of it.
    init(step: Int = 0) { _step = State(initialValue: Step(rawValue: step) ?? .plugins) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ZStack(alignment: .topLeading) { page.id(step).transition(stepTransition) }
                    if let issue { InlineIssue(message: issue) }
                }.padding(.horizontal, 28).padding(.bottom, 20).frame(maxWidth: .infinity, alignment: .leading)
            }.minimalScrollbars()
            footer
        }
        .frame(width: 600, height: 580).foregroundStyle(FrogStyle.ink).frogSurface(.window).background(FrogStyle.canvas)
        .buttonStyle(.frog()).tint(FrogStyle.accent)
        .confirmationDialog("Import settings and skip setup?", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
            Button("Import settings") {
                guard let configuration = pendingImport else { return }
                do { try model.importConfiguration(configuration); pendingImport = nil; model.finishSetup() }
                catch { pendingImport = nil; issue = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: { Text("Frog keeps a backup of the current settings. Keys, models and permissions are not imported.") }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            FrogMark()
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title).font(FrogType.title).tracking(-0.4)
                Text(step.subtitle).font(FrogType.body).foregroundStyle(FrogStyle.muted)
            }
            Spacer()
            OnboardingProgress(step: step.rawValue, count: Step.allCases.count).padding(.top, 8)
        }.padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 20)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if step == .plugins { Button("Import settings…", action: chooseImport).buttonStyle(.frog(.ghost)) }
            else { Button("Skip setup") { model.finishSetup() }.buttonStyle(.frog(.ghost)) }
            Spacer()
            if let previous = Step(rawValue: step.rawValue - 1) { Button("Back") { go(to: previous) } }
            Button(step == Step.allCases.last ? "Open Frog" : "Continue") {
                if let next = Step(rawValue: step.rawValue + 1) { go(to: next) } else { model.finishSetup() }
            }.buttonStyle(.frog(.primary)).keyboardShortcut(.defaultAction)
        }.padding(.horizontal, 28).padding(.vertical, 18)
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .plugins: OnboardingPlugins()
        case .permissions: OnboardingPermissions()
        case .models: OnboardingModels()
        case .providers: OnboardingProviders()
        }
    }

    private func go(to next: Step) {
        forward = next.rawValue > step.rawValue
        issue = nil
        withAnimation(reduceMotion ? FrogMotion.reveal : FrogMotion.step) { step = next }
    }

    /// The next step comes in from the side it lies on while the last one fades; Reduce Motion only fades.
    private var stepTransition: AnyTransition {
        let insertion = reduceMotion ? AnyTransition.opacity : .offset(x: forward ? 16 : -16).combined(with: .opacity)
        return .asymmetric(insertion: insertion, removal: .opacity.animation(FrogMotion.exit))
    }

    private func chooseImport() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { pendingImport = try ConfigurationFile.read(from: url) } catch { issue = error.localizedDescription }
    }
}

/// A dot per step; the current one is a short bar.
private struct OnboardingProgress: View {
    let step: Int
    let count: Int
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { index in
                Capsule().fill(index <= step ? FrogStyle.accent : FrogStyle.border)
                    .frame(width: index == step ? 16 : 6, height: 6)
            }
        }
        .animation(FrogMotion.reveal, value: step)
        .accessibilityElement().accessibilityLabel("Step \(step + 1) of \(count)")
    }
}

// MARK: Plugins

/// Every built-in plugin as a tile to turn on or off; the change applies at once.
private struct OnboardingPlugins: View {
    @EnvironmentObject private var model: AppModel
    @State private var pending = Set<String>()
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        let host = model.pluginHost
        VStack(alignment: .leading, spacing: 18) {
            ForEach(PluginCategory.allCases, id: \.self) { category in
                let plugins = host.descriptors.map(\.info).filter { $0.category == category && $0.id != "community" }
                if !plugins.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionCaption(text: category.title)
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(plugins) { plugin in
                                OnboardingPluginTile(plugin: plugin, on: host.enabled(plugin.id), busy: pending.contains(plugin.id)) {
                                    toggle(plugin.id, to: !host.enabled(plugin.id))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ id: String, to on: Bool) {
        pending.insert(id)
        Task {
            defer { pending.remove(id) }
            do { try await model.pluginHost.setEnabled(id, on) } catch { model.report(error) }
        }
    }
}

private struct OnboardingPluginTile: View {
    let plugin: PluginInfo
    let on: Bool
    let busy: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                PluginIconTile(symbol: plugin.symbol, tint: plugin.tint.color, size: .list)
                    .saturation(on ? 1 : 0).opacity(on ? 1 : 0.5)
                    .overlay(alignment: .bottomTrailing) {
                        if on {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 13, weight: .semibold))
                                .symbolRenderingMode(.palette).foregroundStyle(FrogStyle.canvas, FrogStyle.accent)
                                .background(Circle().fill(FrogStyle.canvas).padding(1))
                                .offset(x: 5, y: 5)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                Text(L10n.text(plugin.name)).font(FrogType.bodyMedium).foregroundStyle(on ? FrogStyle.ink : FrogStyle.muted)
                    .lineLimit(1).minimumScaleFactor(0.9)
                Spacer(minLength: 0)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .frogRowHighlight(hovering: hovering, selected: false)
            .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(busy).onHover { hovering = $0 }.help(L10n.text(plugin.summary))
        .animation(FrogMotion.check, value: on)
        .accessibilityLabel(Text(L10n.text(plugin.name))).accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: Permissions

/// The permissions the plugins that are on need, checked every second while the step is open, so a switch turned in
/// System Settings shows here as soon as the user comes back.
private struct OnboardingPermissions: View {
    @EnvironmentObject private var model: AppModel
    @State private var granted: Set<MacPermission> = []

    private var needed: [MacPermission] {
        let on = model.pluginHost.descriptors.filter { model.pluginHost.enabled($0.id) }
        let wanted = Set(on.flatMap(\.info.permissions))
        return MacPermission.allCases.filter { wanted.contains($0) && Self.checkable.contains($0) }
    }
    private static let checkable: Set<MacPermission> = [.accessibility, .microphone, .notifications]

    var body: some View {
        let needed = needed
        FrogSection {
            if needed.isEmpty {
                FrogRow("Nothing to allow", caption: "The plugins you picked need no permissions.")
            }
            ForEach(needed, id: \.self) { permission in
                FrogRow(permission.title, caption: Self.reason(permission)) {
                    if granted.contains(permission) {
                        Label("Allowed", systemImage: "checkmark.circle.fill").font(FrogType.small).foregroundStyle(FrogStyle.accent)
                            .transition(.opacity)
                    } else {
                        Button("Allow…") { request(permission) }.buttonStyle(.frog(.secondary, compact: true))
                    }
                }
            }
        }
        .animation(FrogMotion.reveal, value: granted)
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func reason(_ permission: MacPermission) -> String {
        switch permission {
        case .accessibility: "Read and replace selected text, move windows."
        case .microphone: "Record while you dictate."
        case .notifications: "Show what arrives from your phone."
        default: ""
        }
    }

    private func refresh() async {
        var now: Set<MacPermission> = []
        if AXIsProcessTrusted() { now.insert(.accessibility) }
        if DictationController.microphoneGranted { now.insert(.microphone) }
        if NotificationRouter.available {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            if status == .authorized || status == .provisional { now.insert(.notifications) }
        }
        if now != granted {
            granted = now
            if now.contains(.accessibility) != model.accessibilityGranted { model.refreshSystemStatus() }
        }
    }

    private func request(_ permission: MacPermission) {
        switch permission {
        case .accessibility:
            SelectionService.requestAccess(); SelectionService.openAccessibilitySettings()
        case .microphone:
            Task {
                if !(await DictationController.requestMicrophone()) { DictationController.openMicrophoneSettings() }
                await refresh()
            }
        case .notifications:
            guard NotificationRouter.available else { return }
            Task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                await refresh()
            }
        default: break
        }
    }
}

// MARK: Models

/// The recommended speech and text models, one download each. Every other model is in Models.
private struct OnboardingModels: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let local = model.localModels
        let pair = LocalModelDescriptor.recommendedPair
        let missing = pair.filter { !local.installed.contains($0.id) && local.progress[$0.id] == nil }
        FrogSection(footer: LocalModels.supported ? "More models, and any from Hugging Face, are in Models." : "Local models need Apple silicon. Add a provider in the next step instead.", accessory: {
            if LocalModels.supported, missing.count > 1 {
                Button("Download both") { for item in missing { local.download(item) } }.buttonStyle(.frog(.ghost, compact: true))
            }
        }) {
            ForEach(pair) { item in
                FrogRow(item.name, caption: "\(item.kind == .audio ? "Speech" : "Text") · \(item.downloadSize)") {
                    HStack(spacing: 8) {
                        if local.installed.contains(item.id) {
                            Label("Ready", systemImage: "checkmark.circle.fill").font(FrogType.small).foregroundStyle(FrogStyle.accent)
                        } else if let progress = local.progress[item.id] {
                            ModelDownloadProgress(fraction: progress.fraction, preparing: local.preparing.contains(item.id), width: 90)
                            Button("Cancel") { local.cancelDownload(item.id) }.buttonStyle(.frog(.ghost, compact: true))
                        } else {
                            Button("Download") { local.download(item) }.buttonStyle(.frog(.secondary, compact: true))
                                .disabled(!LocalModels.supported)
                        }
                    }
                }
                if let error = local.errors[item.id] { FrogRowNote(text: error, tone: FrogStyle.warning) }
            }
        }
    }
}
// MARK: Providers and agents

/// AI tools and local model servers found on this Mac, each one click from being a provider, then agent access.
private struct OnboardingProviders: View {
    @EnvironmentObject private var model: AppModel
    @State private var found: [ProviderDetection.Found]?
    @State private var editing: ProviderConfiguration?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FrogSection("Providers", accessory: {
                Button("Add with an API key…") { editing = ProviderConfiguration() }.buttonStyle(.frog(.ghost, compact: true))
            }) {
                if let found {
                    if found.isEmpty { FrogRow("Nothing found", caption: "Claude Code, Codex, OpenCode, Ollama or LM Studio show here once installed.") }
                    ForEach(found) { item in
                        FrogRow(item.name, caption: item.caption) {
                            if configured(item.kind) {
                                Label("Added", systemImage: "checkmark.circle.fill").font(FrogType.small).foregroundStyle(FrogStyle.accent)
                            } else {
                                Button("Use") { add(item) }.buttonStyle(.frog(.secondary, compact: true))
                            }
                        }
                    }
                } else {
                    FrogRow("Looking…") { ProgressView().controlSize(.small) }
                }
            }
            OnboardingAgents()
        }
        .sheet(item: $editing) { ProviderEditor(provider: $0).environmentObject(model) }
        .task { found = await ProviderDetection.detect() }
    }

    private func configured(_ kind: ProviderKind) -> Bool { model.configuration.providers.contains { $0.kind == kind } }

    private func add(_ item: ProviderDetection.Found) {
        let provider = ProviderConfiguration(name: item.name, kind: item.kind, models: item.models.isEmpty ? nil : item.models)
        do { try model.saveProvider(provider, apiKey: nil, clearKey: false) } catch { model.report(error) }
    }
}

/// One switch for agent access: turns it on and installs the `frog` command and the skill for every agent found.
private struct OnboardingAgents: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var installation = AgentInstallation()

    private var access: Bool { model.configuration.preferences.toolkitSettings.agentAccess == true }
    private var installable: [AgentInstaller.SkillFolder] {
        AgentInstaller.skillFolders.filter { installation.found($0) && [.notInstalled, .outdated].contains(installation.state($0)) }
    }
    private var toolMissing: Bool {
        switch installation.tool { case .notInstalled, .otherCopy: true; default: false }
    }
    private var agents: String {
        let names = CodingAgent.allCases.filter { installation.detected.contains($0) }.map(\.title)
        return names.isEmpty ? "Any agent can use the frog command." : names.joined(separator: ", ")
    }

    var body: some View {
        FrogSection("AI agents") {
            FrogRow("Let agents use Frog", caption: agents) {
                if access && installable.isEmpty && !toolMissing {
                    Label("On", systemImage: "checkmark.circle.fill").font(FrogType.small).foregroundStyle(FrogStyle.accent)
                } else {
                    Button(access ? "Install" : "Turn on", action: turnOn).buttonStyle(.frog(.secondary, compact: true))
                }
            }
            if let issue = installation.issue { FrogRowNote(text: issue, tone: FrogStyle.warning) }
        }
    }

    private func turnOn() {
        installation.perform {
            if !access { try model.setAgentAccess(true) }
            if toolMissing { try installation.installer.installTool() }
            for folder in installable { try installation.installer.installSkill(folder) }
        }
    }
}

/// Looks for the AI command-line tools Frog can drive and for local model servers. Only `localhost` is contacted.
enum ProviderDetection {
    struct Found: Identifiable, Equatable {
        let kind: ProviderKind
        var models: [ProviderModel] = []
        var id: String { kind.rawValue }
        var name: String { kind.title.replacingOccurrences(of: " (local)", with: "") }
        var caption: String {
            if kind.localTool != nil { return "Uses its own sign-in" }
            return models.isEmpty ? "Running" : "Running · \(models.count) \(models.count == 1 ? "model" : "models")"
        }
    }

    static func detect(discovery: LocalToolDiscovery = LocalToolDiscovery()) async -> [Found] {
        let tools = LocalToolKind.allCases.filter { discovery.executable(for: $0) != nil }
            .compactMap { tool in ProviderKind.allCases.first { $0.localTool == tool } }
            .map { Found(kind: $0) }
        async let ollama = server(.ollama)
        async let lmStudio = server(.lmStudio)
        return tools + [await ollama, await lmStudio].compactMap { $0 }
    }

    /// A local server counts when it answers its model list; a refused connection fails at once.
    private static func server(_ kind: ProviderKind) async -> Found? {
        do {
            let models = try await LLMClient().localModels(provider: ProviderConfiguration(name: kind.title, kind: kind), apiKey: nil)
            return Found(kind: kind, models: models)
        } catch { return nil }
    }
}
