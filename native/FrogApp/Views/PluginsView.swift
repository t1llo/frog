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

/// The Plugins feature's page: what is installed, the directory at frog.beffa.xyz, and how to build one.
struct PluginsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var plugins: PluginRuntime
    @State private var tab = PluginsTab.installed
    @State private var link = ""
    @State private var removing: PluginItem?

    var body: some View {
        PageScroll {
            PageHeader(title: "Plugins", subtitle: "Features you build with your AI agent or install from others. Each runs in its own sandbox and can do only what you approve.") {
                IconAction(title: "Install a plugin file", symbol: "square.and.arrow.down") { chooseFile() }
            }
            HStack(spacing: 4) {
                ForEach(PluginsTab.allCases) { item in FilterTag(title: item.title, selected: item == tab) { tab = item } }
                Spacer()
                if let host = plugins.downloading {
                    ProgressView().controlSize(.small)
                    Text("Downloading from \(host)…").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
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
                           message: "Ask your AI agent to build one, or install one from the directory.")
            HStack(spacing: 8) {
                Button("Build your own") { tab = .build }
                Button("Open the directory") { tab = .browse }
            }.frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 8) {
                ForEach(plugins.items) { item in installedRow(item) }
            }
        }
    }

    private func installedRow(_ item: PluginItem) -> some View {
        FrogCard {
            HStack(alignment: .top, spacing: 12) {
                SymbolTile(symbol: PluginSymbol.name(item.symbol), size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.name).font(.system(size: 13, weight: .medium))
                        if let version = item.manifest?.version { Text(version).font(.system(size: 11)).foregroundStyle(FrogStyle.muted) }
                        if item.needsReview { FrogBadge(text: "Needs review", active: true) }
                        else if !item.record.enabled { FrogBadge(text: "Off") }
                        else if plugins.running.contains(item.id) { FrogBadge(text: "Running") }
                    }
                    if let description = item.manifest?.description {
                        Text(description).font(.system(size: 12)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    if let problem = item.problem {
                        Text(problem).font(.system(size: 11)).foregroundStyle(FrogStyle.critical).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(sourceLine(item)).font(.system(size: 10)).foregroundStyle(FrogStyle.muted).lineLimit(1).truncationMode(.middle)
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if item.needsReview {
                        Button("Review") {
                            do { try plugins.reviewInstalled(item.id) } catch { model.report(error) }
                        }.buttonStyle(FrogButtonStyle(primary: true))
                    } else if item.problem == nil {
                        if item.runs, item.hasPage { Button("Open") { model.openPlugin(item.id) } }
                        Toggle("", isOn: Binding(get: { item.record.enabled }, set: { plugins.setEnabled(item.id, $0) }))
                            .toggleStyle(.switch).controlSize(.small).labelsHidden()
                            .accessibilityLabel("\(item.name) on")
                    }
                    IconAction(title: "Remove \(item.name)", symbol: "trash", destructive: false) { removing = item }
                }
            }
        }
    }

    private func sourceLine(_ item: PluginItem) -> String {
        switch item.record.source {
        case .folder: "Built on this Mac · \(item.record.source.label)"
        case .link: "From \(item.record.source.label)"
        case .file: "From \(item.record.source.label)"
        }
    }

    // MARK: Directory

    @ViewBuilder private var directory: some View {
        if plugins.loadingListings && plugins.listings.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
        } else if let error = plugins.listingsError, plugins.listings.isEmpty {
            InlineIssue(message: error)
            Button("Try again") { Task { await plugins.loadListings() } }
        } else if plugins.listings.isEmpty {
            FrogEmptyState(symbol: "square.grid.2x2", title: "The directory is empty so far",
                           message: "Plugins people share appear here once they are listed on frog.beffa.xyz/plugins.")
        } else {
            VStack(spacing: 8) { ForEach(plugins.listings) { listingRow($0) } }
        }
        Text("Every plugin listed was read before it was added, and the file you install must match the one that was read. A listed plugin still runs only with the access you approve.")
            .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
            .task { if plugins.listings.isEmpty { await plugins.loadListings() } }
    }

    private func listingRow(_ listing: PluginListing) -> some View {
        let installed = plugins.item(listing.id)
        return FrogCard {
            HStack(alignment: .top, spacing: 12) {
                SymbolTile(symbol: PluginSymbol.name(listing.symbol ?? PluginManifest.defaultSymbol), size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(listing.name).font(.system(size: 13, weight: .medium))
                        Text(listing.version).font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                    }
                    Text("By \(listing.author)").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                    Text(listing.description).font(.system(size: 12)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
                    Text(listing.permissions.isEmpty ? "Asks for no permissions" : "Asks to: " + listing.permissions.compactMap { PluginPermission(rawValue: $0)?.title.lowercased() }.joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if installed?.record.sha256 == listing.sha256.lowercased() {
                    FrogBadge(text: "Installed")
                } else if let url = listing.downloadURL {
                    Button(installed == nil ? "Install" : "Update") { open(url, sha256: listing.sha256) }
                        .disabled(plugins.downloading != nil)
                }
            }
        }
    }

    // MARK: Build

    private static let prompt = "Build me a Frog plugin that … Run `frog plugins guide` first and follow it."

    @ViewBuilder private var build: some View {
        FrogCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Build a plugin with your AI agent").font(.system(size: 13, weight: .medium))
                Text("A plugin is a small web page with a plugin.json: it gets a page in this sidebar, rows in the command bar, its own storage, and only the access you approve. Your agent reads the guide, writes the files, installs the plugin here and looks at a picture of it, until it does what you asked.")
                    .font(.system(size: 12)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
                step(1, "Turn on AI agents in Features, so your agent can use the frog command.")
                step(2, "Ask your agent, for example:")
                HStack {
                    Text(Self.prompt).font(FrogType.mono).textSelection(.enabled)
                    Spacer(minLength: 8)
                    IconAction(title: "Copy", symbol: "doc.on.doc") { ViewActions.copy(Self.prompt) }
                }.padding(10).background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
                step(3, "Review it here when it asks for access the first time. Updates that ask for nothing new run at once.")
                step(4, "To share it, ask your agent to pack it: `frog plugins pack` makes a .frogplugin file anyone can install.")
            }
        }
        FrogCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Install from a link").font(.system(size: 13, weight: .medium))
                Text("Paste an https link to a .frogplugin file. You review what it asks for before anything is installed.")
                    .font(.system(size: 12)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("https://…/plugin.frogplugin", text: $link).textFieldStyle(.plain).padding(8)
                        .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
                        .onSubmit(openTypedLink)
                    Button("Review", action: openTypedLink).disabled(URL(string: link.trimmingCharacters(in: .whitespaces))?.scheme != "https" || plugins.downloading != nil)
                }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)").font(.system(size: 11, weight: .semibold)).foregroundStyle(FrogStyle.muted).frame(width: 14)
            Text(.init(text)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func openTypedLink() {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespaces)), url.scheme == "https" else { return }
        open(url, sha256: nil)
    }

    private func open(_ url: URL, sha256: String?) {
        Task {
            do { try await plugins.openLink(url, sha256: sha256); link = "" } catch { model.report(error) }
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

    private var manifest: PluginManifest { review.package.manifest }

    var body: some View {
        let additions = review.additions
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                SymbolTile(symbol: PluginSymbol.name(manifest.displaySymbol), size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(review.approved == nil ? "Install \(manifest.name)?" : "Update \(manifest.name)?").font(.system(size: 15, weight: .semibold))
                    Text("Version \(manifest.version)\(manifest.author.map { " · by \($0)" } ?? "")").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                    origin
                }
            }
            Text(manifest.description).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            if !review.compatible {
                InlineIssue(message: "It needs Frog \(manifest.frog ?? "") or later. Update Frog first.")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if manifest.permissions.isEmpty {
                        Text("It asks for no permissions: it shows its page, keeps its own storage and receives its commands.")
                            .font(.system(size: 12)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
                    } else {
                        SectionCaption(text: review.approved != nil && additions.permissions.isEmpty && additions.hosts.isEmpty && additions.scripts.isEmpty
                                       ? "It asks for nothing new" : "It asks to")
                        ForEach(manifest.permissions, id: \.self) { permission in
                            permissionRow(permission, new: review.approved != nil && additions.permissions.contains(permission))
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
                                }.frame(maxHeight: 160).padding(8).background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
                            } label: {
                                HStack(spacing: 6) {
                                    Text(name).font(FrogType.mono)
                                    if review.approved != nil, additions.scripts.contains(name) { FrogBadge(text: "Changed", active: true) }
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 320).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("\(review.package.files.count) files · \(ByteCountFormatter.string(fromByteCount: Int64(review.package.size), countStyle: .file))")
                    .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                Spacer()
                Button(review.installed ? "Not now" : "Cancel") { plugins.dismissReview() }.keyboardShortcut(.cancelAction)
                Button(review.installed ? "Allow" : review.approved == nil ? "Install" : "Update") {
                    do { try plugins.approve(review) } catch { report(error); plugins.dismissReview() }
                }.buttonStyle(FrogButtonStyle(primary: true)).disabled(!review.compatible)
            }
        }
        .padding(20).frame(width: 480)
        .font(.system(size: 13)).foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).buttonStyle(FrogButtonStyle())
    }

    @ViewBuilder private var origin: some View {
        switch review.source {
        case .folder(let path):
            Text("Built on this Mac in \((path as NSString).abbreviatingWithTildeInPath)").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
        case .link, .file:
            HStack(spacing: 6) {
                Text("From \(review.source.label)").font(.system(size: 11)).foregroundStyle(FrogStyle.muted).lineLimit(1).truncationMode(.middle)
                if review.listed {
                    Label("Listed in the Frog directory", systemImage: "checkmark.seal").font(.system(size: 11)).foregroundStyle(FrogStyle.good)
                } else {
                    Label("Not in the Frog directory", systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(FrogStyle.warning)
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
                    Text(permission.title).font(.system(size: 12, weight: .medium))
                    if new { FrogBadge(text: "New", active: true) }
                }
                Text(permission.detail).font(.system(size: 11)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
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
            HStack(spacing: 8) {
                Image(systemName: PluginSymbol.name(item?.symbol ?? PluginManifest.defaultSymbol)).foregroundStyle(FrogStyle.muted)
                Text(item?.name ?? id).font(.system(size: 13, weight: .medium))
                Spacer()
                if case .folder = item?.record.source {
                    IconAction(title: "Reload", symbol: "arrow.clockwise") { model.plugins.reload(id) }
                }
                IconAction(title: "Plugins", symbol: "puzzlepiece.extension") { model.toolkit.select(.feature(.plugins)) }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
            .overlay { WindowDragRegion().accessibilityHidden(true).allowsHitTesting(false) }
            Rectangle().fill(FrogStyle.border.opacity(0.6)).frame(height: 1)
            if let host {
                PluginWebContainer(host: host)
                    .background(FeatureVisibility { shown in host.isShowing = shown; if shown { host.refreshTheme() } })
                    .onDisappear { host.isShowing = false }
            } else if let failure {
                FrogEmptyState(symbol: "exclamationmark.triangle", title: "This plugin cannot open", message: failure)
                Button("Open Plugins") { model.toolkit.select(.feature(.plugins)) }
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
