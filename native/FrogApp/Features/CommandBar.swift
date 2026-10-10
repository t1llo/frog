import AppKit
import Combine
import FrogCore
import SwiftUI

@MainActor final class CommandBar: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                removeFiles()
                for file in selectedFiles { addFile(file) }
                for file in recentFiles { addFile(file) }
            }
            updateResults(preserveSelection: false)
            searchFiles()
        }
    }
    @Published private(set) var results: [SearchRecord] = []
    @Published var selection = 0 { didSet { if selection != oldValue { selectionWasMoved = true } } }
    private var selectionWasMoved = false
    @Published private(set) var showsPositionReset = false
    var onToolUse: ((ActivityToolKind) -> Void)?
    private weak var model: AppModel?
    private var records: [SearchRecord] = []
    private var recordsByID: [String: SearchRecord] = [:]
    private var fileRecords: [SearchRecord] = []
    private var calculationID: String?
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
    private var settingsIndexing: Task<Void, Never>?
    private var settingsLoaded = false
    private var cachedSettings = SystemSettingsCatalog.defaults
    private var cachedApplications: [Rule] = []
    private var applicationRecords: [String: SearchRecord] = [:]
    private var cachedWindows: [SwitcherWindow] = []
    private let icons: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.countLimit = 256; return cache
    }()
    private struct IconLoad {
        let id = UUID()
        let task: Task<NSImage?, Never>
        var readers: Set<UUID> = []
    }
    private var iconLoads: [String: IconLoad] = [:]
    private var windowIconPaths: [String: String] = [:]
    private var recentSelections: [String] = []
    private var recentFiles: [SearchRecord] = []
    private var selectedFiles: [SearchRecord] = []
    @Published private(set) var invocation = UUID()
    private var delivery: Task<Void, Never>?
    private var generation = UUID()
    private let fileSearch: any CommandFileSearching
    private var fileRevision = 0
    private var fileDelay: Task<Void, Never>?
    private let pasteboard: NSPasteboard
    private let loadApplications: @MainActor () async -> [Rule]
    private let iconReader: CommandIconReader
    private let openFile: @MainActor (URL) -> Bool
    private let loadSettings: @Sendable () async -> [SystemSetting]
    private let openSetting: @MainActor (SystemSetting) throws -> Void
    private let fileScopes: [Any]
    private let captureTarget: @MainActor () -> (any ClipboardHistoryPasteTarget)?
    private let waitForRelease: () async throws -> Void

    init(model: AppModel, pasteboard: NSPasteboard = .general, fileScopes: [Any]? = nil,
         captureTarget: @escaping @MainActor () -> (any ClipboardHistoryPasteTarget)? = { NativeClipboardHistoryPasteTarget.capture() },
         waitForRelease: @escaping () async throws -> Void = { try await ClipboardSelection.waitForShortcutRelease() },
         loadIcon: @escaping @Sendable (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) },
         fileSearch: (any CommandFileSearching)? = nil,
         openFile: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
         loadSettings: @escaping @Sendable () async -> [SystemSetting] = { await MacSettingsIndex.shared.load() },
         openSetting: @escaping @MainActor (SystemSetting) throws -> Void = { try MacSettingsNavigation.open($0) },
         loadApplications: @escaping @MainActor () async -> [Rule] = {
             await ApplicationCatalogStore.shared.loadIfNeeded(); return ApplicationCatalogStore.shared.installed
         }) {
        self.model = model; self.pasteboard = pasteboard; self.loadApplications = loadApplications
        self.iconReader = CommandIconReader(load: loadIcon); self.openFile = openFile
        self.loadSettings = loadSettings; self.openSetting = openSetting
        self.fileSearch = fileSearch ?? MetadataCommandFileSearch()
        self.captureTarget = captureTarget; self.waitForRelease = waitForRelease
        self.fileScopes = fileScopes ?? [NSMetadataQueryUserHomeScope, NSMetadataQueryLocalComputerScope]
    }
    func warm() {
        guard warming == nil, model?.configuration.preferences.featureEnabled(.commandBar) == true else { return }
        preparePanel()
        refreshSettings()
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
        settingsIndexing?.cancel(); settingsIndexing = nil; settingsLoaded = false
        cachedSettings = SystemSettingsCatalog.defaults
        cachedApplications = []; applicationRecords = [:]; cachedWindows = []; icons.removeAllObjects()
        windowIconPaths = [:]
        recentSelections = []; recentFiles = []; selectedFiles = []
        panel?.contentView = nil; panel = nil
    }
    private func cacheApplications(_ installed: [Rule]) {
        guard installed != cachedApplications else { return }
        cachedApplications = installed
        applicationRecords = [:]
        for rule in installed {
            guard let path = rule.action?.applicationPath else { continue }
            applicationRecords[path] = SearchRecord(id: "app:\(path)", title: rule.name, subtitle: "App", keywords: "app open launch \(rule.action?.applicationBundleID ?? "")", symbol: "app")
        }
    }
    private func refreshSettings() {
        guard !settingsLoaded, settingsIndexing == nil else { return }
        settingsIndexing = Task { [weak self] in
            guard let self else { return }
            let settings = await self.loadSettings()
            guard !Task.isCancelled else { return }
            self.cachedSettings = settings; self.settingsLoaded = true; self.settingsIndexing = nil
            guard self.panel?.isVisible == true else { return }
            for record in self.records where record.id.hasPrefix("mac-setting:") {
                self.recordsByID[record.id] = nil; self.actions[record.id] = nil
            }
            self.records.removeAll { $0.id.hasPrefix("mac-setting:") }
            self.addSettings()
            self.updateResults()
        }
    }
    private func addSettings() {
        let open = openSetting
        for setting in cachedSettings { add(setting.record) { try open(setting) } }
    }
    func icon(for result: SearchRecord) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let path: String
        if result.id.hasPrefix("app:") { path = String(result.id.dropFirst(4)) }
        else if let windowPath = windowIconPaths[result.id] { path = windowPath }
        else { return nil }
        if let cached = icons.object(forKey: path as NSString) { return cached }
        let readerID = UUID(), token = generation
        if iconLoads[path] == nil {
            let reader = iconReader
            iconLoads[path] = IconLoad(task: Task.detached(priority: .utility) { await reader.image(for: path) })
        }
        iconLoads[path]?.readers.insert(readerID)
        guard let pending = iconLoads[path] else { return nil }
        let image = await withTaskCancellationHandler {
            await pending.task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.iconLoads[path]?.id == pending.id else { return }
                self.iconLoads[path]?.readers.remove(readerID)
                if self.iconLoads[path]?.readers.isEmpty == true {
                    self.iconLoads.removeValue(forKey: path)?.task.cancel()
                }
            }
        }
        guard token == generation else { return nil }
        if iconLoads[path]?.id == pending.id {
            iconLoads[path] = nil
            if let image { icons.setObject(image, forKey: path as NSString) }
        }
        return Task.isCancelled ? nil : image
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
        windowIconPaths = [:]
        for item in items {
            windowIconPaths["window:\(item.id)"] = NSRunningApplication(processIdentifier: item.pid)?.bundleURL?.path
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
        let host = NSHostingView(rootView: CommandBarView(bar: self))
        host.sizingOptions = []; created.contentView = host; panel = created
        center()
        host.layoutSubtreeIfNeeded()
    }
    func show() {
        guard let model, model.configuration.preferences.featureEnabled(.commandBar) else { return }
        if panel?.isVisible == true { hide(); return }
        hide()
        let target = captureTarget(), frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        records = []; recordsByID = [:]; fileRecords = []; actions = [:]; copyActions = [:]; query = ""; selection = 0
        selectionWasMoved = false
        addApplications(cachedApplications)
        for file in selectedFiles { addFile(file) }
        for file in recentFiles { addFile(file) }
        if model.configuration.preferences.featureEnabled(.windowSwitcher) { addWindows(cachedWindows) }
        addRoutes(model, target: target, frontPID: frontPID)
        addSettings()
        updateResults()
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
        if !NSScreen.screens.contains(where: { $0.visibleFrame.contains(panel.frame) }) { center() }
        panel.makeKeyAndOrderFront(nil)
        searchFiles()
        refreshSettings()
        let token = generation
        let shownApplications = cachedApplications
        indexing = Task { [weak self, weak model] in
            guard let self, let model else { return }
            let installed = await self.loadApplications()
            guard self.generation == token, !Task.isCancelled else { return }
            if installed != shownApplications {
                self.cacheApplications(installed)
                for record in self.records where record.id.hasPrefix("app:") {
                    self.recordsByID[record.id] = nil; self.actions[record.id] = nil
                }
                self.records.removeAll { $0.id.hasPrefix("app:") }
                self.addApplications(installed)
                self.updateResults()
            }
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
                self.updateResults()
            }
        }
        if model.configuration.preferences.featureEnabled(.windowSwitcher) {
            let applications = NSWorkspace.shared.runningApplications.compactMap(SwitcherApplication.running)
            windowIndexing = Task { [weak self] in
                guard let self else { return }
                let snapshot = await self.windows.snapshot(applications: applications, frontPID: frontPID)
                guard self.generation == token, !Task.isCancelled, snapshot.isPublishable else { return }
                self.cachedWindows = snapshot.windows
                for record in self.records where record.id.hasPrefix("window:") {
                    self.recordsByID[record.id] = nil; self.actions[record.id] = nil
                }
                self.records.removeAll { $0.id.hasPrefix("window:") }
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
        if model.configuration.preferences.featureEnabled(.applicationShortcuts) {
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
    }
    private func add(_ record: SearchRecord, copy: (() async throws -> Void)? = nil, action: @escaping () async throws -> Void) {
        if recordsByID.updateValue(record, forKey: record.id) == nil { records.append(record) }
        actions[record.id] = action
        copyActions[record.id] = copy
    }
    private func updateResults(preserveSelection: Bool = true) {
        let preserveChoice = preserveSelection && selectionWasMoved
        let selectedID = preserveChoice && results.indices.contains(selection) ? results[selection].id : nil
        var preferred = recentSelections.compactMap { recordsByID[$0] }
        let typed = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !typed {
            let files = fileRecords.prefix(4)
            let commands = records.lazy.filter { $0.id.hasPrefix("feature:") || $0.id.hasPrefix("rule:") }.prefix(4)
            preferred += files + commands
            preferred += cachedApplications.prefix(8).compactMap { $0.action?.applicationPath.flatMap { applicationRecords[$0] } }
        }
        // Late Spotlight results must not bury an equally good app or Frog command.
        var next = CommandSearch.results(records, query: query, preferred: preferred, trailing: typed ? fileRecords : [])
        if let calculationID { actions[calculationID] = nil; self.calculationID = nil }
        if let answer = QuickCalculation.result(query) {
            let id = "calculation:\(query)"
            next.insert(SearchRecord(id: id, title: answer, subtitle: "Calculation · Copy result", symbol: "equal.circle"), at: 0)
            calculationID = id
            actions[id] = { [weak self] in self?.copy(answer) }
        }
        if results != next { results = next }
        let nextSelection = selectedID.flatMap { id in next.firstIndex(where: { $0.id == id }) } ?? 0
        if selection != nextSelection { selection = nextSelection }
        selectionWasMoved = preserveChoice
    }
    private func searchFiles() {
        fileRevision += 1
        fileDelay?.cancel(); fileDelay = nil
        fileSearch.stop()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard panel?.isVisible == true, text.isEmpty || text.count >= 2 else { return }
        let revision = fileRevision
        if text.isEmpty { startFileSearch(text, revision: revision); return }
        fileDelay = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, self.fileRevision == revision else { return }
            self.startFileSearch(text, revision: revision)
        }
    }
    private func startFileSearch(_ text: String, revision: Int) {
        fileSearch.start(text: text, scopes: fileScopes) { [weak self] files in
            guard let self, self.fileRevision == revision else { return }
            self.removeFiles()
            for file in self.selectedFiles { self.addFile(file) }
            for file in files { self.addFile(file) }
            if text.isEmpty { self.recentFiles = Array(files.prefix(8)) }
            self.updateResults()
        }
    }
    private func addFile(_ record: SearchRecord) {
        guard record.id.hasPrefix("file:") else { return }
        let url = URL(fileURLWithPath: String(record.id.dropFirst(5)))
        if let previous = recordsByID.updateValue(record, forKey: record.id) {
            if previous != record, let index = fileRecords.firstIndex(where: { $0.id == record.id }) { fileRecords[index] = record }
        } else { fileRecords.append(record) }
        let open = openFile
        actions[record.id] = {
            guard open(url) else { throw FrogError.message("The file could not be opened.") }
        }
    }
    func choose(_ index: Int? = nil, copyOnly: Bool = false) {
        let index = index ?? selection
        guard let model, model.configuration.preferences.featureEnabled(.commandBar), results.indices.contains(index),
              let action = (copyOnly ? copyActions[results[index].id] : nil) ?? actions[results[index].id] else { return }
        let selected = results[index], selectedID = results[index].id
        hide()
        let token = generation
        delivery = Task { [weak self] in
            do {
                guard let self else { return }
                try await self.waitForRelease()
                guard token == self.generation, !Task.isCancelled else { return }
                try await action()
                try Task.checkCancellation()
                self.recentSelections.removeAll { $0 == selectedID }
                self.recentSelections.insert(selectedID, at: 0)
                self.recentSelections = Array(self.recentSelections.prefix(40))
                if selectedID.hasPrefix("file:") {
                    self.selectedFiles.removeAll { $0.id == selectedID }
                    self.selectedFiles.insert(selected, at: 0)
                    self.selectedFiles = Array(self.selectedFiles.prefix(8))
                }
                self.onToolUse?(.commandSelection)
            } catch is CancellationError { }
            catch { self?.model?.report(error) }
        }
    }
    func hide() {
        showsPositionReset = false
        generation = UUID(); indexing?.cancel(); delivery?.cancel(); indexing = nil; delivery = nil
        for load in iconLoads.values { load.task.cancel() }; iconLoads = [:]
        windowIndexing?.cancel(); windowIndexing = nil
        fileRevision += 1
        fileSearch.stop()
        fileDelay?.cancel(); fileDelay = nil; sourceObservation = nil
        panel?.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let outside { NSEvent.removeMonitor(outside) }; outside = nil
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }; activation = nil
        records = []; recordsByID = [:]; fileRecords = []; actions = [:]; copyActions = [:]; results = []; calculationID = nil
    }
    func finishDragging() {
        guard let panel, let screen = panel.screen else { return }
        let target = NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2, y: screen.visibleFrame.midY - panel.frame.height / 2)
        if abs(panel.frame.minX - target.x) < 18, abs(panel.frame.minY - target.y) < 18 { center() }
        else { showsPositionReset = true }
    }
    func center() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2, y: screen.visibleFrame.midY - panel.frame.height / 2))
        showsPositionReset = false
    }
    private func removeFiles() {
        for record in fileRecords { recordsByID[record.id] = nil; actions[record.id] = nil }
        fileRecords = []
    }
    private func copy(_ value: String) { pasteboard.clearContents(); pasteboard.setString(value, forType: .string) }
    isolated deinit { stop() }
}

/// Serial reads keep a fast scroll from flooding the cooperative pool with blocking icon I/O.
private actor CommandIconReader {
    let load: @Sendable (String) -> NSImage
    init(load: @escaping @Sendable (String) -> NSImage) { self.load = load }
    func image(for path: String) -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let image = load(path)
        guard !Task.isCancelled else { return nil }
        // Resolve lazy icon representations here too, rather than during SwiftUI drawing.
        // A fixed 2x thumbnail also bounds the cache by pixels, not just item count.
        guard image.isValid,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: 48, height: 48))
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: 24, height: 24)
        let thumbnail = NSImage(size: bitmap.size); thumbnail.addRepresentation(bitmap)
        return Task.isCancelled ? nil : thumbnail
    }
}

@MainActor protocol CommandFileSearching: AnyObject {
    func start(text: String, scopes: [Any], receive: @escaping @MainActor ([SearchRecord]) -> Void)
    func stop()
}

@MainActor final class MetadataCommandFileSearch: CommandFileSearching {
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    static func predicate(text: String, now: Date = Date()) -> NSPredicate {
        let documents = NSPredicate(format: "(ANY kMDItemContentTypeTree == 'public.content' OR ANY kMDItemContentTypeTree == 'public.folder') AND NOT (ANY kMDItemContentTypeTree == 'com.apple.application-bundle')")
        let words = text.split(whereSeparator: \.isWhitespace).map { NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, String($0)) }
        let recent = NSPredicate(format: "kMDItemLastUsedDate > %@", now.addingTimeInterval(-7 * 86400) as NSDate)
        // NSMetadataQuery raises on an AND with a single subpredicate, so every term stays at this level.
        return NSCompoundPredicate(andPredicateWithSubpredicates: [documents] + (words.isEmpty ? [recent] : words))
    }

    func start(text: String, scopes: [Any], receive: @escaping @MainActor ([SearchRecord]) -> Void) {
        stop()
        let search = NSMetadataQuery()
        search.searchScopes = scopes
        search.predicate = Self.predicate(text: text)
        search.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        search.notificationBatchingInterval = 0.1
        for notificationName in [Notification.Name.NSMetadataQueryGatheringProgress, .NSMetadataQueryDidFinishGathering] {
            observers.append(NotificationCenter.default.addObserver(forName: notificationName, object: search, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let search = notification.object as? NSMetadataQuery, self.query === search else { return }
                search.disableUpdates()
                let files = (0..<min(text.isEmpty ? 8 : 200, search.resultCount)).compactMap { index -> SearchRecord? in
                    guard let item = search.result(at: index) as? NSMetadataItem,
                          let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
                    let url = URL(fileURLWithPath: path)
                    let types = item.value(forAttribute: "kMDItemContentTypeTree") as? [String] ?? []
                    return SearchRecord(id: "file:\(path)", title: url.lastPathComponent, subtitle: url.deletingLastPathComponent().abbreviatingWithTildeInPath, symbol: types.contains("public.folder") ? "folder" : "doc")
                }
                if notification.name == .NSMetadataQueryDidFinishGathering { self.stop() }
                else { search.enableUpdates() }
                receive(files)
            }
            })
        }
        query = search
        if !search.start() { stop(); receive([]) }
    }

    func stop() {
        query?.stop(); query = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers = []
    }
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
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(FrogStyle.muted)
                    .frame(width: 24, height: 40).overlay { WindowDragRegion(onDragEnd: bar.finishDragging).help("Drag to move") }
                TextField("Search anything…", text: $bar.query)
                    .textFieldStyle(.plain).font(.system(size: 16)).focused($focused)
                if bar.showsPositionReset {
                    Button { bar.center() } label: { Image(systemName: "scope") }
                        .buttonStyle(.plain).help("Center command bar").accessibilityLabel("Center command bar")
                }
            }.padding(.horizontal, 14).frame(height: 50)
                .background(WindowDragRegion(onDragEnd: bar.finishDragging))
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(bar.results.enumerated()), id: \.element.id) { index, result in
                            CommandResultRow(bar: bar, result: result, selected: index == bar.selection)
                                .equatable().id(result.id)
                        }
                        if bar.results.isEmpty { Text("No matching results").foregroundStyle(FrogStyle.muted).padding(28) }
                    }.padding(8)
                }.onChange(of: bar.selection) { _, value in
                    if bar.results.indices.contains(value) { proxy.scrollTo(bar.results[value].id) }
                }
            }
         }.frame(width: 600, height: 390).frogPanel()
             .onAppear { focused = true }.onChange(of: bar.invocation) { focused = true }
    }
}

private struct CommandResultRow: View, Equatable {
    let bar: CommandBar
    let result: SearchRecord
    let selected: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bar === rhs.bar && lhs.result == rhs.result && lhs.selected == rhs.selected
    }

    var body: some View {
        Button {
            if let index = bar.results.firstIndex(where: { $0.id == result.id }) { bar.choose(index) }
        } label: {
            HStack(spacing: 12) {
                CommandResultIcon(bar: bar, result: result)
                Text(result.title).font(.system(size: 13, weight: selected ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 10)
                Text(result.subtitle).font(.system(size: 10)).foregroundStyle(result.isFrogCommand ? FrogStyle.accent : FrogStyle.muted).lineLimit(1).frame(maxWidth: 160, alignment: .trailing)
                if selected { Image(systemName: "return").font(.system(size: 11, weight: .medium)).foregroundStyle(FrogStyle.accent) }
            }.padding(.horizontal, 10).frame(height: 40)
                .background(selected ? FrogStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct CommandResultIcon: View {
    let bar: CommandBar
    let result: SearchRecord
    @State private var icon: NSImage?
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable() }
            else {
                Image(systemName: result.symbol).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(result.isFrogCommand ? FrogStyle.accent : FrogStyle.muted).frame(width: 24, height: 24)
                    .background(result.isFrogCommand ? FrogStyle.accentSoft : FrogStyle.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }.frame(width: 24, height: 24)
            .task(id: result.id) { icon = await bar.icon(for: result) }
    }
}

private extension SearchRecord {
    /// Frog's own pages, commands and answers, set apart from apps, windows, files and system destinations.
    var isFrogCommand: Bool { id == "features" || ["feature:", "route:", "rule:", "quick:", "layout:", "system:", "calculation:"].contains { id.hasPrefix($0) } }
}

private extension URL {
    var abbreviatingWithTildeInPath: String { (path as NSString).abbreviatingWithTildeInPath }
}
