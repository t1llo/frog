import AppKit
import Combine
import FrogCore
import SwiftUI

/// The command bar: a keyboard panel that lists rows from its providers, ranked as you type, and Spotlight's files.
/// It opens in one frame with no animation; everything slow (scans, snapshots, Spotlight) arrives after it.
@MainActor final class CommandBar: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            disarm()
            if argument != nil { updateResults(preserveSelection: false); return }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                removeFiles()
                addPickedFiles()
                for file in recentFiles { addFile(file) }
            }
            updateResults(preserveSelection: false)
            searchFiles()
        }
    }
    @Published private(set) var results: [SearchRecord] = []
    @Published var selection = 0 {
        didSet {
            guard selection != oldValue else { return }
            selectionWasMoved = true
            if let armed = armedRecord, !(results.indices.contains(selection) && results[selection].id == armed.id) { disarm() }
        }
    }
    /// The action that asks for a value, while the search field takes it.
    @Published private(set) var argument: CommandArgument?
    /// Published so that rows already drawn switch to their own icon, even when nothing else about them changed.
    @Published private(set) var iconPaths: [String: String] = [:]
    @Published private(set) var showsPositionReset = false
    @Published private(set) var invocation = UUID()
    var onToolUse: ((ActivityToolKind) -> Void)?
    /// How long the last open took: building the rows, and from the key press until the panel was on screen.
    private(set) var lastOpen: (rows: Duration, shown: Duration)?

    private var selectionWasMoved = false
    /// Set by a drag that left the bar away from the middle of its display, until it is centred again.
    private var userPlaced = false
    private weak var model: AppModel?

    // MARK: Rows

    let applications: ApplicationCommandRows
    let macSettings: MacSettingsCommandRows
    private let windowRows = WindowSwitchCommandRows()
    /// The bar's own sources, in the order equally good matches are listed. Plugins add theirs after these.
    private lazy var builtin: [any CommandBarRowProviding] = [
        applications,
        windowRows,
        FrogPageRows(),
        RuleCommandRows(),
        WindowLayoutCommandRows(),
        TextToolRows(),
        CalculationRows(),
        EmojiRows(),
        CleanerCommandRows(applications: { [unowned self] in self.applications.cleanerApplications }),
        PhoneCommandRows(),
        PluginCommandRows(),
        PluginActionRows(),
    ] + extraProviders
    private let extraProviders: [any CommandBarRowProviding]
    private let clipboardRows = ClipboardCommandRows(), documentRows = DocumentRowsProvider()
    /// The providers of this open, and the rows each gave last.
    private var providers: [any CommandBarRowProviding] = []
    private var providerRows: [ObjectIdentifier: [CommandBarRow]] = [:]
    private var context: CommandBarContext?

    /// The catalogue: every provider's rows, a row listed twice in the place it was first listed.
    private var records: [SearchRecord] = []
    private var rows: [String: CommandBarRow] = [:]
    /// The rows the providers built for the typed text, which are listed but not part of the catalogue.
    private var queryRows: [String: CommandBarRow] = [:]
    private var fileRecords: [SearchRecord] = []
    private var fileIDs = Set<String>()
    private var recentSelections: [String] = []
    private var recentFiles: [SearchRecord] = []
    private var selectedFiles: [SearchRecord] = []

    private var confirmation = CommandConfirmation()
    /// The armed row as it is listed when it is not waiting.
    private var armedRecord: SearchRecord?
    private var disarming: Task<Void, Never>?
    private var prompt: CommandRowPrompt?
    /// What was typed before the prompt took the field, for going back.
    private var typedBeforeArgument = ""

    // MARK: Panel and services

    private var panel: NSPanel?
    private var monitor: Any?
    private var outside: Any?
    private var activation: NSObjectProtocol?
    private var warming: Task<Void, Never>?
    private var delivery: Task<Void, Never>?
    private var generation = UUID()
    private var pasteTarget: (any ClipboardHistoryPasteTarget)?
    private let icons: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.countLimit = 256; return cache
    }()
    private struct IconLoad {
        let id = UUID()
        let task: Task<NSImage?, Never>
        var readers: Set<UUID> = []
    }
    private var iconLoads: [String: IconLoad] = [:]
    private let fileSearch: any CommandFileSearching
    private var fileRevision = 0
    private var fileDelay: Task<Void, Never>?
    private let pasteboard: NSPasteboard
    private let iconReader: CommandIconReader
    private let openFile: @MainActor (URL) -> Bool
    private let fileScopes: [Any]
    private let captureTarget: @MainActor () -> (any ClipboardHistoryPasteTarget)?
    private let waitForRelease: () async throws -> Void

    init(model: AppModel, pasteboard: NSPasteboard = .general, fileScopes: [Any]? = nil,
         captureTarget: @escaping @MainActor () -> (any ClipboardHistoryPasteTarget)? = { NativeClipboardHistoryPasteTarget.capture() },
         waitForRelease: @escaping () async throws -> Void = { try await ClipboardSelection.waitForShortcutRelease() },
         loadIcon: @escaping @Sendable (String) -> NSImage = { MacSettingsDiscovery.image(forIconKey: $0) },
         fileSearch: (any CommandFileSearching)? = nil,
         openFile: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
         loadSettings: @escaping @Sendable () async -> [SystemSetting] = { await MacSettingsIndex.shared.load() },
         openSetting: @escaping @MainActor (SystemSetting) throws -> Void = { try MacSettingsNavigation.open($0) },
         loadApplications: @escaping @MainActor () async -> [Rule] = { await ApplicationCatalogStore.shared.load() },
         applicationNames: @escaping @MainActor (String) -> [String] = { ApplicationCatalogStore.shared.alternativeNames[$0] ?? [] },
         extraProviders: [any CommandBarRowProviding] = []) {
        self.model = model; self.extraProviders = extraProviders; self.pasteboard = pasteboard
        applications = ApplicationCommandRows(load: loadApplications, alternativeNames: applicationNames)
        macSettings = MacSettingsCommandRows(load: loadSettings, open: openSetting)
        iconReader = CommandIconReader(load: loadIcon); self.openFile = openFile
        self.fileSearch = fileSearch ?? MetadataCommandFileSearch()
        self.captureTarget = captureTarget; self.waitForRelease = waitForRelease
        self.fileScopes = fileScopes ?? [NSMetadataQueryUserHomeScope, NSMetadataQueryLocalComputerScope]
    }

    private var enabled: Bool { model?.configuration.preferences.featureEnabled(.commandBar) == true }

    /// Builds the panel and reads the applications and settings panes, so the first open is as fast as the rest.
    func warm() {
        guard warming == nil, enabled else { return }
        preparePanel()
        refreshSettings()
        warming = Task { [weak self] in
            guard let self else { return }
            await self.applications.warm()
            guard !Task.isCancelled else { return }
            await self.preloadIcons()
            guard !Task.isCancelled else { return }
            self.warming = nil
        }
    }
    /// The rows listed before anything is typed then show their icons from the first frame of the first open.
    func preloadIcons() async {
        for record in applications.suggested where !Task.isCancelled { _ = await icon(for: record) }
    }
    func stop() {
        hide(); warming?.cancel(); warming = nil
        macSettings.reset(); applications.clear(); windowRows.clear()
        icons.removeAllObjects()
        recentSelections = []; recentFiles = []; selectedFiles = []
        panel?.contentView = nil; panel = nil
    }
    func cacheApplications(_ installed: [Rule]) { applications.cache(installed) }
    func refreshSettings() { macSettings.discover() }

    // MARK: Icons

    /// The key a row's icon is cached and read under, or nil for a row that shows its symbol.
    func iconPath(for result: SearchRecord) -> String? {
        // A pane's icon can arrive with discovery while the bar is closed.
        if result.id.hasPrefix("mac-setting:") { return macSettings.iconPath(for: result.id) }
        if let path = iconPaths[result.id] { return path }
        if result.id.hasPrefix("app:") { return String(result.id.dropFirst(4)) }
        if let path = CleanerCommand.path(fromRowID: result.id) { return path }
        return nil
    }
    /// What a row draws first. It only looks in the cache, so it never waits for a read.
    func cachedIcon(for result: SearchRecord) -> NSImage? {
        iconPath(for: result).flatMap { icons.object(forKey: $0 as NSString) }
    }
    func icon(for result: SearchRecord) async -> NSImage? {
        guard !Task.isCancelled, let path = iconPath(for: result) else { return nil }
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

    // MARK: Opening and closing

    private func preparePanel() {
        guard panel == nil else { return }
        let created = CommandBarPanel(contentRect: NSRect(origin: .zero, size: CommandBarView.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        created.title = "Frog command bar"; created.isReleasedWhenClosed = false; created.isRestorable = false
        created.isOpaque = false; created.backgroundColor = .clear; created.hasShadow = true
        created.level = .floating; created.hidesOnDeactivate = false
        // A keyboard surface opens and closes in one frame: no fade or zoom from AppKit.
        created.animationBehavior = .none
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: CommandBarView(bar: self))
        host.sizingOptions = []; created.contentView = host; panel = created
        center()
        host.layoutSubtreeIfNeeded()
    }
    func show() {
        guard let model, enabled else { return }
        if panel?.isVisible == true { hide(); return }
        hide()
        let clock = ContinuousClock(), start = clock.now
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        prepareResults(model, frontPID: frontPID)
        let built = clock.now
        preparePanel()
        guard let panel else { return }
        invocation = UUID()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type != .keyDown { if event.window !== self.panel { self.hide() }; return false }
                guard event.window === self.panel else { return false }
                if event.keyCode == 51, self.argument != nil, self.query.isEmpty { self.leaveArgument(); return true }
                guard Self.handlesKey(event.keyCode, firstResponder: self.panel?.firstResponder) else { return false }
                switch event.keyCode {
                case 53: if self.argument != nil { self.leaveArgument() } else { self.hide() }; return true
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
        // Retain the user's drag position; recover if its display was disconnected. A bar that was left where it
        // opened follows the pointer to the display in use, as the window switcher does.
        let inUse = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let origin = Self.openingOrigin(of: panel.frame, dragged: userPlaced, displays: NSScreen.screens.map(\.visibleFrame), inUse: inUse?.visibleFrame)
        if origin != panel.frame.origin { panel.setFrameOrigin(origin); userPlaced = false }
        // The rows are drawn before the panel is ordered in, so its first frame already lists them.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.makeKeyAndOrderFront(nil)
        lastOpen = (built - start, clock.now - start)
        searchFiles()
        applications.rescan()
    }
    /// Escape, the arrow keys and Return act on the results before the search field sees them. An input method
    /// that is composing there needs them itself, to cancel, pick or confirm a candidate.
    static func handlesKey(_ keyCode: UInt16, firstResponder: NSResponder?) -> Bool {
        [53, 125, 126, 36, 76].contains(keyCode) && (firstResponder as? NSTextInputClient)?.hasMarkedText() != true
    }
    /// The rows a presentation starts with and the field they paste into. This runs before the panel takes
    /// keyboard focus and opens no window.
    func prepareResults(_ model: AppModel, frontPID: pid_t?) {
        // Finding the focused field is Accessibility IPC to the app in front. Only clipboard rows and notes that
        // paste paste there. Before the notes are read, one of them might.
        let preferences = model.configuration.preferences
        let pastes = preferences.featureEnabled(.clipboard) || preferences.featureEnabled(.scratchpad)
            && (!model.documents.loaded || model.documents.items.contains(where: \.pastes))
        pasteTarget = pastes ? captureTarget() : nil
        let context = CommandBarContext(model: model, frontPID: frontPID, pasteboard: pasteboard, pasteTarget: pasteTarget,
                                        waitForRelease: waitForRelease, copy: { [weak self] in self?.copy($0) },
                                        toolUse: { [weak self] in self?.onToolUse?($0) })
        self.context = context
        if learning { model.commandChoices.refreshIfStale() }
        argument = nil; prompt = nil
        fileRecords = []; fileIDs = []; queryRows = [:]
        query = ""; selection = 0
        selectionWasMoved = false
        addPickedFiles()
        for file in recentFiles { addFile(file) }
        providers = builtin + model.pluginHost.commandBarProviders + [clipboardRows, macSettings, documentRows]
        providerRows = [:]
        for provider in providers {
            provider.open(in: context) { [weak self, weak provider] in
                guard let self, let provider else { return }
                self.reload(provider)
            }
            providerRows[ObjectIdentifier(provider)] = provider.rows(in: context)
        }
        rebuildCatalogue()
        updateResults()
    }
    /// A provider's rows changed while the bar lists rows.
    private func reload(_ provider: any CommandBarRowProviding) {
        let key = ObjectIdentifier(provider)
        guard let context, let listed = providerRows[key] else { return }
        let next = provider.rows(in: context)
        // Rows from a provider that listed none yet go last, so equally good rows keep their lines under the selection.
        if listed.isEmpty, !next.isEmpty, let index = providers.firstIndex(where: { ObjectIdentifier($0) == key }) {
            providers.append(providers.remove(at: index))
        }
        providerRows[key] = next
        rebuildCatalogue()
        updateResults()
    }
    /// Every provider's rows in provider order. A row listed again replaces the first in its place, so what it
    /// shows is what its action acts on.
    private func rebuildCatalogue() {
        var records: [SearchRecord] = [], rows: [String: CommandBarRow] = [:], positions: [String: Int] = [:]
        var paths: [String: String] = [:]
        for provider in providers {
            for row in providerRows[ObjectIdentifier(provider)] ?? [] {
                let id = row.record.id
                if let position = positions[id] { records[position] = row.record } else { positions[id] = records.count; records.append(row.record) }
                rows[id] = row
                if let path = row.iconPath { paths[id] = path } else { paths[id] = nil }
            }
        }
        self.records = records; self.rows = rows
        if paths != iconPaths { iconPaths = paths }
    }
    func hide() {
        showsPositionReset = false
        generation = UUID(); delivery?.cancel(); delivery = nil
        for load in iconLoads.values { load.task.cancel() }; iconLoads = [:]
        for provider in providers { provider.close() }
        providers = []; providerRows = [:]
        fileRevision += 1
        fileSearch.stop()
        fileDelay?.cancel(); fileDelay = nil; pasteTarget = nil
        panel?.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let outside { NSEvent.removeMonitor(outside) }; outside = nil
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }; activation = nil
        confirmation.disarm(); armedRecord = nil; disarming?.cancel(); disarming = nil
        argument = nil; prompt = nil
        records = []; rows = [:]; fileRecords = []; fileIDs = []; results = []
        queryRows = [:]; context = nil
    }

    // MARK: Ranking

    private var learning: Bool { model?.commandChoices.isActive == true }
    private func record(_ id: String) -> SearchRecord? {
        rows[id]?.record ?? (fileIDs.contains(id) ? fileRecords.first { $0.id == id } : nil)
    }
    private func updateResults(preserveSelection: Bool = true) {
        let preserveChoice = preserveSelection && selectionWasMoved
        let selectedID = preserveChoice && results.indices.contains(selection) ? results[selection].id : nil
        var next = argument != nil ? argumentResults() : rankedResults()
        // A row that waits for a second Return keeps saying so while the list around it changes.
        if let armed = armedRecord {
            if let index = next.firstIndex(where: { $0.id == armed.id }), let confirm = row(armed.id)?.primary?.confirm {
                armedRecord = next[index]; next[index] = Self.asking(next[index], confirm)
            } else { confirmation.disarm(); armedRecord = nil; disarming?.cancel(); disarming = nil }
        }
        if results != next { results = next }
        let nextSelection = selectedID.flatMap { id in next.firstIndex(where: { $0.id == id }) } ?? 0
        if selection != nextSelection { selection = nextSelection }
        selectionWasMoved = preserveChoice
    }
    /// Learned rows lead, those picked for this text with their frecency; one may be latched above everything.
    /// With learning off, the rows picked in this session only break ties.
    private func rankedResults() -> [SearchRecord] {
        let typed = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var preferred: [SearchRecord], latched: String?, boosts: [String: Double] = [:]
        if learning, let index = model?.commandChoices.index {
            let suggestions = index.suggestions(for: query)
            var listed = Set<String>()
            preferred = (suggestions.leading + index.frequentItems(limit: 40)).compactMap { id in listed.insert(id).inserted ? record(id) : nil }
            latched = suggestions.latched
            if typed { boosts = index.frecency(for: query) }
        } else {
            preferred = recentSelections.compactMap { record($0) }
        }
        if !typed {
            let files = fileRecords.prefix(4)
            let commands = records.lazy.filter { $0.id.hasPrefix("feature:") || $0.id.hasPrefix("rule:") }.prefix(4)
            preferred += files + commands
            preferred += applications.suggested
        }
        // Late Spotlight results must not bury an equally good app or Frog command.
        let ranked = CommandSearch.results(records, query: query, preferred: preferred, trailing: typed ? fileRecords : [], latched: latched, boosts: boosts)
        queryRows = [:]
        var leading: [SearchRecord] = [], trailing: [SearchRecord] = []
        if let context {
            for provider in providers {
                for row in provider.queryRows(for: query, in: context) where rows[row.record.id] == nil && queryRows[row.record.id] == nil {
                    queryRows[row.record.id] = row
                    if row.placement == .leading { leading.append(row.record) } else { trailing.append(row.record) }
                }
            }
        }
        return leading + ranked + trailing
    }

    // MARK: Asking for a value

    /// The options that match what was typed, or the typed text itself, as the rows Return submits.
    private func argumentResults() -> [SearchRecord] {
        guard let argument, let prompt else { return [] }
        if prompt.options.isEmpty {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [SearchRecord(id: "argument:\(text)", title: text, subtitle: argument.title, symbol: argument.symbol)]
        }
        let options = prompt.options.map { SearchRecord(id: "argument:\($0)", title: $0, subtitle: argument.title, symbol: argument.symbol) }
        return CommandSearch.results(options, query: query)
    }
    private func enterArgument(_ record: SearchRecord, _ prompt: CommandRowPrompt) {
        typedBeforeArgument = query
        self.prompt = prompt
        argument = CommandArgument(id: record.id, title: record.title, symbol: record.symbol, placeholder: prompt.placeholder)
        selectionWasMoved = false
        if query.isEmpty { updateResults(preserveSelection: false) } else { query = "" }
    }
    /// Back to the list the prompt was chosen from.
    func leaveArgument() {
        guard argument != nil else { return }
        argument = nil; prompt = nil
        let typed = typedBeforeArgument
        if query == typed { updateResults(preserveSelection: false) } else { query = typed }
    }

    // MARK: Choosing

    private func row(_ id: String) -> CommandBarRow? { rows[id] ?? queryRows[id] }
    private func action(for record: SearchRecord, copyOnly: Bool) -> (() async throws -> Void)? {
        if record.id.hasPrefix("argument:"), let prompt {
            let value = String(record.id.dropFirst("argument:".count))
            return { try await prompt.submit(value) }
        }
        if fileIDs.contains(record.id) { return fileAction(record) }
        guard let row = row(record.id) else { return nil }
        return (copyOnly ? row.secondary?.run : nil) ?? row.primary?.run
    }
    func choose(_ index: Int? = nil, copyOnly: Bool = false) {
        let index = index ?? selection
        guard enabled, results.indices.contains(index) else { return }
        let selected = results[index]
        if argument == nil, let prompt = row(selected.id)?.primary?.prompt {
            enterArgument(selected, prompt); return
        }
        let copies = copyOnly && row(selected.id)?.secondary != nil
        guard let action = action(for: selected, copyOnly: copyOnly) else { return }
        if !copies, argument == nil, let confirm = row(selected.id)?.primary?.confirm, !confirmation.press(selected.id, now: Date()) {
            arm(index, confirm: confirm)
            return
        }
        // A value typed for a prompt is a pick of the action it was asked for, after the text that found it.
        let pickedID = argument?.id ?? selected.id
        // A calculation answers only its own query and is never listed again as a suggestion.
        let suggestible = argument != nil || rows[pickedID] != nil || fileIDs.contains(pickedID)
        let typed = argument != nil ? typedBeforeArgument : query
        // Hiding and the next open clear the query.
        hide()
        let token = generation
        delivery = Task { [weak self] in
            do {
                guard let self else { return }
                try await self.waitForRelease()
                guard token == self.generation, !Task.isCancelled else { return }
                try await action()
                try Task.checkCancellation()
                if suggestible {
                    self.recentSelections.removeAll { $0 == pickedID }
                    self.recentSelections.insert(pickedID, at: 0)
                    self.recentSelections = Array(self.recentSelections.prefix(40))
                    // Recorded only while learning is still on; a copy is a pick of the same row.
                    self.model?.commandChoices.record(typed: typed, id: pickedID)
                }
                if pickedID.hasPrefix("file:") {
                    self.selectedFiles.removeAll { $0.id == pickedID }
                    self.selectedFiles.insert(selected, at: 0)
                    self.selectedFiles = Array(self.selectedFiles.prefix(8))
                }
                self.onToolUse?(.commandSelection)
            } catch is CancellationError { }
            catch { self?.model?.report(error) }
        }
    }
    /// Shows the confirm text in place of the row's subtitle until the second Return, or until the time for it is up.
    private func arm(_ index: Int, confirm: String) {
        let id = results[index].id
        if let armed = armedRecord, armed.id != id, let previous = results.firstIndex(where: { $0.id == armed.id }) { results[previous] = armed }
        if armedRecord?.id != id { armedRecord = results[index] }
        results[index] = Self.asking(results[index], confirm)
        disarming?.cancel()
        disarming = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(CommandConfirmation.window)) } catch { return }
            guard let self, self.armedRecord?.id == id else { return }
            self.disarm()
        }
    }
    /// Forgets the first Return and lists the armed row as it was.
    private func disarm() {
        confirmation.disarm()
        disarming?.cancel(); disarming = nil
        guard let armed = armedRecord else { return }
        armedRecord = nil
        if let index = results.firstIndex(where: { $0.id == armed.id }) { results[index] = armed }
    }
    private static func asking(_ record: SearchRecord, _ confirm: String) -> SearchRecord {
        SearchRecord(id: record.id, title: record.title, subtitle: confirm, keywords: record.keywords, symbol: record.symbol)
    }

    // MARK: Files

    private func searchFiles() {
        fileRevision += 1
        fileDelay?.cancel(); fileDelay = nil
        fileSearch.stop()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard panel?.isVisible == true, argument == nil, text.isEmpty || text.count >= 2 else { return }
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
            self.listFiles(files, recent: text.isEmpty)
        }
    }
    /// Lists what the file search reports now in place of what it reported before.
    func listFiles(_ files: [SearchRecord], recent: Bool) {
        // Spotlight reports its first rows as they stand while it gathers. A file the choice was moved to keeps its
        // row while it is chosen, so that a report without it does not hand Return to whatever is listed first.
        let chosen = selectionWasMoved && results.indices.contains(selection)
            ? fileRecords.firstIndex { $0.id == results[selection].id } : nil
        let kept = chosen.map { fileRecords[$0] }
        removeFiles()
        addPickedFiles()
        for file in files { addFile(file) }
        if let chosen, let kept, !fileIDs.contains(kept.id) {
            addFile(kept)
            let record = fileRecords.removeLast()
            fileRecords.insert(record, at: min(chosen, fileRecords.count))
        }
        if recent { recentFiles = Array(files.prefix(8)) }
        updateResults()
    }
    /// Files picked before are listed before Spotlight answers: those of this session, and with learning on the
    /// learned ones that still exist.
    private func addPickedFiles() {
        for file in selectedFiles { addFile(file) }
        if learning, let learned = model?.commandChoices.learnedFiles { for file in learned { addFile(file) } }
    }
    private func addFile(_ record: SearchRecord) {
        guard record.id.hasPrefix("file:"), rows[record.id] == nil else { return }
        if fileIDs.insert(record.id).inserted { fileRecords.append(record) }
        else if let index = fileRecords.firstIndex(where: { $0.id == record.id }), fileRecords[index] != record { fileRecords[index] = record }
    }
    private func fileAction(_ record: SearchRecord) -> () async throws -> Void {
        let url = URL(fileURLWithPath: String(record.id.dropFirst(5))), open = openFile
        return { [weak self] in
            guard open(url) else {
                // A learned file that has gone is not suggested again.
                self?.model?.commandChoices.forget(id: record.id)
                throw FrogError.message("The file could not be opened.")
            }
        }
    }
    private func removeFiles() { fileRecords = []; fileIDs = [] }

    // MARK: Position

    /// Where the bar opens: where it was dragged to while a display still shows all of it, otherwise in the middle
    /// of the display in use.
    static func openingOrigin(of frame: NSRect, dragged: Bool, displays: [NSRect], inUse: NSRect?) -> NSPoint {
        if dragged, displays.contains(where: { $0.contains(frame) }) { return frame.origin }
        guard let inUse else { return frame.origin }
        return NSPoint(x: inUse.midX - frame.width / 2, y: inUse.midY - frame.height / 2)
    }
    func finishDragging() {
        guard let panel, let screen = panel.screen else { return }
        let target = NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2, y: screen.visibleFrame.midY - panel.frame.height / 2)
        if abs(panel.frame.minX - target.x) < 18, abs(panel.frame.minY - target.y) < 18 { center() }
        else { showsPositionReset = true; userPlaced = true }
    }
    func center() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2, y: screen.visibleFrame.midY - panel.frame.height / 2))
        showsPositionReset = false; userPlaced = false
    }
    private func copy(_ value: String) { pasteboard.clearContents(); pasteboard.setString(value, forType: .string) }
    isolated deinit { stop() }
}

/// An action asking for its value in the search field.
struct CommandArgument: Equatable {
    let id: String
    let title: String
    let symbol: String
    let placeholder: String
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

/// No files, for a bar that only ranks its rows.
@MainActor final class NoCommandFileSearch: CommandFileSearching {
    func start(text: String, scopes: [Any], receive: @escaping @MainActor ([SearchRecord]) -> Void) {}
    func stop() {}
}

@MainActor final class MetadataCommandFileSearch: CommandFileSearching {
    /// One Spotlight query and the rows it reported last.
    private struct Pass {
        let query: NSMetadataQuery
        let observers: [NSObjectProtocol]
        var files: [SearchRecord] = []
        var gathering = true
    }
    private var passes: [Pass] = []
    /// Far more than is ever listed. Gathering past it only costs time, most of all on the main thread.
    static let gatherLimit = 1_000

    private static var documents: NSPredicate {
        NSPredicate(format: "(ANY kMDItemContentTypeTree == 'public.content' OR ANY kMDItemContentTypeTree == 'public.folder') AND NOT (ANY kMDItemContentTypeTree == 'com.apple.application-bundle')")
    }
    static func predicate(text: String, now: Date = Date()) -> NSPredicate {
        let words = text.split(whereSeparator: \.isWhitespace).map { NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, String($0)) }
        let recent = NSPredicate(format: "kMDItemLastUsedDate > %@", now.addingTimeInterval(-7 * 86400) as NSDate)
        // NSMetadataQuery raises on an AND with a single subpredicate, so every term stays at this level.
        return NSCompoundPredicate(andPredicateWithSubpredicates: [documents] + (words.isEmpty ? [recent] : words))
    }
    /// The queries that answer `text`, the one whose rows are listed first leading. Spotlight hands over what it
    /// finds in no useful order and only the first rows are read, so the names that begin with the text, which rank
    /// highest, are asked for by themselves. Two letters are part of a great share of all names on a disk and are
    /// looked for nowhere else; two characters of a script that writes whole words with them are longer in UTF-8.
    static func predicates(text: String, now: Date = Date()) -> [NSPredicate] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [predicate(text: text, now: now)] }
        let beginning = NSCompoundPredicate(andPredicateWithSubpredicates: [documents, NSPredicate(format: "%K BEGINSWITH[cd] %@", NSMetadataItemFSNameKey, text)])
        return text.utf8.count < 3 ? [beginning] : [beginning, predicate(text: text, now: now)]
    }
    /// Whether a query for typed text has found enough. The recent files are few and come sorted by use.
    static func stopsGathering(at count: Int, text: String) -> Bool { !text.isEmpty && count >= gatherLimit }
    /// Every row once, those of the leading query first.
    static func merged(_ passes: [[SearchRecord]]) -> [SearchRecord] {
        var listed = Set<String>()
        return passes.joined().filter { listed.insert($0.id).inserted }
    }

    func start(text: String, scopes: [Any], receive: @escaping @MainActor ([SearchRecord]) -> Void) {
        stop()
        for predicate in Self.predicates(text: text) {
            let search = NSMetadataQuery()
            search.searchScopes = scopes
            search.predicate = predicate
            search.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
            // Delivered with the results. Asked of each row instead, the type is a round trip to Spotlight per row,
            // and two hundred of them were measured to hold the main thread for a fifth of a second on every report.
            search.valueListAttributes = [NSMetadataItemContentTypeTreeKey]
            search.notificationBatchingInterval = 0.1
            let observers = [Notification.Name.NSMetadataQueryGatheringProgress, .NSMetadataQueryDidFinishGathering].map { notificationName in
                NotificationCenter.default.addObserver(forName: notificationName, object: search, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let search = notification.object as? NSMetadataQuery,
                          let pass = self.passes.firstIndex(where: { $0.query === search && $0.gathering }) else { return }
                    search.disableUpdates()
                    self.passes[pass].files = (0..<min(text.isEmpty ? 8 : 200, search.resultCount)).compactMap { index -> SearchRecord? in
                        guard let item = search.result(at: index) as? NSMetadataItem,
                              let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
                        let url = URL(fileURLWithPath: path)
                        let types = item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []
                        return SearchRecord(id: "file:\(path)", title: url.lastPathComponent, subtitle: url.deletingLastPathComponent().abbreviatingWithTildeInPath, symbol: types.contains("public.folder") ? "folder" : "doc")
                    }
                    if notification.name == .NSMetadataQueryDidFinishGathering || Self.stopsGathering(at: search.resultCount, text: text) { self.finish(pass) }
                    else { search.enableUpdates() }
                    receive(Self.merged(self.passes.map(\.files)))
                }
                }
            }
            passes.append(Pass(query: search, observers: observers))
        }
        for pass in passes.indices where !passes[pass].query.start() { finish(pass) }
        if !passes.contains(where: \.gathering) { stop(); receive([]) }
    }

    /// Ends one query and keeps its rows for as long as the others gather.
    private func finish(_ pass: Int) {
        passes[pass].query.stop(); passes[pass].gathering = false
        for observer in passes[pass].observers { NotificationCenter.default.removeObserver(observer) }
    }
    func stop() {
        for pass in passes.indices where passes[pass].gathering { finish(pass) }
        passes = []
    }
    isolated deinit { stop() }
}

private final class CommandBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
struct CommandBarView: View {
    static let size = NSSize(width: 600, height: 390)
    @ObservedObject var bar: CommandBar
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(FrogStyle.muted)
                    .frame(width: 24, height: 40).overlay { WindowDragRegion(onDragEnd: bar.finishDragging).help("Drag to move") }
                if let argument = bar.argument {
                    Label(argument.title, systemImage: argument.symbol).font(FrogType.label).lineLimit(1)
                        .foregroundStyle(FrogStyle.accent).padding(.horizontal, 8).frame(height: FrogStyle.compactHeight)
                        .background(FrogStyle.accentSoft, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
                }
                TextField(bar.argument?.placeholder ?? "Search", text: $bar.query)
                    .textFieldStyle(.plain).font(FrogType.lead).focused($focused)
                if bar.showsPositionReset {
                    IconAction(title: "Center command bar", symbol: "scope") { bar.center() }
                }
            }.padding(.horizontal, 14).frame(height: 50)
                .background(WindowDragRegion(onDragEnd: bar.finishDragging))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(bar.results.enumerated()), id: \.element.id) { index, result in
                            CommandResultRow(bar: bar, result: result, iconKey: bar.iconPath(for: result), selected: index == bar.selection)
                                .equatable().id(result.id)
                        }
                        if bar.results.isEmpty {
                            Text(bar.argument == nil ? "No results" : "Type, then press Return")
                                .font(FrogType.body).foregroundStyle(FrogStyle.muted).padding(28)
                        }
                    }.padding(6)
                }.onChange(of: bar.selection) { _, value in
                    if bar.results.indices.contains(value) { proxy.scrollTo(bar.results[value].id) }
                }
            }
        }.frame(width: Self.size.width, height: Self.size.height).frogPanel().environment(\.frogKeyboardSurface, true)
            // Opening, typing and the arrow keys are instant: nothing inside the bar animates.
            .transaction { $0.animation = nil }
            .onAppear { focused = true }.onChange(of: bar.invocation) { focused = true }
    }
}

private struct CommandResultRow: View, Equatable {
    let bar: CommandBar
    let result: SearchRecord
    let iconKey: String?
    let selected: Bool
    @State private var hovering = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bar === rhs.bar && lhs.result == rhs.result && lhs.iconKey == rhs.iconKey && lhs.selected == rhs.selected
    }

    /// The keyboard's row takes the selection colour, the pointer's the hover fill, as rows in every Frog list do.
    var body: some View {
        Button {
            if let index = bar.results.firstIndex(where: { $0.id == result.id }) { bar.choose(index) }
        } label: {
            HStack(spacing: 10) {
                CommandResultIcon(bar: bar, result: result, key: iconKey)
                Text(result.title).font(FrogType.body).lineLimit(1)
                Spacer(minLength: 10)
                Text(result.subtitle).font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1).frame(maxWidth: 180, alignment: .trailing)
                Image(systemName: "return").font(.system(size: 10, weight: .semibold)).foregroundStyle(FrogStyle.muted)
                    .frame(width: 12).opacity(selected ? 1 : 0)
            }.padding(.horizontal, 8).frame(height: 36)
                .frogRowHighlight(hovering: hovering, selected: selected)
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}

private struct CommandResultIcon: View {
    let bar: CommandBar
    let result: SearchRecord
    /// The row's icon key. A pane's own icon replaces the System Settings icon of a row that is already drawn.
    let key: String?
    @State private var icon: NSImage?
    init(bar: CommandBar, result: SearchRecord, key: String?) {
        self.bar = bar; self.result = result; self.key = key
        // A cached icon is drawn at once instead of after a frame with the placeholder.
        _icon = State(initialValue: bar.cachedIcon(for: result))
    }
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable() }
            else {
                Image(systemName: result.symbol).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(result.isFrogCommand ? FrogStyle.accent : FrogStyle.muted).frame(width: 24, height: 24)
                    .background(result.isFrogCommand ? FrogStyle.accentSoft : FrogStyle.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
            }
        }.frame(width: 24, height: 24)
            .task(id: [result.id, key]) {
                guard key != nil else { icon = nil; return }
                // The icon shown stays until its replacement is read, so a changing key never flashes the symbol.
                if let loaded = await bar.icon(for: result), !Task.isCancelled { icon = loaded }
            }
    }
}

private extension SearchRecord {
    /// Frog's own pages, commands and answers, set apart from apps, windows, files and system destinations.
    var isFrogCommand: Bool { id == "features" || ["feature:", "plugin-page:", "route:", "rule:", "quick:", "layout:", "system:", "calculation:", "action:", "argument:"].contains { id.hasPrefix($0) } }
}

private extension URL {
    var abbreviatingWithTildeInPath: String { (path as NSString).abbreviatingWithTildeInPath }
}
