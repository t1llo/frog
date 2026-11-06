import AppKit
import SwiftUI
import FrogCore

/// The first run, one calm step at a time: a welcome, which plugins, the permissions they need, the recommended local
/// models, the providers and agents already on this Mac, and a summary. Every step can be skipped; everything here is
/// also in Plugins, Models and Settings, and setup can be run again from Settings.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, plugins, permissions, models, providers, done

        var title: String {
            switch self {
            case .welcome: "Welcome to Frog"
            case .plugins: "Choose your features"
            case .permissions: "Allow access"
            case .models: "Local models"
            case .providers: "Connect AI"
            case .done: "You're all set"
            }
        }
        var subtitle: String {
            switch self {
            case .welcome: "Window layouts, writing help, dictation and the small tools your Mac is missing, in one calm menu bar app."
            case .plugins: "Turn on what you want. You can change this any time in Features."
            case .permissions: "Frog asks only for what the features you chose need."
            case .models: "Private and offline, on your Mac. Optional."
            case .providers: "Coding tools and model servers found on this Mac."
            case .done: "Here is what is ready. Everything can be changed in Settings."
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
    /// How many parts the summary still shows as open, once it has looked.
    @State private var openSteps: Int?

    /// `step` opens at a later step, for pictures of it.
    init(step: Int = 0) { _step = State(initialValue: Step(rawValue: step) ?? .welcome) }

    var body: some View {
        ZStack {
            if step == .welcome {
                welcome.transition(stepTransition)
            } else {
                VStack(spacing: 0) {
                    // The header stays put on every step, so only the step below it changes.
                    header.padding(.top, FrogStyle.pagePadding + 4).padding(.horizontal, FrogStyle.pagePadding + 4)
                        .padding(.bottom, FrogStyle.space16)
                    OnboardingScroll(step: step) {
                        VStack(alignment: .leading, spacing: FrogStyle.space16) {
                            page
                            if let issue { InlineIssue(message: issue) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(step).transition(stepTransition)
                        .padding(.horizontal, FrogStyle.pagePadding + 4).padding(.vertical, FrogStyle.space4)
                    }
                    footer
                }
            }
        }
        // A fixed size, so no step makes the sheet jump; a long step scrolls inside.
        .frame(width: 620, height: 600).foregroundStyle(FrogStyle.ink).frogSurface(.window).background(FrogStyle.canvas)
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

    // MARK: Welcome

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: FrogStyle.space16) {
                FrogMark(size: 112)
                VStack(spacing: FrogStyle.space10) {
                    Text(L10n.text(Step.welcome.title)).font(FrogType.hero).tracking(-0.6).accessibilityAddTraits(.isHeader)
                    Text(L10n.text(Step.welcome.subtitle)).font(FrogType.lead).foregroundStyle(FrogStyle.muted)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 380)
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: FrogStyle.space10) {
                // The one hero action: taller and wider than a page's buttons.
                Button { go(to: .plugins) } label: {
                    Text("Get started").font(FrogType.section).frame(minWidth: 180, minHeight: 36)
                }.buttonStyle(.frog(.primary)).keyboardShortcut(.defaultAction)
                HStack(spacing: FrogStyle.space4) {
                    Button("Import settings…", action: chooseImport).buttonStyle(.frog(.ghost))
                    Button("Skip setup") { model.finishSetup() }.buttonStyle(.frog(.ghost))
                }
                if let issue { InlineIssue(message: issue) }
            }.padding(.bottom, FrogStyle.pagePadding + 4)
        }.padding(.horizontal, FrogStyle.pagePadding + 4).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header and footer

    /// The mark, the step's title and one line under it, at the same place on every step.
    private var header: some View {
        VStack(spacing: FrogStyle.space12) {
            FrogMark(size: 44)
            VStack(spacing: FrogStyle.space4) {
                Text(L10n.text(title)).font(FrogType.title).tracking(-0.4).accessibilityAddTraits(.isHeader)
                Text(L10n.text(subtitle)).font(FrogType.lead).foregroundStyle(FrogStyle.muted)
                    .multilineTextAlignment(.center).lineLimit(2).frame(maxWidth: 480)
            }
            .id(step).transition(.opacity.animation(FrogMotion.exit))
        }.frame(maxWidth: .infinity)
    }

    private var title: String { step.title }

    /// Frog works once setup ends, so the summary always closes as done; what was skipped is optional and is said
    /// here, not in the headline.
    private var subtitle: String {
        guard step == .done, let open = openSteps else { return step.subtitle }
        return open == 0 ? "Everything is ready. You can change it any time in Settings."
            : open == 1 ? "Frog is ready. Set up the optional step now or later in Settings."
            : "Frog is ready. Set up the \(open) optional steps now or later in Settings."
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // The ghost button's text starts at the content edge; its hover fill reaches past it.
            Button("Back") { back() }.buttonStyle(.frog(.ghost)).keyboardShortcut("[", modifiers: .command).padding(.leading, -10)
            Spacer()
            if step != .done { Button("Skip") { advance() }.buttonStyle(.frog(.ghost)) }
            Button(step == .done ? "Done" : "Continue") { advance() }.buttonStyle(.frog(.primary)).keyboardShortcut(.defaultAction)
        }
        .overlay { OnboardingProgress(step: step.rawValue - 1, count: Step.allCases.count - 1) }
        // Escape steps back too; on the welcome step it does nothing, since leaving is an explicit choice.
        .frogEscapeBack { back() }
        .padding([.horizontal, .bottom], FrogStyle.pagePadding + 4).padding(.top, FrogStyle.space12)
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome: EmptyView()
        case .plugins: OnboardingPlugins()
        case .permissions: OnboardingPermissions()
        case .models: OnboardingModels()
        case .providers: OnboardingProviders()
        case .done: OnboardingDone(open: $openSteps) { go(to: $0) }
        }
    }

    // MARK: Moving

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) { go(to: next) } else { finish() }
    }

    private func back() {
        if let previous = Step(rawValue: step.rawValue - 1) { go(to: previous) }
    }

    /// Done opens the main window on Settings, where everything chosen here can be changed.
    private func finish() {
        model.toolkit.select(.settings)
        model.finishSetup()
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

/// A step's content under the fixed header. A step taller than the window scrolls, and while more of it lies below,
/// a "More below" button sits over the fade at the bottom and scrolls there, so a cut-off row never looks like the end.
private struct OnboardingScroll<Content: View>: View {
    let step: OnboardingView.Step
    @ViewBuilder var content: Content
    @State private var bottom: CGFloat = 0
    @State private var viewport: CGFloat = 0

    private var more: Bool { bottom - viewport > 24 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("start")
                    content
                    Color.clear.frame(height: 1).id("end")
                }
                .background(GeometryReader { geometry in
                    // Read here rather than through a preference, which a scroll view does not pass up reliably.
                    let maxY = geometry.frame(in: .named("onboardingScroll")).maxY
                    Color.clear.onAppear { bottom = maxY }.onChange(of: maxY) { _, value in bottom = value }
                })
            }
            .coordinateSpace(name: "onboardingScroll")
            .scrollIndicators(.never).bottomScrollFade()
            .background(GeometryReader { geometry in
                Color.clear.onAppear { viewport = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, height in viewport = height }
            })
            .overlay(alignment: .bottom) {
                if more {
                    Button { withAnimation(FrogMotion.reveal) { proxy.scrollTo("end", anchor: .bottom) } } label: {
                        Label("More below", systemImage: "chevron.down")
                    }
                    .buttonStyle(.frog(.secondary, compact: true)).padding(.bottom, FrogStyle.space4)
                }
            }
            .onChange(of: step) { _, _ in proxy.scrollTo("start", anchor: .top) }
        }
    }
}

/// A dot per step of setup. The welcome is the cover, not a step, and has no footer, so five dots count the five
/// steps after it.
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

// MARK: Done

/// What is set up and what was skipped; a skipped part is one button from its step.
private struct OnboardingDone: View {
    @EnvironmentObject private var model: AppModel
    @State private var granted: Set<MacPermission> = []
    @Binding var open: Int?
    let jump: (OnboardingView.Step) -> Void

    var body: some View {
        let host = model.pluginHost
        let on = host.descriptors.filter { host.enabled($0.id) }.count
        let needed = OnboardingPermissionSupport.needed(model)
        let missing = needed.filter { !granted.contains($0) }
        let pair = LocalModelDescriptor.recommendedPair
        let ready = pair.filter { model.localModels.installed.contains($0.id) }.count
        let providers = model.configuration.providers.count
        let access = model.configuration.preferences.toolkitSettings.agentAccess == true
        let remaining = [on > 0, missing.isEmpty, ready > 0, providers > 0, access].filter { !$0 }.count
        FrogSection {
            row("Features", on > 0 ? "\(on) turned on" : "None turned on", done: on > 0, step: .plugins)
            row("Permissions", needed.isEmpty ? "None needed" : missing.isEmpty ? "All allowed" : "\(missing.map(\.title).joined(separator: ", ")) still to allow",
                done: missing.isEmpty, step: .permissions)
            row("Local models", ready == 0 ? "None downloaded" : "\(ready) of \(pair.count) ready", done: ready > 0, step: .models)
            row("Coding tools", providers == 0 ? "None added" : "\(providers) added", done: providers > 0, step: .providers)
            row("AI agents", access ? "Can use the frog command" : "Off", done: access, step: .providers)
        }
        .onChange(of: remaining, initial: true) { _, count in open = count }
        .task {
            while !Task.isCancelled {
                granted = await OnboardingPermissionSupport.granted()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func row(_ title: String, _ detail: String, done: Bool, step: OnboardingView.Step) -> some View {
        FrogRow(title, caption: detail, icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed").font(.system(size: 18))
                .foregroundStyle(done ? FrogStyle.good : FrogStyle.muted).frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }, control: {
            if !done { Button("Set up") { jump(step) }.buttonStyle(.frog(.secondary, compact: true)) }
        })
    }
}

// MARK: Plugins

/// Every built-in plugin as a tile to turn on or off; the change applies at once.
private struct OnboardingPlugins: View {
    @EnvironmentObject private var model: AppModel
    @State private var pending = Set<String>()
    private let columns = Array(repeating: GridItem(.flexible(), spacing: FrogStyle.space6), count: 3)

    var body: some View {
        let host = model.pluginHost
        VStack(alignment: .leading, spacing: FrogStyle.space16) {
            ForEach(PluginCategory.allCases, id: \.self) { category in
                let plugins = host.descriptors.map(\.info).filter { $0.category == category && $0.id != "community" }
                if !plugins.isEmpty {
                    VStack(alignment: .leading, spacing: FrogStyle.space8) {
                        FrogSectionHeader(category.title)
                        LazyVGrid(columns: columns, spacing: FrogStyle.space6) {
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
            HStack(spacing: FrogStyle.space8) {
                PluginIconTile(symbol: plugin.symbol, tint: plugin.tint.color, size: .list)
                    .saturation(on ? 1 : 0).opacity(on ? 1 : 0.55)
                Text(L10n.text(plugin.name)).font(FrogType.bodyMedium).foregroundStyle(on ? FrogStyle.ink : FrogStyle.muted)
                    .lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                // A tick says what is on; the tile itself stays plain, so a grid of features that are all on stays calm.
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: on ? .regular : .light))
                    .foregroundStyle(on ? FrogStyle.accent : FrogStyle.placeholder)
                    .contentTransition(.symbolEffect(.replace)).accessibilityHidden(true)
            }
            .padding(.vertical, FrogStyle.space8).padding(.leading, FrogStyle.space8).padding(.trailing, FrogStyle.space8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FrogStyle.card, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius, style: .continuous))
            .frogRowHighlight(hovering: hovering, selected: false)
            .contentShape(RoundedRectangle(cornerRadius: FrogStyle.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain).disabled(busy).onHover { hovering = $0 }.help(L10n.text(plugin.summary))
        .animation(FrogMotion.check, value: on)
        .accessibilityLabel(Text(L10n.text(plugin.name))).accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(on ? .isSelected : [])
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
        FrogSection("Recommended models", footer: LocalModels.supported ? "More models, and any from Hugging Face, are in Models." : "Local models need Apple silicon. Add a provider in the next step instead.", accessory: {
            if LocalModels.supported, missing.count > 1 {
                Button("Download both") { for item in missing { local.download(item) } }.buttonStyle(.frog(.ghost, compact: true))
            }
        }) {
            ForEach(pair) { item in
                FrogRow(item.name, caption: "\(item.kind == .audio ? "For dictation" : "For writing rules") · \(item.downloadSize)", icon: {
                    PluginIconTile(symbol: item.kind == .audio ? "waveform" : "text.alignleft", tint: (item.kind == .audio ? PluginTint.red : .green).color, size: .list)
                }, control: {
                    HStack(spacing: 8) {
                        if local.installed.contains(item.id) {
                            Label("Ready", systemImage: "checkmark.circle.fill").font(FrogType.small).foregroundStyle(FrogStyle.good)
                        } else if let progress = local.progress[item.id] {
                            ModelDownloadProgress(fraction: progress.fraction, preparing: local.preparing.contains(item.id), width: 90)
                            Button("Cancel") { local.cancelDownload(item.id) }.buttonStyle(.frog(.ghost, compact: true))
                        } else {
                            Button("Download") { local.download(item) }.buttonStyle(.frog(.secondary, compact: true))
                                .disabled(!LocalModels.supported)
                        }
                    }
                })
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
        VStack(alignment: .leading, spacing: FrogStyle.sectionSpacing - 6) {
            // Coding tools all sign in the same way, so it is said once under the list rather than on every row.
            FrogSection("Found on this Mac", footer: found?.contains { $0.kind.localTool != nil } == true ? "Coding tools use their own sign-in, so no API key is needed." : nil, accessory: {
                Button("Add with an API key…") { editing = ProviderConfiguration() }.buttonStyle(.frog(.ghost, compact: true))
            }) {
                if let found {
                    if found.isEmpty { FrogRow("Nothing found", caption: "Claude Code, Codex, OpenCode, Ollama or LM Studio show here once installed.") }
                    ForEach(found) { item in
                        FrogRow(item.name, caption: item.caption, icon: {
                            PluginIconTile(symbol: item.kind.localTool != nil ? "terminal.fill" : "server.rack", tint: PluginTint.gray.color, size: .list)
                        }, control: {
                            if configured(item.kind) {
                                Label("Added", systemImage: "checkmark.circle.fill").font(FrogType.small).foregroundStyle(FrogStyle.good)
                            } else {
                                Button("Use") { add(item) }.buttonStyle(.frog(.secondary, compact: true))
                            }
                        })
                    }
                } else {
                    FrogLoadingNote(text: "Looking for coding tools and model servers…")
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
        FrogSection("AI agents", footer: "Agents such as Claude Code get the frog command and a skill, so they can drive Frog for you.") {
            FrogRow("Let agents use Frog", caption: agents, icon: {
                PluginIconTile(symbol: "sparkles", tint: PluginTint.purple.color, size: .list)
            }, control: {
                if access && installable.isEmpty && !toolMissing {
                    Label("On", systemImage: "checkmark.circle.fill").font(FrogType.small).foregroundStyle(FrogStyle.good)
                } else {
                    Button(access ? "Install" : "Turn on", action: turnOn).buttonStyle(.frog(.secondary, compact: true))
                }
            })
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
            if kind.localTool != nil { return "Coding tool" }
            return models.isEmpty ? "Local server · running" : "Local server · \(models.count) \(models.count == 1 ? "model" : "models")"
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

