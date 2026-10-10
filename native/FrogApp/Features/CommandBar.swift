import AppKit
import Combine
import FrogCore
import SwiftUI

@MainActor final class CommandBar: ObservableObject {
    @Published var query = "" { didSet { removeFiles(); updateResults() } }
    @Published private(set) var results: [SearchRecord] = []
    @Published var selection = 0
    var onToolUse: ((ActivityToolKind) -> Void)?
    private weak var model: AppModel?
    private var records: [SearchRecord] = []
    private var recordIDs = Set<String>()
    private var actions: [String: () async throws -> Void] = [:]
    private var copyActions: [String: () async throws -> Void] = [:]
    private var sourceObservation: AnyCancellable?
    private let windows = WindowCatalog()
    private var panel: NSPanel?
    private var monitor: Any?
    private var outside: Any?
    private var activation: NSObjectProtocol?
    private var indexing: Task<Void, Never>?
    private var windowIndexing: Task<Void, Never>?
    private var warming: Task<Void, Never>?
    private var cachedApplications: [Rule] = []
    private var applicationRecords: [String: SearchRecord] = [:]
    private var cachedWindows: [SwitcherWindow] = []
    private var icons: [String: NSImage] = [:]
    @Published private(set) var invocation = UUID()
    private var delivery: Task<Void, Never>?
    private var generation = UUID()
    private var fileQuery: NSMetadataQuery?
    private var fileObserver: NSObjectProtocol?
    private var fileRevision = 0
    private var fileDelay: Task<Void, Never>?
    private let pasteboard: NSPasteboard
    private let loadApplications: @MainActor () async -> [Rule]
    private let fileScopes: [Any]
    private let captureTarget: @MainActor () -> (any ClipboardHistoryPasteTarget)?
    private let waitForRelease: () async throws -> Void

    init(model: AppModel, pasteboard: NSPasteboard = .general, fileScopes: [Any]? = nil,
         captureTarget: @escaping @MainActor () -> (any ClipboardHistoryPasteTarget)? = { NativeClipboardHistoryPasteTarget.capture() },
         waitForRelease: @escaping () async throws -> Void = { try await ClipboardSelection.waitForShortcutRelease() },
         loadApplications: @escaping @MainActor () async -> [Rule] = {
             await ApplicationCatalogStore.shared.loadIfNeeded(); return ApplicationCatalogStore.shared.installed
         }) {
        self.model = model; self.pasteboard = pasteboard; self.loadApplications = loadApplications
        self.captureTarget = captureTarget; self.waitForRelease = waitForRelease
        self.fileScopes = fileScopes ?? [NSMetadataQueryUserHomeScope, NSMetadataQueryLocalComputerScope]
    }
    func warm() {
        guard warming == nil, model?.configuration.preferences.featureEnabled(.commandBar) == true else { return }
        preparePanel()
        warming = Task { [weak self] in
            guard let self else { return }
            let installed = await self.loadApplications()
            guard !Task.isCancelled else { return }
            self.cacheApplications(installed)
            self.warming = nil
        }
    }
    func stop() {
        hide(); warming?.cancel(); warming = nil
        cachedApplications = []; applicationRecords = [:]; cachedWindows = []; icons = [:]
        panel?.contentView = nil; panel = nil
    }
    private func cacheApplications(_ installed: [Rule]) {
        guard installed != cachedApplications else { return }
        cachedApplications = installed
        applicationRecords = [:]
        for rule in installed {
            guard let path = rule.action?.applicationPath else { continue }
            applicationRecords[path] = SearchRecord(id: "app:\(path)", title: rule.name, subtitle: "Application", keywords: "app open launch \(rule.action?.applicationBundleID ?? "")", symbol: "app")
        }
    }
    func icon(for result: SearchRecord) -> NSImage? {
        if let cached = icons[result.id] { return cached }
        guard result.id.hasPrefix("app:") else { return nil }
        let image = NSWorkspace.shared.icon(forFile: String(result.id.dropFirst(4)))
        icons[result.id] = image
        return image
    }
    private func addApplications(_ installed: [Rule]) {
        for rule in installed {
            guard let path = rule.action?.applicationPath else { continue }
            guard let record = applicationRecords[path] else { continue }
            add(record) { [weak self] in
                try await ApplicationLauncher().launch(rule)
                try Task.checkCancellation()
                self?.onToolUse?(.applicationCommand)
            }
        }
    }
    private func addWindows(_ items: [SwitcherWindow]) {
        for item in items {
            icons["window:\(item.id)"] = NSRunningApplication(processIdentifier: item.pid)?.icon
            add(SearchRecord(id: "window:\(item.id)", title: item.title, subtitle: item.appName, keywords: "window switch", symbol: "macwindow")) { [weak self] in
                guard let self else { return }
                try Task.checkCancellation()
                guard let app = NSRunningApplication(processIdentifier: item.pid), !app.isTerminated else {
                    throw FrogError.message("That window is no longer available.")
                }
                if app.isHidden { app.unhide() }
                let activated = await WindowActivation.perform(
                    raise: { await self.windows.raise(id: item.id) },
                    request: { app.activate(options: []) },
                    bringForward: { await self.windows.bringApplicationForward(id: item.id) },
                    isFrontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier == item.pid })
                try Task.checkCancellation()
                guard activated else { throw FrogError.message("Could not bring that window to the front. Try again.") }
                self.onToolUse?(.windowCommand)
            }
        }
    }
    private func preparePanel() {
        guard panel == nil else { return }
        let created = CommandBarPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: 600, height: 390)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        created.title = "Frog command bar"; created.isReleasedWhenClosed = false; created.isRestorable = false
        created.isOpaque = false; created.backgroundColor = .clear; created.hasShadow = true
        created.level = .floating; created.hidesOnDeactivate = false
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        created.center()
        let host = NSHostingView(rootView: CommandBarView(bar: self))
        host.sizingOptions = []; created.contentView = host; panel = created
        host.layoutSubtreeIfNeeded()
    }
    func show() {
        guard let model, model.configuration.preferences.featureEnabled(.commandBar) else { return }
        if panel?.isVisible == true { hide(); return }
        hide()
        let target = captureTarget(), frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        records = []; recordIDs = []; actions = [:]; copyActions = [:]; query = ""; selection = 0
        addApplications(cachedApplications)
        if model.configuration.preferences.featureEnabled(.windowSwitcher) { addWindows(cachedWindows) }
        addRoutes(model, target: target, frontPID: frontPID)
        // Clear/disable/eviction invalidates previews as well as pending insertion.
        sourceObservation = model.clipboardHistoryStore.$entries.dropFirst().sink { [weak self] _ in self?.hide() }
        preparePanel()
        guard let panel else { return }
        invocation = UUID()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type != .keyDown { if event.window !== self.panel { self.hide() }; return false }
                guard event.window === self.panel else { return false }
                switch event.keyCode {
                case 53: self.hide(); return true
                case 125: self.selection = min(max(0, self.results.count - 1), self.selection + 1); return true
                case 126: self.selection = max(0, self.selection - 1); return true
                case 36, 76: self.choose(copyOnly: event.modifierFlags.contains(.command)); return true
                default: return false
                }
            }
            return consumed ? nil : event
        }
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.hide()
            }
        }
        // Retain the user's drag position; recover if its display was disconnected.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.contains(panel.frame) }) { panel.center() }
        panel.makeKeyAndOrderFront(nil)
        let token = generation
        let applications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map {
            SwitcherApplication(pid: $0.processIdentifier, name: $0.localizedName ?? "Application", hidden: $0.isHidden)
        }
        indexing = Task { [weak self, weak model] in
            guard let self, let model else { return }
            let installed = await self.loadApplications()
            guard self.generation == token, !Task.isCancelled else { return }
            self.cacheApplications(installed)
            self.addApplications(installed)
            self.updateResults()
            if [.snippets, .scratchpad, .shelf, .scripts].contains(where: { model.configuration.preferences.featureEnabled($0) }) {
                await model.documents.load()
                guard self.generation == token, !Task.isCancelled else { return }
                for item in model.documents.items {
                    if item.kind == .snippet, model.configuration.preferences.featureEnabled(.snippets) {
                        let deliver: (Bool) async throws -> Void = { [weak self, weak model] paste in
                            guard let self, let model, model.configuration.preferences.featureEnabled(.snippets),
                                  let current = model.documents.items.first(where: { $0.id == item.id }) else { return }
                            let text = SnippetExpansion.expand(current.text, clipboard: self.pasteboard.string(forType: .string) ?? "")
                            let sensitive = current.text.contains("{{clipboard}}") && self.pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true
                            let entry = ClipboardHistoryEntry(text: text, isSensitive: sensitive)
                            if paste {
                                try await ClipboardHistoryDelivery.paste(entry, plainText: true, pasteboard: self.pasteboard, target: target,
                                    isCurrent: { model.configuration.preferences.featureEnabled(.snippets) && model.documents.items.contains(where: { $0.id == item.id }) }, waitForRelease: self.waitForRelease)
                            } else {
                                guard entry.write(to: self.pasteboard, plainText: true) else { throw FrogError.message("Could not copy the snippet.") }
                            }
                            self.onToolUse?(.snippetCopy)
                        }
                        self.add(SearchRecord(id: "snippet:\(item.id)", title: item.title, subtitle: "Snippet · Paste · ⌘↩ Copy", symbol: "text.badge.plus"), copy: { try await deliver(false) }) { try await deliver(true) }
                    } else if item.kind == .note, model.configuration.preferences.featureEnabled(.scratchpad) {
                        self.add(SearchRecord(id: "note:\(item.id)", title: item.title, subtitle: "Notes", keywords: String(item.text.prefix(512)), symbol: "note.text")) { [weak model] in model?.openDocument(item) }
                    } else if item.kind == .shelf, model.configuration.preferences.featureEnabled(.shelf) {
                        self.add(SearchRecord(id: "shelf:\(item.id)", title: item.title, subtitle: "Shelf", symbol: "tray")) { [weak model] in model?.openDocument(item) }
                    } else if item.kind == .script, model.configuration.preferences.featureEnabled(.scripts) {
                        self.add(SearchRecord(id: "script:\(item.id)", title: item.title, subtitle: "Run saved script", symbol: "terminal")) { [weak model] in
                            model?.openDocument(item); model?.runScript(item)
                        }
                    }
                }
            }
            self.updateResults()
        }
        if model.configuration.preferences.featureEnabled(.windowSwitcher) {
            windowIndexing = Task { [weak self] in
                guard let self else { return }
                let snapshot = await self.windows.snapshot(applications: applications, frontPID: frontPID)
                guard self.generation == token, !Task.isCancelled, snapshot.isPublishable else { return }
                self.cachedWindows = snapshot.windows
                self.records.removeAll { $0.id.hasPrefix("window:") }
                self.recordIDs = Set(self.records.map(\.id))
                self.actions = self.actions.filter { !$0.key.hasPrefix("window:") }
                self.addWindows(snapshot.windows)
                self.updateResults()
            }
        }
    }
    private func addRoutes(_ model: AppModel, target: (any ClipboardHistoryPasteTarget)?, frontPID: pid_t?) {
        for feature in model.configuration.preferences.sidebarFeatures {
            add(SearchRecord(id: "feature:\(feature.rawValue)", title: feature.title, subtitle: "Frog", keywords: "frog command \(feature.detail)", symbol: feature.symbol)) { [weak model] in
                model?.openFeature(feature)
            }
        }
        add(SearchRecord(id: "features", title: "Manage features", subtitle: "Enable the tools you use", symbol: "square.grid.2x2")) { [weak model] in
            model?.toolkit.select(.features); model?.showSettings()
        }
        for (route, title, symbol) in [(ToolkitRoute.settings, "Settings", "gearshape"), (.models, "Models", "cpu"), (.history, "History", "clock.arrow.circlepath")] {
            add(SearchRecord(id: "route:\(title)", title: title, subtitle: "Frog", keywords: "frog preferences configuration", symbol: symbol)) { [weak model] in
                model?.toolkit.select(route); model?.showSettings()
            }
        }
        for rule in model.configuration.rules where rule.enabled && model.ruleFeatureEnabled(rule) {
            add(SearchRecord(id: "rule:\(rule.id)", title: rule.name, subtitle: "Run \(rule.category.title.lowercased()) rule", symbol: rule.category == .audio ? "waveform" : "command")) { [weak model] in
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID else { throw FrogError.message("The target application changed. Open the command bar again.") }
                model?.runRuleFromCommandBar(rule.id)
            }
        }
        if model.configuration.preferences.featureEnabled(.windowSwitcher) {
            for action in WindowAction.allCases {
                add(SearchRecord(id: "layout:\(action.rawValue)", title: action.title, subtitle: "Arrange front window", keywords: "window layout", symbol: "macwindow")) { [weak model] in
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID else { throw FrogError.message("The target application changed. Open the command bar again.") }
                    model?.runWindowAction(action)
                }
            }
        }
        if model.configuration.preferences.featureEnabled(.applicationShortcuts) {
            for action in SystemAction.allCases {
                add(SearchRecord(id: "system:\(action.rawValue)", title: action.title, subtitle: "Mac action", keywords: "frog command shortcut", symbol: action.symbol)) { [weak model] in
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID else { throw FrogError.message("The target application changed. Open the command bar again.") }
                    model?.runSystemAction(action)
                }
            }
        }
        if model.configuration.preferences.featureEnabled(.quickActions) {
            add(SearchRecord(id: "quick:uuid", title: "Generate UUID", subtitle: "Copy a new UUID", symbol: "number")) { [weak self] in self?.copy(UUID().uuidString) }
            add(SearchRecord(id: "quick:url", title: "Clean clipboard URL", subtitle: "Remove tracking parameters and copy", symbol: "link")) { [weak self] in
                guard let self, let cleaned = LinkCleaning.clean(self.pasteboard.string(forType: .string) ?? "") else { throw FrogError.message("Copy an HTTP or HTTPS URL first.") }
                self.copy(cleaned)
            }
        }
        for (symbol, words) in [("😀", "grinning smile happy"), ("🙂", "slightly smiling happy"), ("😂", "laugh tears joy"), ("❤️", "red heart love"),
                                ("👍", "thumbs up yes"), ("👎", "thumbs down no"), ("🎉", "party celebrate"), ("✅", "check done yes"),
                                ("❌", "cross no cancel"), ("🚀", "rocket launch"), ("🔥", "fire hot"), ("🐸", "frog"), ("🙏", "thank you please"),
                                ("🤔", "thinking"), ("👀", "eyes look"), ("✨", "sparkles"), ("💡", "idea bulb"), ("📌", "pin"), ("☕️", "coffee"), ("💻", "computer laptop")] {
            add(SearchRecord(id: "emoji:\(symbol)", title: "\(symbol)  \(words.capitalized)", subtitle: "Emoji · Copy", keywords: "emoji \(words)", symbol: "face.smiling")) { [weak self] in self?.copy(symbol) }
        }
        if model.configuration.preferences.featureEnabled(.clipboard) {
            for entry in model.clipboardHistoryStore.entries where !entry.isSensitive {
                let copy: () async throws -> Void = { [weak model] in
                    guard let model, model.configuration.preferences.featureEnabled(.clipboard), model.clipboardHistoryStore.copy(entry) else {
                        throw FrogError.message("The clipboard item is no longer available.")
                    }
                }
                let retention = model.clipboardHistoryStore.retentionGeneration
                add(SearchRecord(id: "clipboard:\(entry.id)", title: String(entry.text.prefix(100)), subtitle: "Clipboard · Paste · ⌘↩ Copy", keywords: String(entry.text.prefix(512)), symbol: "clipboard"), copy: copy) { [weak self, weak model] in
                    guard let self, let model else { return }
                    try await ClipboardHistoryDelivery.paste(entry, plainText: false, pasteboard: self.pasteboard, target: target, isCurrent: {
                        model.configuration.preferences.featureEnabled(.clipboard) && model.clipboardHistoryStore.retentionGeneration == retention && model.clipboardHistoryStore.entries.contains(where: { $0.id == entry.id })
                    }, waitForRelease: self.waitForRelease)
                    self.onToolUse?(.clipboardPaste)
                }
            }
        }
        updateResults()
    }
    private func add(_ record: SearchRecord, copy: (() async throws -> Void)? = nil, action: @escaping () async throws -> Void) {
        if recordIDs.insert(record.id).inserted { records.append(record) }
        actions[record.id] = action
        copyActions[record.id] = copy
    }
    private func updateResults() {
        let selectedID = results.indices.contains(selection) ? results[selection].id : nil
        results = CommandSearch.results(records, query: query)
        actions = actions.filter { !$0.key.hasPrefix("calculation:") }
        if let answer = QuickCalculation.result(query) {
            let id = "calculation:\(query)"
            results.insert(SearchRecord(id: id, title: answer, subtitle: "Calculation · Copy result", symbol: "equal.circle"), at: 0)
            actions[id] = { [weak self] in self?.copy(answer) }
        }
        selection = selectedID.flatMap { id in results.firstIndex(where: { $0.id == id }) } ?? 0
        searchFiles()
    }
    private func searchFiles() {
        fileRevision += 1
        fileDelay?.cancel(); fileDelay = nil
        fileQuery?.stop(); fileQuery = nil
        if let fileObserver { NotificationCenter.default.removeObserver(fileObserver); self.fileObserver = nil }
        guard panel?.isVisible == true, query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return }
        let revision = fileRevision, text = query
        fileDelay = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, self.fileRevision == revision else { return }
            self.startFileSearch(text, revision: revision)
        }
    }
    private func startFileSearch(_ text: String, revision: Int) {
        let search = NSMetadataQuery()
        search.searchScopes = fileScopes
        search.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, text)
        fileObserver = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: search, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.fileRevision == revision, let search = self.fileQuery else { return }
                search.disableUpdates(); defer { search.stop() }
                self.records.removeAll { $0.id.hasPrefix("file:") }
                self.recordIDs = Set(self.records.map(\.id))
                self.actions = self.actions.filter { !$0.key.hasPrefix("file:") }
                for index in 0..<min(40, search.resultCount) {
                    guard let item = search.result(at: index) as? NSMetadataItem,
                          let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                    let url = URL(fileURLWithPath: path)
                    self.add(SearchRecord(id: "file:\(path)", title: url.lastPathComponent, subtitle: url.deletingLastPathComponent().abbreviatingWithTildeInPath, symbol: "doc")) {
                        guard NSWorkspace.shared.open(url) else { throw FrogError.message("The file could not be opened.") }
                    }
                }
                let files = CommandSearch.results(self.records.filter { $0.id.hasPrefix("file:") }, query: text, limit: 20)
                self.results.removeAll { $0.id.hasPrefix("file:") }; self.results.append(contentsOf: files)
            }
        }
        fileQuery = search; search.start()
    }
    func choose(_ index: Int? = nil, copyOnly: Bool = false) {
        let index = index ?? selection
        guard let model, model.configuration.preferences.featureEnabled(.commandBar), results.indices.contains(index),
              let action = (copyOnly ? copyActions[results[index].id] : nil) ?? actions[results[index].id] else { return }
        hide()
        let token = generation
        delivery = Task { [weak self] in
            do {
                guard let self else { return }
                try await self.waitForRelease()
                guard token == self.generation, !Task.isCancelled else { return }
                try await action()
                try Task.checkCancellation()
                self.onToolUse?(.commandSelection)
            } catch is CancellationError { }
            catch { self?.model?.report(error) }
        }
    }
    func hide() {
        generation = UUID(); indexing?.cancel(); delivery?.cancel(); indexing = nil; delivery = nil
        windowIndexing?.cancel(); windowIndexing = nil
        fileRevision += 1
        fileQuery?.stop(); fileQuery = nil
        fileDelay?.cancel(); fileDelay = nil; sourceObservation = nil
        if let fileObserver { NotificationCenter.default.removeObserver(fileObserver) }; fileObserver = nil
        panel?.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let outside { NSEvent.removeMonitor(outside) }; outside = nil
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }; activation = nil
        records = []; recordIDs = []; actions = [:]; copyActions = [:]; results = []
    }
    private func removeFiles() {
        records.removeAll { $0.id.hasPrefix("file:") }
        recordIDs = Set(records.map(\.id))
        actions = actions.filter { !$0.key.hasPrefix("file:") }
    }
    private func copy(_ value: String) { pasteboard.clearContents(); pasteboard.setString(value, forType: .string) }
    isolated deinit { stop() }
}

private final class CommandBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
private struct CommandBarView: View {
    @ObservedObject var bar: CommandBar
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(FrogStyle.muted.opacity(0.35)).frame(width: 28, height: 3)
                .frame(maxWidth: .infinity).frame(height: 14)
                .overlay { WindowDragRegion().help("Drag to move the command bar") }
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(FrogStyle.muted)
                TextField("Search anything…", text: $bar.query)
                    .textFieldStyle(.plain).font(.system(size: 16)).focused($focused)
                 Text("esc").font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                     .padding(.horizontal, 5).padding(.vertical, 3).background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 4))
            }.padding(.horizontal, 18).frame(height: 54)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(bar.results.enumerated()), id: \.element.id) { index, result in
                            Button { bar.choose(index) } label: {
                                HStack(spacing: 12) {
                                    if let icon = bar.icon(for: result) {
                                        Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                                    } else { Image(systemName: result.symbol).frame(width: 24).foregroundStyle(FrogStyle.muted) }
                                    Text(result.title).font(.system(size: 13)).lineLimit(1)
                                    Spacer(minLength: 10)
                                    Text(result.subtitle).font(.system(size: 10)).foregroundStyle(FrogStyle.muted).lineLimit(1).frame(maxWidth: 160, alignment: .trailing)
                                    if index == bar.selection { Image(systemName: "return").font(.system(size: 11)).foregroundStyle(FrogStyle.muted) }
                                 }.padding(.horizontal, 10).frame(height: 40)
                                    .background(index == bar.selection ? FrogStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(result.id)
                        }
                        if bar.results.isEmpty { Text("No matching results").foregroundStyle(FrogStyle.muted).padding(28) }
                    }.padding(8)
                }.onChange(of: bar.selection) { _, value in
                    if bar.results.indices.contains(value) { proxy.scrollTo(bar.results[value].id) }
                }
            }
            Divider()
              HStack { Text("Frog"); Spacer(); Text("↑↓ Select    ↩ Open    ⌘↩ Copy") }
                 .font(.system(size: 10)).foregroundStyle(FrogStyle.muted).padding(.horizontal, 16).frame(height: 28)
                 .overlay { WindowDragRegion().help("Drag to move the command bar") }
         }.frame(width: 600, height: 390).frogPanel()
             .onAppear { focused = true }.onChange(of: bar.invocation) { focused = true }
    }
}

private extension URL {
    var abbreviatingWithTildeInPath: String { (path as NSString).abbreviatingWithTildeInPath }
}
