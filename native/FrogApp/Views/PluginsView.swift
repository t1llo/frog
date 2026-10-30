import AppKit
import FrogCore
import SwiftUI
import UniformTypeIdentifiers

enum PluginsTab: String, CaseIterable, Identifiable {
    case installed, browse, build
    var id: String { rawValue }
    var title: String {
        switch self {
        case .installed: "Installed"
        case .browse: "Directory"
        case .build: "Build your own"
        }
    }
}

/// The Community plugins page: what is installed, the signed directory at frog.beffa.xyz, and how to build one.
struct PluginsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var plugins: PluginRuntime
    @State private var tab = PluginsTab.installed
    @State private var search = ""
    @State private var link = ""
    @State private var removing: PluginItem?

    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Community plugins", subtitle: "Each runs in its own sandbox, with only the access you approve.") {
                if let host = plugins.downloading {
                    ProgressView().controlSize(.small).help("Downloading from \(host)")
                }
                IconAction(title: "Install a plugin file", symbol: "square.and.arrow.down", bordered: true) { chooseFile() }
            }
            HStack(spacing: 8) {
                CompactSegments(values: PluginsTab.allCases, selected: tab, width: 320, title: \.title) { tab = $0 }
                Spacer()
                if tab == .browse, !plugins.registry.isEmpty {
                    SearchBox(placeholder: "Search the directory", text: $search).frame(width: 220)
                }
            }
            switch tab {
            case .installed: installed
            case .browse: directory
            case .build: build
            }
        }
        .onAppear { plugins.refresh() }
        .alert(item: $removing) { item in
            Alert(title: Text("Remove \(item.name)?"),
                  message: Text("Its files and what it stored move to the Trash."),
                  primaryButton: .destructive(Text("Remove")) { plugins.remove(item.id) },
                  secondaryButton: .cancel())
        }
    }

    // MARK: Installed

    @ViewBuilder private var installed: some View {
        if plugins.items.isEmpty {
            FrogEmptyState(symbol: "puzzlepiece.extension", title: "No plugins yet",
                           message: "Install one from the directory, or have your AI agent build one.") {
                HStack(spacing: 8) {
                    Button("Open the directory") { tab = .browse }.buttonStyle(.frog(.primary))
                    Button("Build your own") { tab = .build }
                }
            }.frogTableSurface()
        } else {
            FrogSection {
                ForEach(plugins.items) { installedRow($0) }
            }
        }
    }

    private func installedRow(_ item: PluginItem) -> some View {
        FrogRow(item.name, caption: item.problem ?? caption(item)) {
            PluginIconTile(symbol: PluginSymbol.name(item.symbol), tint: FrogStyle.accent)
        } control: {
            HStack(spacing: 6) {
                if item.needsReview {
                    Button("Review") {
                        do { try plugins.reviewInstalled(item.id) } catch { model.report(error) }
                    }.buttonStyle(.frog(.primary, compact: true))
                } else if item.problem == nil {
                    if plugins.running.contains(item.id) { FrogBadge(text: "Running") }
                    if item.runs, item.hasPage { Button("Open") { model.openPlugin(item.id) }.buttonStyle(.frog(compact: true)) }
                    Toggle("", isOn: Binding(get: { item.record.enabled }, set: { plugins.setEnabled(item.id, $0) }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .accessibilityLabel("\(item.name) on")
                }
                IconMenu(title: "More about \(item.name)") {
                    Text(source(item))
                    Button("Remove…", systemImage: "trash", role: .destructive) { removing = item }
                }
            }
        }
    }

    private func caption(_ item: PluginItem) -> String {
        let manifest = item.manifest
        let actions = manifest?.actions.count ?? 0
        return [manifest?.version, manifest?.description, actions > 0 ? (actions == 1 ? "1 action" : "\(actions) actions") : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func source(_ item: PluginItem) -> String {
        switch item.record.source {
        case .folder: "Built on this Mac · \(item.record.source.label)"
        case .link, .file: "From \(item.record.source.label)"
        }
    }

    // MARK: Directory

    private var shown: [PluginRegistryEntry] { plugins.registry.filter { $0.matches(search) } }

    @ViewBuilder private var directory: some View {
        Group {
            if plugins.registryKeys.isEmpty {
                FrogEmptyState(symbol: "checkmark.seal", title: "The directory opens soon",
                               message: "Frog installs only plugins the directory signed, and no entry is signed yet.").frogTableSurface()
            } else if plugins.loadingRegistry, plugins.registry.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 44)
            } else if let error = plugins.registryError, plugins.registry.isEmpty {
                FrogEmptyState(symbol: "wifi.exclamationmark", title: "The directory did not load", message: error) {
                    Button("Try again") { Task { await plugins.loadRegistry() } }
                }.frogTableSurface()
            } else if plugins.registry.isEmpty {
                FrogEmptyState(symbol: "square.grid.2x2", title: "Nothing listed yet",
                               message: "Plugins people share appear here once frog.beffa.xyz/plugins lists them.").frogTableSurface()
            } else if shown.isEmpty {
                FrogEmptyState(symbol: "magnifyingglass", title: "Nothing matches", message: "Try another word.").frogTableSurface()
            } else {
                FrogSection(footer: "Frog checks each file's signature and SHA-256 before installing it. One that asks for access opens its review first.") {
                    ForEach(shown) { listingRow($0) }
                    if plugins.registryRejected > 0 {
                        FrogRowNote(text: "\(plugins.registryRejected) entries were left out: their signature did not check.", tone: FrogStyle.warning)
                    }
                }
            }
        }
        .task { if plugins.registry.isEmpty, !plugins.registryKeys.isEmpty { await plugins.loadRegistry() } }
    }

    private func listingRow(_ entry: PluginRegistryEntry) -> some View {
        let installed = plugins.item(entry.id)
        let permissions = entry.permissions.compactMap { PluginPermission(rawValue: $0)?.title.lowercased() }
        let caption = [entry.summary, "by \(entry.author)", permissions.isEmpty ? nil : "asks to " + permissions.joined(separator: ", ")]
            .compactMap { $0 }.joined(separator: " · ")
        return FrogRow("\(entry.name) \(entry.version)", caption: caption) {
            PluginIconTile(symbol: PluginSymbol.name(entry.displaySymbol), tint: FrogStyle.accent)
        } control: {
            if let installed, installed.record.sha256 == entry.sha256.lowercased() || !Self.isNewer(entry, than: installed) {
                FrogBadge(text: "Installed")
            } else if plugins.installing == entry.id {
                ProgressView().controlSize(.small).frame(width: 60)
            } else if !entry.runs(on: AppVersion.current) {
                FrogBadge(text: "Needs Frog \(entry.frog ?? "")")
            } else {
                Button(installed == nil ? "Install" : "Update") { install(entry) }
                    .buttonStyle(.frog(installed == nil ? .primary : .secondary, compact: true))
                    .disabled(plugins.installing != nil || plugins.downloading != nil)
            }
        }
    }

    /// Whether the entry is a newer version than the one installed; the Directory never offers an older one.
    private static func isNewer(_ entry: PluginRegistryEntry, than installed: PluginItem) -> Bool {
        guard let listed = PluginVersion(entry.version) else { return false }
        guard let version = installed.manifest?.version, let current = PluginVersion(version) else { return true }
        return listed > current
    }

    // MARK: Build

    private static let prompt = "Build me a Frog plugin that … Run `frog plugin guide` first and follow it."

    @ViewBuilder private var build: some View {
        FrogSection("Build one with your AI agent",
                    footer: "Your agent writes the files, installs the plugin for your review and checks a picture of its page.") {
            FrogRow("Ask your agent", caption: Self.prompt) {
                CopyAction { ViewActions.copy(Self.prompt) }
            }
            FrogRow("Let it use Frog", caption: "Settings → Agents installs the frog command and skill.") {
                Button("Settings") { model.toolkit.select(.settings) }.buttonStyle(.frog(compact: true))
            }
            FrogRow("Share it", caption: "frog plugin publish packs it and prints the entry for the directory.")
        }
        FrogSection("Install from a link") {
            FrogRow("Link to a .frogplugin file", caption: "You review what it asks for before anything is installed.") {
                HStack(spacing: 6) {
                    TextField("https://…", text: $link).textFieldStyle(.plain).font(FrogType.body)
                        .padding(.horizontal, 8).frame(width: 240).frogControlSurface()
                        .onSubmit(openTypedLink)
                    Button("Review", action: openTypedLink).buttonStyle(.frog(compact: true))
                        .disabled(typedLink == nil || plugins.downloading != nil)
                }
            }
        }
    }

    // MARK: Actions

    private var typedLink: URL? {
        URL(string: link.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == "https" && $0.host != nil ? $0 : nil }
    }

    private func openTypedLink() {
        guard let url = typedLink else { return }
        Task {
            do { try await plugins.openLink(url, sha256: nil); link = "" } catch { model.report(error) }
        }
    }

    private func install(_ entry: PluginRegistryEntry) {
        Task {
            do { try await plugins.install(entry) } catch { model.report(error) }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: PluginArchive.fileExtension) ?? .zip]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .frogplugin file. You review what it asks for before it is installed."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try PluginPackage.readFile(url, maximumBytes: PluginArchive.maximumArchiveBytes)
                try await plugins.openArchive(data, source: .file(url.path))
            } catch { model.report(error) }
        }
    }
}

enum PluginSymbol {
    /// The plugin's SF Symbol, or the default one when this Mac has no symbol by that name.
    static func name(_ symbol: String) -> String {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil ? PluginManifest.defaultSymbol : symbol
    }
}

/// What a plugin asks for, before it is installed or when an update asks for more.
struct PluginReviewSheet: View {
    let review: PluginReview
    @ObservedObject var plugins: PluginRuntime
    let report: (Error) -> Void
    /// The main button waits a moment after the sheet changes, so a click meant for something else cannot approve it.
    @State private var armed = false

    private var manifest: PluginManifest { review.package.manifest }

    var body: some View {
        let additions = review.additions
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                SymbolTile(symbol: PluginSymbol.name(manifest.displaySymbol), size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(review.approved == nil ? "Install \(manifest.name)?" : "Update \(manifest.name)?").font(FrogType.section)
                    Text("Version \(manifest.version)\(manifest.author.map { " · by \($0)" } ?? "")").font(FrogType.small).foregroundStyle(FrogStyle.muted)
                    origin
                }
            }
            Text(manifest.description).font(FrogType.body).fixedSize(horizontal: false, vertical: true)
            if let replacing = review.replacing {
                InlineIssue(message: "You have \(manifest.name) from \(replacing.label). This one comes from \(review.source.label): it replaces that plugin and gets what it stored. Install it only if both come from the same author.")
            }
            if !review.compatible {
                InlineIssue(message: "It needs Frog \(manifest.frog ?? "") or later. Update Frog first.")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if manifest.permissions.isEmpty {
                        Text("It asks for no permissions: it shows its page, keeps its own storage and receives its commands.")
                            .font(FrogType.body).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
                    } else {
                        SectionCaption(text: review.approved != nil && additions.permissions.isEmpty && additions.hosts.isEmpty && additions.scripts.isEmpty
                                       ? "It asks for nothing new" : "It asks to")
                        ForEach(manifest.permissions, id: \.self) { permission in
                            permissionRow(permission, new: review.approved != nil && additions.permissions.contains(permission))
                        }
                    }
                    if !manifest.actions.isEmpty {
                        SectionCaption(text: "Actions you and your agents can run")
                        ForEach(manifest.actions, id: \.id) { action in
                            HStack(spacing: 6) {
                                Text(action.title).font(FrogType.body)
                                Spacer(minLength: 8)
                                Text(action.effect.title).font(FrogType.small)
                                    .foregroundStyle(action.effect == .read ? FrogStyle.muted : FrogStyle.ink)
                            }
                        }
                    }
                    if !manifest.hosts.isEmpty {
                        SectionCaption(text: "Sites it can reach")
                        ForEach(manifest.hosts, id: \.self) { host in
                            HStack(spacing: 6) {
                                Text(host).font(FrogType.mono)
                                if review.approved != nil, additions.hosts.contains(host) { FrogBadge(text: "New", active: true) }
                            }
                        }
                    }
                    if !manifest.scripts.isEmpty {
                        SectionCaption(text: "Scripts it can run")
                        ForEach(manifest.scripts.keys.sorted(), id: \.self) { name in
                            DisclosureGroup {
                                ScrollView {
                                    Text((try? review.package.scriptText(name)) ?? "The script could not be read.")
                                        .font(FrogType.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }.frame(maxHeight: 160).padding(8).background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
                            } label: {
                                HStack(spacing: 6) {
                                    Text(name).font(FrogType.mono)
                                    if review.approved != nil, additions.scripts.contains(name) { FrogBadge(text: "Changed", active: true) }
                                }
                            }
                        }
                        if review.approved != nil, additions.scripts.contains(PluginGrant.filesKey) {
                            HStack(spacing: 6) {
                                Text("Its files changed, and its scripts can run any of them.").font(FrogType.small).foregroundStyle(FrogStyle.muted)
                                FrogBadge(text: "Changed", active: true)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 320).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("\(review.package.files.count) files · \(ByteCountFormatter.string(fromByteCount: Int64(review.package.size), countStyle: .file))")
                    .font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                Spacer()
                Button(review.installed ? "Not now" : "Cancel") { plugins.dismissReview() }.keyboardShortcut(.cancelAction)
                Button(review.installed ? "Allow" : review.approved == nil ? "Install" : "Update") {
                    do { try plugins.approve(review) } catch { report(error); plugins.dismissReview() }
                }.buttonStyle(.frog(.primary)).disabled(!review.compatible || !armed)
            }
        }
        .task(id: review.id) {
            armed = false
            try? await Task.sleep(for: .seconds(1))
            armed = true
        }
        .padding(20).frame(width: 480)
        .font(FrogType.body).foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).buttonStyle(FrogButtonStyle())
    }

    @ViewBuilder private var origin: some View {
        switch review.source {
        case .folder(let path):
            Text("Built on this Mac in \((path as NSString).abbreviatingWithTildeInPath)").font(FrogType.small).foregroundStyle(FrogStyle.muted)
        case .link, .file:
            HStack(spacing: 6) {
                Text("From \(review.source.label)").font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1).truncationMode(.middle)
                if plugins.isListed(review.sha256) {
                    Label("Signed by the Frog directory", systemImage: "checkmark.seal").font(FrogType.small).foregroundStyle(FrogStyle.good)
                } else {
                    Label("Not in the Frog directory", systemImage: "exclamationmark.triangle").font(FrogType.small).foregroundStyle(FrogStyle.warning)
                }
            }
        }
    }

    private func permissionRow(_ permission: PluginPermission, new: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: permission.isSensitive ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(permission.isSensitive ? FrogStyle.warning : FrogStyle.muted).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title).font(FrogType.bodyMedium)
                    if new { FrogBadge(text: "New", active: true) }
                }
                Text(permission.detail).font(FrogType.small).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A plugin's page in Frog's window.
struct PluginPageView: View {
    @EnvironmentObject private var model: AppModel
    let id: String
    @State private var host: PluginWebHost?
    @State private var failure: String?

    var body: some View {
        let item = model.plugins.item(id)
        VStack(spacing: 0) {
            // The plugin's page has its own title, so this row only leads back and, while building, reloads.
            HStack(spacing: 8) {
                Button("Community plugins", systemImage: "chevron.left") { model.toolkit.select(.feature(.plugins)) }
                    .buttonStyle(.frog(.ghost))
                Spacer()
                if case .folder = item?.record.source {
                    IconAction(title: "Reload", symbol: "arrow.clockwise") { model.plugins.reload(id) }
                }
            }
            .frame(height: FrogStyle.controlHeight).padding(.horizontal, 20)
            .background { WindowDragRegion().accessibilityHidden(true) }
            if let host {
                PluginWebContainer(host: host)
                    .background(FeatureVisibility { shown in host.isShowing = shown; if shown { host.refreshTheme() } })
                    .onDisappear { host.isShowing = false }
            } else if let failure {
                FrogEmptyState(symbol: "exclamationmark.triangle", title: "This plugin cannot open", message: failure) {
                    Button("Open Community plugins") { model.toolkit.select(.feature(.plugins)) }
                }
                Spacer()
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: id) {
            do { host = try await model.plugins.host(for: id); failure = nil }
            catch { failure = error.localizedDescription }
        }
    }
}

/// Holds the plugin's web view, which outlives the page: a plugin keeps running while another page is shown.
struct PluginWebContainer: NSViewRepresentable {
    let host: PluginWebHost

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) { attach(to: container) }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        let webView = host.webView
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}

extension PluginManifestAction.Effect {
    /// How the review names what an action may do.
    var title: String {
        switch self {
        case .read: "Only reads"
        case .write: "Changes things"
        case .network: "Uses the network"
        }
    }
}
