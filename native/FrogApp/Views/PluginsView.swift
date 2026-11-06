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
    @State private var settings: PluginSettingsTarget?

    /// `tab` opens the page on another tab than Installed, for pictures of each tab.
    init(plugins: PluginRuntime, tab: PluginsTab = .installed) {
        self.plugins = plugins
        _tab = State(initialValue: tab)
    }

    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Community plugins", subtitle: "Each runs in its own sandbox, with only the access you approve.") {
                if let host = plugins.downloading {
                    FrogSpinner().help("Downloading from \(host)")
                }
                Button("Install from file…", systemImage: "square.and.arrow.down") { chooseFile() }
                    .help("Install a plugin file")
            }
            HStack(spacing: 8) {
                CompactSegments(values: PluginsTab.allCases, selected: tab, title: \.title) { tab = $0 }
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
        .sheet(item: $settings) { target in
            PluginSettingsSheet(id: target.id, plugins: plugins) { settings = nil }
        }
    }

    // MARK: Installed

    @ViewBuilder private var installed: some View {
        if plugins.items.isEmpty {
            FrogEmptyState(symbol: CommunityPlugin.info.symbol, title: "No plugins yet",
                           message: "Install one from the directory, or have your AI agent build one.", tint: CommunityPlugin.info.tint) {
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

    /// One installed plugin on one line of caption: what it does, truncated, with the version beside its name and
    /// the rest (the full description, its actions, where it came from) in the help and its menu.
    private func installedRow(_ item: PluginItem) -> some View {
        HStack(spacing: 12) {
            PluginIconTile(symbol: PluginSymbol.name(item.symbol), tint: PluginTint.purple.color)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L10n.text(item.name)).font(FrogType.row).foregroundStyle(FrogStyle.ink).lineLimit(1)
                    if let version = item.manifest?.version, !version.isEmpty {
                        Text(version).font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
                    }
                }
                Text(L10n.text(item.problem ?? item.manifest?.description ?? ""))
                    .font(FrogType.small).foregroundStyle(item.problem == nil ? FrogStyle.muted : FrogStyle.warning)
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(item.problem ?? caption(item))
            HStack(spacing: 8) {
                if item.needsReview {
                    Button("Review") {
                        do { try plugins.reviewInstalled(item.id) } catch { model.report(error) }
                    }.buttonStyle(.frog(.primary, compact: true))
                } else if item.problem == nil {
                    if plugins.running.contains(item.id) { FrogBadge(text: "Running") }
                    if item.runs, item.hasPage { Button("Open") { model.openPlugin(item.id) }.buttonStyle(.frog(compact: true)) }
                    Toggle("", isOn: Binding(get: { item.record.enabled }, set: { plugins.setEnabled(item.id, $0) }))
                        .toggleStyle(.frogSwitch).controlSize(.small).labelsHidden()
                        .accessibilityLabel("\(item.name) on")
                }
                IconMenu(title: "More about \(item.name)", bordered: false) {
                    Text(source(item))
                    if let actions = item.manifest?.actions.count, actions > 0 { Text(actions == 1 ? "1 action" : "\(actions) actions") }
                    if item.runs, item.hasSettings {
                        Button("Settings…", systemImage: "slider.horizontal.3") { settings = PluginSettingsTarget(id: item.id) }
                    }
                    Button("Remove…", systemImage: "trash", role: .destructive) { removing = item }
                }
            }.fixedSize()
        }
        .padding(.vertical, FrogStyle.space6)
        .frame(minHeight: FrogStyle.rowHeight)
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
                FrogEmptyState(symbol: CommunityPlugin.info.symbol, title: "The directory opens soon",
                               message: "No plugins yet. Frog only installs plugins signed by the directory.",
                               tint: CommunityPlugin.info.tint).frogTableSurface()
            } else if plugins.loadingRegistry, plugins.registry.isEmpty {
                FrogLoadingNote(text: "Loading the directory…").frame(maxWidth: .infinity).padding(.vertical, 36).frogTableSurface()
            } else if let error = plugins.registryError, plugins.registry.isEmpty {
                FrogEmptyState(symbol: "wifi.exclamationmark", title: "The directory did not load", message: error) {
                    Button("Try again") { Task { await plugins.loadRegistry() } }
                }.frogTableSurface()
            } else if plugins.registry.isEmpty {
                FrogEmptyState(symbol: CommunityPlugin.info.symbol, title: "Nothing listed yet",
                               message: "Plugins people share appear here once frog.beffa.xyz/plugins lists them.",
                               tint: CommunityPlugin.info.tint).frogTableSurface()
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
            PluginIconTile(symbol: PluginSymbol.name(entry.displaySymbol), tint: PluginTint.purple.color)
        } control: {
            if let installed, installed.record.sha256 == entry.sha256.lowercased() || !Self.isNewer(entry, than: installed) {
                FrogBadge(text: "Installed")
            } else if plugins.installing == entry.id {
                FrogSpinner().frame(width: 60)
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
            FrogRow("Ask your agent", caption: "Paste this prompt and finish the sentence.") {
                CopyAction(title: "Copy prompt") { ViewActions.copy(Self.prompt) }
            }
            // The prompt itself, set like code where it names a command, and without the backticks.
            Text(InlineCode.attributed(Self.prompt)).font(FrogType.body).foregroundStyle(FrogStyle.ink).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                .padding(FrogStyle.space10)
                .background(FrogStyle.control, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius, style: .continuous))
                .padding(.bottom, FrogStyle.space10)
            FrogRow("Let it use Frog", caption: "Settings → Agents installs the frog command and skill.") {
                Button("Open Settings") { model.toolkit.select(.settings) }.buttonStyle(.frog(compact: true))
            }
            FrogRow("Share it", caption: "Packs the plugin and prints its entry for the directory.") {
                FrogCodeChip(text: "frog plugin publish")
            }
        }
        FrogSection("Install from a link") {
            FrogRow("Link to a .frogplugin file", caption: "You review what it asks for before anything is installed.") {
                HStack(spacing: 6) {
                    FrogTextField(placeholder: "https://…", text: $link).textFieldStyle(.plain).font(FrogType.body)
                        .padding(.horizontal, 8).frame(width: 240).frogControlSurface()
                        .onSubmit(openTypedLink)
                    Button("Review", action: openTypedLink).buttonStyle(.frog(compact: true))
                        .frogDisabled(plugins.downloading != nil ? "Downloading…" : typedLink == nil ? "Paste a link to a .frogplugin file" : nil)
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
    /// Permission rows opened to their full explanation; each shows one line until clicked.
    @State private var expanded = Set<PluginPermission>()

    private var manifest: PluginManifest { review.package.manifest }

    var body: some View {
        let additions = review.additions
        let updating = review.approved != nil
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: FrogStyle.space12) {
                HStack(alignment: .center, spacing: FrogStyle.space12) {
                    PluginIconTile(symbol: PluginSymbol.name(manifest.displaySymbol), tint: PluginTint.purple.color, size: .header)
                    VStack(alignment: .leading, spacing: FrogStyle.space2) {
                        Text(updating ? "Update \(manifest.name)?" : "Install \(manifest.name)?").font(FrogType.title).tracking(-0.4)
                            .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                        Text("Version \(manifest.version)\(manifest.author.map { " · by \($0)" } ?? "")").font(FrogType.small).foregroundStyle(FrogStyle.muted)
                    }
                }
                origin
                Text(manifest.description).font(FrogType.body).fixedSize(horizontal: false, vertical: true)
                if let replacing = review.replacing {
                    InlineIssue(message: "You have \(manifest.name) from \(replacing.label). This one comes from \(review.source.label): it replaces that plugin and gets what it stored. Install it only if both come from the same author.")
                }
                if !review.compatible {
                    InlineIssue(message: "It needs Frog \(manifest.frog ?? "") or later. Update Frog first.")
                }
            }.padding([.horizontal, .top], FrogStyle.sheetPadding).padding(.bottom, FrogStyle.space16)
            ScrollView {
                VStack(alignment: .leading, spacing: FrogStyle.space16) {
                    if manifest.permissions.isEmpty {
                        FrogSection("Permissions") {
                            FrogRow("Nothing beyond its own page", caption: "It shows its page, keeps its own storage and receives its commands.", icon: {
                                permissionIcon("checkmark.shield")
                            }, control: { EmptyView() })
                        }
                    } else {
                        let sensitive = manifest.permissions.filter(\.isSensitive).count
                        FrogSection(updating && additions.isEmpty ? "It asks for nothing new" : "It asks to",
                                    footer: sensitive == 0 ? nil : "Caution marks what can read or send your data, or act for you. Click a row for details.") {
                            ForEach(manifest.permissions, id: \.self) { permission in
                                permissionRow(permission, new: updating && additions.permissions.contains(permission))
                            }
                        }
                    }
                    if !manifest.actions.isEmpty {
                        FrogSection("Actions you and your agents can run") {
                            ForEach(manifest.actions, id: \.id) { action in
                                FrogRow(action.title, icon: { EmptyView() }, control: {
                                    HStack(spacing: FrogStyle.space8) {
                                        if let shortcut = action.shortcut, let parsed = try? Shortcut(shortcut) {
                                            ShortcutBadge(text: HotkeyManager.display(parsed.hotkey))
                                        }
                                        effectLabel(action.effect)
                                    }
                                })
                            }
                        }
                    }
                    if !manifest.uses.isEmpty {
                        FrogSection("Frog actions it can run") {
                            ForEach(manifest.uses, id: \.self) { pattern in
                                listRow(pattern, badge: updating && additions.uses.contains(pattern) ? "New" : nil)
                            }
                        }
                    }
                    if !manifest.hosts.isEmpty {
                        FrogSection("Sites it can reach") {
                            ForEach(manifest.hosts, id: \.self) { host in
                                listRow(host, badge: updating && additions.hosts.contains(host) ? "New" : nil)
                            }
                        }
                    }
                    if !manifest.scripts.isEmpty {
                        FrogSection("Scripts it can run") {
                            ForEach(manifest.scripts.keys.sorted(), id: \.self) { name in
                                DisclosureGroup {
                                    ScrollView {
                                        Text((try? review.package.scriptText(name)) ?? "The script could not be read.")
                                            .font(FrogType.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }.frame(maxHeight: 160).padding(8).background(FrogStyle.control, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
                                        .padding(.bottom, FrogStyle.space8)
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(name).font(FrogType.mono)
                                        if updating, additions.scripts.contains(name) { FrogBadge(text: "Changed", active: true) }
                                    }.frame(minHeight: FrogStyle.rowHeight)
                                }
                            }
                            if updating, additions.scripts.contains(PluginGrant.filesKey) {
                                FrogRowNote(text: "Its files changed, and its scripts can run any of them.", tone: FrogStyle.warning)
                            }
                        }
                    }
                }
                .padding(.horizontal, FrogStyle.sheetPadding).padding(.bottom, FrogStyle.space4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 440).fixedSize(horizontal: false, vertical: true).bottomScrollFade()
            FrogSheetButtons {
                Text("\(review.package.files.count) files · \(ByteCountFormatter.string(fromByteCount: Int64(review.package.size), countStyle: .file))")
                    .font(FrogType.caption).foregroundStyle(FrogStyle.muted)
            } trailing: {
                FrogCancelButton(review.installed ? "Not now" : "Cancel") { plugins.dismissReview() }
                // It looks ready at once; a click in its first second after the sheet changes is ignored, so a click
                // meant for something else cannot approve it.
                Button(review.installed ? "Allow" : updating ? "Update" : "Install") {
                    guard armed else { return }
                    do { try plugins.approve(review) } catch { report(error); plugins.dismissReview() }
                }.buttonStyle(.frog(.primary)).frogDisabled(review.compatible ? nil : "Update Frog first")
            }
        }
        .task(id: review.id) {
            armed = false
            try? await Task.sleep(for: .seconds(1))
            armed = true
        }
        .frame(width: 500)
        .font(FrogType.body).foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).buttonStyle(FrogButtonStyle())
    }

    @ViewBuilder private var origin: some View {
        switch review.source {
        case .folder(let path):
            let shown = (path as NSString).abbreviatingWithTildeInPath
            Label { Text("Built on this Mac").foregroundStyle(FrogStyle.ink) + Text(" · \(shown)") } icon: { Image(systemName: "hammer") }
                .font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1).truncationMode(.middle).help(shown)
        case .link, .file:
            VStack(alignment: .leading, spacing: FrogStyle.space4) {
                if plugins.isListed(review.sha256) {
                    Label("Signed by the Frog directory", systemImage: "checkmark.seal.fill").font(FrogType.small).foregroundStyle(FrogStyle.good)
                } else {
                    Label("Not in the Frog directory", systemImage: "exclamationmark.triangle.fill").font(FrogType.small).foregroundStyle(FrogStyle.warning)
                }
                Text("From \(review.source.label)").font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1).truncationMode(.middle)
                    .help(review.source.label)
            }
        }
    }

    private func permissionIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 13, weight: .medium))
            .foregroundStyle(FrogStyle.ink.opacity(0.75))
            .frame(width: 28, height: 28).background(FrogStyle.control, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius - 2, style: .continuous))
            .accessibilityHidden(true)
    }

    private func permissionRow(_ permission: PluginPermission, new: Bool) -> some View {
        PluginPermissionRow(permission: permission, new: new, expanded: expanded.contains(permission)) {
            if expanded.contains(permission) { expanded.remove(permission) } else { expanded.insert(permission) }
        } icon: { permissionIcon(permission.symbol) }
    }

    private func listRow(_ text: String, badge: String?) -> some View {
        HStack(spacing: FrogStyle.space6) {
            Text(text).font(FrogType.mono).textSelection(.enabled)
            if let badge { FrogBadge(text: badge, active: true) }
            Spacer(minLength: 0)
        }.frame(minHeight: 32)
    }

    private func effectLabel(_ effect: PluginManifestAction.Effect) -> some View {
        Label(effect.title, systemImage: effect.symbol).font(FrogType.small)
            .foregroundStyle(effect == .read ? FrogStyle.muted : FrogStyle.ink)
            .help(effect.explanation)
    }
}

/// One permission on one line: its symbol, its title with a Caution or New badge beside it, and the start of its
/// explanation. A click opens the whole explanation; the pointer shows it as a tooltip.
private struct PluginPermissionRow<Icon: View>: View {
    let permission: PluginPermission
    let new: Bool
    let expanded: Bool
    let toggle: () -> Void
    @ViewBuilder var icon: Icon
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: expanded ? .top : .center, spacing: FrogStyle.space12) {
                icon
                VStack(alignment: .leading, spacing: FrogStyle.space2) {
                    HStack(spacing: FrogStyle.space6) {
                        Text(permission.title).font(FrogType.row).foregroundStyle(FrogStyle.ink)
                        if permission.isSensitive { PluginCautionBadge() }
                        if new { FrogBadge(text: "New", active: true) }
                    }
                    Text(permission.detail).font(FrogType.small).foregroundStyle(FrogStyle.muted)
                        .lineLimit(expanded ? nil : 1).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: expanded)
                }
                Spacer(minLength: FrogStyle.space8)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle((hovering || expanded ? FrogStyle.muted : FrogStyle.placeholder))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(height: 28)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, FrogStyle.space6).frame(minHeight: FrogStyle.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .help(expanded ? "" : permission.detail)
        .animation(FrogMotion.reveal, value: expanded)
        .accessibilityElement(children: .combine)
        .accessibilityHint(expanded ? "" : permission.detail)
    }
}

/// "Caution" beside a permission that can read or send the user's data, or act for them: the warning colour in a
/// capsule, like every other badge.
private struct PluginCautionBadge: View {
    var body: some View {
        Label { Text("Caution") } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            .labelStyle(PluginBadgeLabelStyle())
            .font(FrogType.caption.weight(.semibold)).foregroundStyle(FrogStyle.warning)
            .padding(.horizontal, FrogStyle.space6).padding(.vertical, 3)
            .background(FrogStyle.warning.opacity(0.14), in: Capsule(style: .continuous))
    }
}

private struct PluginBadgeLabelStyle: LabelStyle {
    func makeBody(configuration: LabelStyleConfiguration) -> some View {
        HStack(spacing: FrogStyle.space2) { configuration.icon.font(.system(size: 8, weight: .bold)); configuration.title }
    }
}

extension PluginPermission {
    /// A neutral symbol for what the permission reaches; the review adds a caution mark to the sensitive ones.
    var symbol: String {
        switch self {
        case .clipboardRead: "doc.on.clipboard"
        case .clipboardWrite: "clipboard"
        case .selection: "character.cursor.ibeam"
        case .notifications: "bell"
        case .links: "link"
        case .menubar: "menubar.rectangle"
        case .hotkeys: "command"
        case .background: "clock.arrow.circlepath"
        case .files: "folder"
        case .network: "network"
        case .ai: "sparkles"
        case .frogActions: "bolt"
        case .scripts: "terminal"
        }
    }
}

/// A plugin's page in Frog's window.
struct PluginPageView: View {
    @EnvironmentObject private var model: AppModel
    let id: String
    @State private var host: PluginWebHost?
    @State private var failure: String?
    @State private var settings: PluginSettingsTarget?

    var body: some View {
        let item = model.plugins.item(id)
        VStack(spacing: 0) {
            // The toolbar leads back ("Community plugins › Name"); this row only holds the page's own actions.
            let reloads: Bool = { if case .folder = item?.record.source { return true }; return false }()
            if reloads || item?.hasSettings == true {
                HStack(spacing: FrogStyle.space8) {
                    Spacer()
                    if reloads {
                        IconAction(title: "Reload", symbol: "arrow.clockwise") { model.plugins.reload(id) }
                    }
                    if item?.hasSettings == true {
                        IconAction(title: "Settings", symbol: "slider.horizontal.3") { settings = PluginSettingsTarget(id: id) }
                    }
                }
                .frame(height: FrogStyle.controlHeight).padding(.horizontal, FrogStyle.pagePadding)
            }
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
                FrogSpinner(label: "Opening the plugin").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frogPageBack("plugin-page-\(id)", parent: "Community plugins") { model.toolkit.select(.feature(.plugins)) }
        .task(id: id) {
            do { host = try await model.plugins.host(for: id); failure = nil }
            catch { failure = error.localizedDescription }
        }
        .sheet(item: $settings) { target in
            PluginSettingsSheet(id: target.id, plugins: model.plugins) { settings = nil }
        }
    }
}

/// The plugin whose settings sheet is open.
struct PluginSettingsTarget: Identifiable { let id: String }

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
        case .read: "Reads only"
        case .write: "Can change data"
        case .network: "Uses the internet"
        }
    }

    var symbol: String {
        switch self {
        case .read: "eye"
        case .write: "pencil"
        case .network: "network"
        }
    }

    /// What the effect lets an action do, under the pointer.
    var explanation: String {
        switch self {
        case .read: "Reads its storage or, with permission, the clipboard. Changes nothing."
        case .write: "Can change its storage, the clipboard, show a notification, run a script or open a link, as its permissions allow."
        case .network: "Can also reach the sites it lists or your AI model, as its permissions allow."
        }
    }
}
