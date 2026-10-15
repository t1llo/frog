import AppKit
import Combine
import FrogCore
import FrogUsage

struct AppIssue: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var configuration = Configuration()
    @Published private(set) var history: [HistoryEntry] = []
    @Published var historyFilter: HistoryFilter?
    @Published private(set) var hotkeyErrors: [UUID: String] = [:]
    @Published private(set) var isProcessing = false
    /// What the running rule is doing, shown while a rule is tried in Writing or Dictation.
    @Published private(set) var status = "Ready"
    @Published private(set) var errorMessage: String?
    @Published private(set) var recentErrors: [AppIssue] = []
    private var errorDismissal: Task<Void, Never>?
    private let errorDisplayDuration: Duration
    @Published private(set) var manualResult = ""
    /// How the last rule run ended. The processing indicator and the Try sheet read this, not
    /// `errorMessage`, which any unrelated failure may have set meanwhile.
    private(set) var ruleOutcome: RuleOutcome?
    @Published private(set) var isTestingProvider = false
    @Published private(set) var startAtLogin = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var loginStatus = ""
    @Published private(set) var loginNeedsAttention = false
    @Published private(set) var windowSwitcherStatus = "Not started"
    @Published private(set) var windowSwitcherReady = false
    @Published private(set) var setupPresented = false

    var openSettings: (() -> Void)?
    private let configurationStore: ConfigurationStore
    private let historyStore: HistoryStore
    private let credentials: any CredentialStore
    private let complete: (String, Rule, ProviderConfiguration, String?) async throws -> String
    private let readKey: (UUID) throws -> String?
    private let writeClipboard: (String) -> Void
    private let registerShortcuts: Bool
    private let readAccessibility: () -> Bool
    private let readLoginStatus: @Sendable () -> LoginService.Snapshot
    private let writeLoginItem: @Sendable (Bool) throws -> Void
    private var loginStatusTask: Task<Void, Never>?
    /// Changes of the login item, done one after another off the main actor.
    private var loginWriteTask: Task<Void, Never>?
    private var loginWrites = 0
    private var loginStatusUpdatedAt: ContinuousClock.Instant?
    private var systemStatusTask: Task<Void, Never>?
    /// The wait between two refreshes of the system status: one second, or a tick a test fires.
    private let systemStatusTick: () async throws -> Void
    private let hotkeys = HotkeyManager()
    private lazy var windowSwitcher: WindowSwitcherController = {
        let controller = WindowSwitcherController { [weak self] message, ready in
            if self?.windowSwitcherStatus != message { self?.windowSwitcherStatus = message }
            if self?.windowSwitcherReady != ready { self?.windowSwitcherReady = ready }
        }
        controller.onError = { [weak self] message in self?.report(FrogError.message(message)) }
        return controller
    }()
    private var started = false
    let localModels: LocalModels
    let dictation: DictationController
    let power: StayAwakeController
    let toolkit: Toolkit
    let systemMonitor = SystemMonitor()
    let statistics: ActivityStatisticsStore
    let commandChoices: CommandChoiceStore
    let localTools: LocalToolClient
    let scripts = ScriptRunner()
    private var documentsModel: LocalDocuments?
    var documents: LocalDocuments {
        if documentsModel == nil { documentsModel = LocalDocuments(directory: configurationStore.directory.appendingPathComponent("Toolkit")) }
        return documentsModel!
    }
    var hasPendingDocumentWrites: Bool { documentsModel?.needsFlush == true }
    func flushDocuments() async -> Bool { await documentsModel?.flush() ?? true }
    private lazy var commandBar: CommandBar = {
        let bar = CommandBar(model: self, pasteboard: clipboardHistoryStore.pasteboard)
        bar.onToolUse = { [weak self] in self?.statistics.recordToolUse($0) }
        return bar
    }()
    let clipboardHistoryStore: ClipboardHistoryStore
    private var observations = Set<AnyCancellable>()
    private var dictationHistoryEpoch: UUID?
    private var recoveryHistoryEpochs: [UUID: UUID] = [:]
    static let localProviderID = UUID(uuidString: "7C05FB97-5BEF-48FD-9C28-A67605107251")!
    static let shortcutPanelID = UUID(uuidString: "85F8DE80-89BC-4506-B82D-DCFB71AFE292")!
    static let cancelRecordingID = UUID(uuidString: "E4A8A2D5-7F72-42CA-924C-9100A213D030")!
    static let clipboardHistoryID = UUID(uuidString: "E7A2D4E5-1CBC-41DB-8B3A-7114DC77943D")!
    static let commandBarID = UUID(uuidString: "76B6A364-18CC-4779-9552-9885FCE778B8")!
    static let menuBarID = UUID(uuidString: "426A0C79-8785-4B2A-96E1-5880E7853209")!
    private lazy var clipboardHistory: ClipboardHistoryController = {
        let controller = ClipboardHistoryController(pasteboard: clipboardHistoryStore.pasteboard, history: clipboardHistoryStore)
        controller.onError = { [weak self] in self?.report($0) }
        controller.onSuccessfulPaste = { [weak self] in self?.statistics.recordToolUse(.clipboardPaste) }
        return controller
    }()
    private let shortcutPanel = ShortcutReferencePanel()
    private let captureSelection: () async throws -> any CapturedTextSelection
    /// Reads an answer's selection through Accessibility before `captureSelection` is tried. Nil when a test
    /// injects only a capture.
    private let selectionReader: SelectionReading?
    /// The app an answer reads from, after the shortcut keys are released.
    private let selectionTarget: () async throws -> pid_t
    private let answerStream: (AnswerRequest) -> AsyncThrowingStream<AnswerEvent, Error>
    private let answerPresenter: AnswerPresenting
    /// Asks for the notes folder the first time an answer is saved. Nil when cancelled.
    private let chooseNotesFolder: () async -> URL?
    private var answerCapture: Task<Void, Never>?
    private let injectedSelectionWatcher: (any SelectionWatching)?
    /// The selection bubble: runs while Explain and the bubble are on and Accessibility is allowed.
    private(set) lazy var selectionWatcher: any SelectionWatching = injectedSelectionWatcher ?? makeSelectionWatcher()
    /// History as it was when the running answer started: clearing or turning it off since stops saving the answer.
    private var answerHistoryEpoch: UUID?
    private var answerHistoryWasEnabled = false
    /// Answer rules: one answer and its follow-ups at a time, in the answer panel.
    private(set) lazy var answers: AnswerController = {
        let controller = AnswerController(
            resolve: { [weak self] rule in
                guard let self else { throw CancellationError() }
                return try self.resolved(rule)
            },
            readKey: { [weak self] id in try self?.readKey(id) },
            stream: answerStream,
            presenter: answerPresenter,
            modelName: { [weak self] provider in
                provider.id == Self.localProviderID ? self?.configuration.localModel(provider.model)?.name ?? provider.name
                    : provider.modelName(provider.model)
            },
            report: { [weak self] in self?.report($0) },
            recordStatistics: { [weak self] in self?.statistics.recordRuleExecution(kind: $0) },
            copy: { [weak self] text in
                self?.writeClipboard(text)
                self?.clipboardHistoryStore.recordCopiedText(text)
            },
            record: { [weak self] in self?.recordAnswer($0) },
            updateRecord: { [weak self] in self?.updateAnswerRecord($0) ?? false },
            saveNote: { [weak self] content in
                guard let self else { throw CancellationError() }
                return try await self.saveAnswerNote(content)
            },
            notesEnabled: { [weak self] in self?.answerNotesEnabled ?? false })
        controller.onEditRule = { [weak self] _ in self?.openFeature(.explain) }
        (answerPresenter as? AnswerPanelController)?.controller = controller
        return controller
    }()
    private let processingIndicator = ProcessingIndicator()
    private var processingTask: Task<Void, Never>?
    // One handle per kind: launching an app must not cancel a system action that waits for its keys.
    private var applicationTask: Task<Void, Never>?
    private var systemActionTask: Task<Void, Never>?
    private let windowManager = WindowManager()
    private var windowActionTask: Task<Void, Never>?
    let windowLayout: WindowLayoutController
    private var historyEpoch = UUID()
    private var configurationLoadError: Error?
    private lazy var usagePreferenceWriter = UsagePreferenceWriter(store: configurationStore, initial: configuration)
    private var usagePreferenceRevision = 0
    private var legacyUsagePreferences = UsageDashboardPreferences()
    private(set) var isRecordingShortcut = false
    /// The recorders that are recording now.
    private var shortcutRecorders = Set<UUID>()

    init(dataDirectory: URL? = nil, registerShortcuts: Bool = true,
         complete: ((String, Rule, ProviderConfiguration, String?) async throws -> String)? = nil,
         credentials: (any CredentialStore)? = nil,
         readKey: ((UUID) throws -> String?)? = nil,
         writeClipboard: ((String) -> Void)? = nil,
         readAccessibility: (() -> Bool)? = nil,
         readLoginStatus: (@Sendable () -> LoginService.Snapshot)? = nil,
         writeLoginItem: (@Sendable (Bool) throws -> Void)? = nil,
         captureSelection: (() async throws -> any CapturedTextSelection)? = nil,
         selectionReader: SelectionReading? = nil,
         selectionTarget: (() async throws -> pid_t)? = nil,
         answerStream: ((AnswerRequest) -> AsyncThrowingStream<AnswerEvent, Error>)? = nil,
         answerPresenter: AnswerPresenting? = nil,
         chooseNotesFolder: (() async -> URL?)? = nil,
         selectionWatcher: (any SelectionWatching)? = nil,
         dictationController: DictationController? = nil,
         modelService: LocalModels? = nil,
         powerController: StayAwakeController? = nil,
         toolkit injectedToolkit: Toolkit? = nil,
         clipboardHistoryStore: ClipboardHistoryStore? = nil,
         localToolClient: LocalToolClient? = nil,
         errorDisplayDuration: Duration = .seconds(6),
         systemStatusTick: (() async throws -> Void)? = nil) {
        let dataDirectory = dataDirectory ?? ProcessInfo.processInfo.environment["FROG_DATA_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.registerShortcuts = registerShortcuts
        self.toolkit = injectedToolkit ?? Toolkit(showsUsageStatusItem: registerShortcuts, showsMenuBarOrganizer: registerShortcuts)
        self.statistics = ActivityStatisticsStore(directory: dataDirectory)
        self.commandChoices = CommandChoiceStore(directory: dataDirectory)
        let localTools = localToolClient ?? LocalToolClient()
        self.localTools = localTools
        self.dictation = dictationController ?? DictationController()
        self.power = powerController ?? StayAwakeController(directory: dataDirectory)
        self.clipboardHistoryStore = clipboardHistoryStore ?? ClipboardHistoryStore()
        self.errorDisplayDuration = errorDisplayDuration
        self.systemStatusTick = systemStatusTick ?? { try await Task.sleep(for: .seconds(1)) }
        let localModels = modelService ?? LocalModels(directory: dataDirectory)
        self.localModels = localModels
        self.answerStream = answerStream ?? AnswerStreams.live(localModels: localModels, localTools: localTools)
        self.answerPresenter = answerPresenter ?? (registerShortcuts ? AnswerPanelController() : SilentAnswerPresenter())
        self.chooseNotesFolder = chooseNotesFolder ?? { await Self.chooseNotesFolderInPanel() }
        self.injectedSelectionWatcher = selectionWatcher
        self.readAccessibility = readAccessibility ?? { SelectionService.isTrusted }
        self.readLoginStatus = readLoginStatus ?? { LoginService.readStatus() }
        self.writeLoginItem = writeLoginItem ?? { try LoginService.setEnabled($0) }
        self.captureSelection = captureSelection ?? { try await SelectionService().capture() }
        self.selectionReader = selectionReader ?? (captureSelection == nil ? SelectionReader() : nil)
        self.selectionTarget = selectionTarget ?? { try await SelectionService.answerTarget() }
        self.complete = complete ?? { text, rule, provider, key in
            if let kind = provider.kind.localTool {
                return try await localTools.complete(LocalToolRequest(kind: kind, text: text, rule: rule, providerModel: provider.model))
            }
            return try await LLMClient().complete(text: text, rule: rule, provider: provider, apiKey: key)
        }
        let credentials = credentials ?? KeychainStore()
        self.credentials = credentials
        self.readKey = readKey ?? { try credentials.read(providerID: $0) }
        self.writeClipboard = writeClipboard ?? { text in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        configurationStore = ConfigurationStore(directory: dataDirectory)
        historyStore = HistoryStore(directory: dataDirectory)
        windowLayout = WindowLayoutController(manager: windowManager)
        let firstConfiguration = !configurationStore.hasExistingConfiguration
        if registerShortcuts {
            do {
                setupPresented = try SetupStore(directory: historyStore.directory).needsSetup(
                    existingConfiguration: !firstConfiguration)
            } catch { report(error) }
        }
        do { configuration = try configurationStore.load() }
        catch { configurationLoadError = error; report(error) }
        localModels.updateCatalog(configuration.modelCatalog)
        if configurationLoadError == nil {
            var candidate = configuration
            if registerShortcuts {
                candidate.adoptExplicitRuleSettings(installed: localModels.installed)
                // Frog's own first configuration starts dark; a mode written in a file, System included, stays.
                if firstConfiguration, candidate.preferences.appearance?.mode == nil {
                    var appearance = candidate.preferences.appearance ?? AppearancePreferences()
                    appearance.mode = .dark
                    candidate.preferences.appearance = appearance
                }
            }
            candidate.reconcileUnavailableModels(installed: localModels.installed)
            if candidate != configuration { do { try persist(candidate) } catch { report(error) } }
        }
        localModels.onInstall = { [weak self] item in
            guard let self else { return }
            var candidate = self.configuration
            candidate.modelAdded(RuleModelSelection(modelID: item.id, category: item.kind == .audio ? .audio : .text))
            if candidate != self.configuration {
                do { try self.persist(candidate) } catch { self.report(error) }
            }
        }
        localModels.onInventoryChanged = { [weak self] in
            guard let self else { return }
            var candidate = self.configuration
            candidate.reconcileUnavailableModels(installed: self.localModels.installed)
            if candidate != self.configuration {
                do { try self.persist(candidate) } catch { self.report(error) }
            }
            self.objectWillChange.send()
        }
        refreshHistory()
        refreshSystemStatus()
        if registerShortcuts { FrogAppearance.shared.apply(configuration.preferences.appearance ?? AppearancePreferences()) }
        localModels.idleSeconds = configuration.preferences.workflowSettings.idleUnloadSeconds
        if registerShortcuts { localModels.unloadUnderMemoryPressure() }
        localModels.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        // Pages read only whether Frog dictates and which History entries it recovers. The timer, the
        // preview text and the microphones are drawn by views that observe the controller, so a tick
        // of the recording does not redraw every page.
        dictation.$phase.removeDuplicates().dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        dictation.$recoveringHistoryIDs.removeDuplicates().dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        dictation.onError = { [weak self] in self?.report($0) }
        dictation.onCopy = { [weak self] in self?.clipboardHistoryStore.recordCopiedText($0) }
        dictation.onMicrophoneChange = { [weak self] id in
            guard let self else { return }
            var preferences = self.configuration.preferences.workflowSettings
            preferences.microphoneID = id
            do { try self.saveWorkflowPreferences(preferences) } catch { self.report(error) }
        }
        dictation.externalTranscription = { [weak self] audio, rule in
            guard let self, let provider = self.configuration.providers.first(where: { $0.id == rule.action?.audioProviderID }),
                  let id = rule.action?.audioModelID, provider.models.contains(where: { $0.id == id && $0.category == .audio }) else {
                throw FrogError.message("Choose a configured speech-to-text model for this rule.")
            }
            return try await SpeechClient().transcribe(samples: audio, provider: provider, model: id, language: rule.action?.transcriptionLanguage, apiKey: self.readKey(provider.id))
        }
        dictation.cleanup = { [weak self] text, rule in
            guard let self else { throw CancellationError() }
            let provider = try self.resolved(rule)
            if provider.id != Self.localProviderID {
                return try await self.complete(text, rule, provider, provider.kind.localTool == nil ? self.readKey(provider.id) : nil)
            }
            return try await self.localModels.complete(text, instructions: rule.expandedInstructions(), modelID: provider.model)
        }
        dictation.localCleanupModel = { [weak self] rule in
            guard let self else { throw CancellationError() }
            let provider = try self.resolved(rule)
            return provider.id == Self.localProviderID ? provider.model : nil
        }
        dictation.onSuccessfulDelivery = { [weak self] seconds, text in
            self?.statistics.recordDictation(recordingSeconds: seconds, text: text, rule: .dictation)
        }
        dictation.onTranscript = { [weak self] id, rule, original, result in
            guard let self else { return }
            if self.configuration.preferences.historyEnabled, self.dictationHistoryEpoch == self.historyEpoch {
                var entry = HistoryEntry(id: id, originalText: original, processedText: result, ruleName: rule.name, providerName: "Transcription", model: rule.action?.audioModelID ?? self.configuration.preferences.workflowSettings.audioModelID)
                entry.category = .audio
                do { if let retained = try self.historyStore.append(entry, preferences: self.configuration.preferences) { self.adoptHistory(retained) } }
                catch { self.report(error) }
            }
        }
        dictation.onInterruption = { [weak self] in self?.saveInterruption($0) ?? false }
        dictation.onHistoryRecovered = { [weak self] in self?.finishHistoryRecovery(id: $0, result: $1) }
        applyUsagePreferences(configuration.preferences)
        toolkit.onOpenUsage = { [weak self] in self?.showSettings() }
        toolkit.onOpenMenuBar = { [weak self] in self?.showSettings() }
        toolkit.menuBarOrganizer.onSettingsChange = { [weak self] value in
            guard let self else { return }
            var preferences = self.configuration.preferences
            var toolkit = preferences.toolkitSettings
            toolkit.menuBar = value; preferences.toolkit = toolkit
            do { try self.savePreferences(preferences) }
            catch { self.report(error) }
        }
        scripts.onSuccessfulRun = { [weak self] in self?.statistics.recordToolUse(.scriptRun) }
        toolkit.onUsagePreferencesChange = { [weak self] value in
            guard let self else { return }
            var preferences = self.configuration.preferences
            var toolkit = preferences.toolkitSettings
            toolkit.usage = UsageDisplayPreferences(provider: value.provider, range: value.range, metric: value.metric, allDevices: value.allDevices, loginSource: value.loginSource,
                                                    claudeAccounts: value.claudeAccounts, claudeAccountsView: value.claudeAccountsView, claudeAccountsMenuBar: value.claudeAccountsMenuBar)
            preferences.toolkit = toolkit
            // Display choices do not change collectors, shortcuts, appearance or history.
            do {
                if let error = self.configurationLoadError { throw FrogError.message(error.localizedDescription) }
                let writer = self.usagePreferenceWriter
                var candidate = self.configuration; candidate.preferences = preferences
                self.usagePreferenceRevision += 1
                let revision = self.usagePreferenceRevision
                self.configuration = candidate
                writer.save(candidate) { [weak self] error, saved in
                    Task { @MainActor [weak self] in
                        guard let self, self.usagePreferenceRevision == revision else { return }
                        self.restoreUsagePreferences(saved)
                        self.report(error)
                    }
                }
            }
            catch { self.applyUsagePreferences(self.configuration.preferences); self.report(error) }
        }
        toolkit.apply(configuration.preferences)
        commandChoices.configure(enabled: Self.learnsCommandChoices(configuration.preferences))
        systemMonitor.configure(enabled: configuration.preferences.featureEnabled(.systemMonitor))
        legacyUsagePreferences = toolkit.usage()?.preferences ?? UsageDashboardPreferences()
        power.configureFeature(enabled: configuration.preferences.featureEnabled(.stayAwake))
        toolkit.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        windowLayout.onError = { [weak self] in self?.report($0) }
        windowLayout.onToolUse = { [weak self] in self?.statistics.recordToolUse($0) }
        toolkit.onDisable = { [weak self] feature in
            guard let self else { return }
            self.commandBar.hide()
            switch feature {
            case .writing: self.processingTask?.cancel(); self.processingIndicator.hide()
            case .dictation: self.dictation.cancel(); self.invalidateHistoryRecovery()
            case .applicationShortcuts: self.applicationTask?.cancel(); self.systemActionTask?.cancel(); if !self.configuration.preferences.windowActionsEnabled { self.windowActionTask?.cancel() }; self.shortcutPanel.hide()
            case .scripts: self.scripts.stop()
            case .commandBar: self.commandBar.stop()
            // slot: explain
            case .explain: self.answerCapture?.cancel(); self.answers.close(); self.selectionWatcher.stop()
            // slot: windows
            case .windows: if !self.configuration.preferences.windowActionsEnabled { self.windowActionTask?.cancel() }; self.windowLayout.stop()
            // slot: cleaner
            // slot: emoji-picker
            // slot: processes
            // slot: color-picker
            // slot: quicklinks
            default: break
            }
        }
    }

    func showSetup() { setupPresented = true }
    var configurationFileURL: URL { configurationStore.textFile }

    func openConfiguration() {
        do {
            drainUsagePreferences()
            if !FileManager.default.fileExists(atPath: configurationFileURL.path) {
                try configurationStore.save(configuration)
            }
            NSWorkspace.shared.open([configurationFileURL], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: NSWorkspace.OpenConfiguration())
        } catch { report(error) }
    }

    func reloadConfiguration() throws {
        guard !isProcessing, !isTestingProvider, !dictation.active else {
            throw FrogError.message("Finish or cancel the current request before reloading configuration.")
        }
        drainUsagePreferences()
        let candidate = try configurationStore.load { try self.validateForThisMac($0, change: .reload) }
        applyConfiguration(candidate)
        usagePreferenceWriter.didSave(candidate)
        configurationLoadError = nil
        localModels.idleSeconds = candidate.preferences.workflowSettings.idleUnloadSeconds
        if !candidate.preferences.historyEnabled { invalidateHistoryRecovery() }
        if !candidate.preferences.showProcessingIndicator { processingIndicator.hide() }
        registerHotkeys(); shortcutPanel.hide()
        configureWindowSwitcher(); configureSelectionWatcher(); configureClipboardHistory(); refreshHistory()
        dismissError()
    }
    func finishSetup() {
        do { try SetupStore(directory: historyStore.directory).complete(); setupPresented = false }
        catch { report(error) }
    }

    func start() {
        started = true
        startSystemStatusMonitoring()
        if registerShortcuts, configurationLoadError == nil,
           !configuration.rules.contains(where: { $0.category == .audio }), configuration.preferences.workflows == nil {
            var candidate = configuration
            candidate.rules.append(.dictationPreset)
            candidate.preferences.workflows = WorkflowPreferences()
            do { try persist(candidate) } catch { report(error) }
        }
        if registerShortcuts, configurationLoadError == nil, configuration.preferences.workflowSettings.dictationDefaultsVersion == nil {
            var candidate = configuration
            candidate.adoptClipboardDictationDefaults()
            do { try persist(candidate) } catch { report(error) }
        }
        if registerShortcuts, configurationLoadError == nil { adoptExplainPresetIfNeeded() }
        registerHotkeys()
        configureWindowSwitcher()
        configureSelectionWatcher()
        configureClipboardHistory()
        if configuration.preferences.featureEnabled(.commandBar) { commandBar.warm() }
        configureWindowLayout()
    }

    func shutdown() {
        drainUsagePreferences()
        statistics.waitForWrites()
        commandChoices.waitForWrites()
        systemMonitor.stop()
        commandBar.stop()
        toolkit.stop()
        systemStatusTask?.cancel(); systemStatusTask = nil
        loginStatusTask?.cancel(); loginStatusTask = nil
        loginWriteTask?.cancel(); loginWriteTask = nil
        loginStatusUpdatedAt = nil
        invalidateHistoryRecovery()
        dictation.cancel(); localModels.shutdown(); shortcutPanel.hide()
        started = false
        if registerShortcuts { windowSwitcher.stop() }
        selectionWatcher.stop()
        if registerShortcuts { clipboardHistory.stop() }
        clipboardHistoryStore.configure(enabled: false)
        processingIndicator.hide()
        processingTask?.cancel()
        applicationTask?.cancel()
        systemActionTask?.cancel()
        windowActionTask?.cancel()
        windowLayout.stop()
        hotkeys.unregister()
    }

    func showSettings() { refreshSystemStatus(); openSettings?() }
    private func applyUsagePreferences(_ preferences: Preferences) {
        guard let value = preferences.toolkitSettings.usage else { return }
        toolkit.applyUsagePreferences(UsageDashboardPreferences(provider: value.provider, range: value.range, metric: value.metric, allDevices: value.allDevices, loginSource: value.loginSource,
                                                                claudeAccounts: value.claudeAccounts, claudeAccountsView: value.claudeAccountsView, claudeAccountsMenuBar: value.claudeAccountsMenuBar))
    }

    func openFeature(_ feature: FeatureID) { toolkit.select(.feature(feature)); showSettings() }
    func openClipboardHistoryPage() { historyFilter = .clipboard; toolkit.select(.history); showSettings() }
    func showCommandBar() {
        guard !isRecordingShortcut else { return }
        commandBar.show()
    }
    func setFeature(_ feature: FeatureID, enabled: Bool) async throws {
        if feature == .stayAwake, !enabled {
            await power.waitForOperation()
            if power.ownsSession {
                power.setEnabled(false); await power.waitForOperation()
                guard !power.ownsSession else { throw FrogError.message(power.error ?? "Restore sleep before disabling Stay awake.") }
            }
        }
        var preferences = configuration.preferences
        preferences.setFeature(feature, enabled: enabled)
        try savePreferences(preferences)
        if feature == .explain, enabled { adoptExplainPresetIfNeeded() }
    }
    /// Turning Explain on creates the Explain rule once, with the newest text model still available.
    private func adoptExplainPresetIfNeeded() {
        guard configuration.preferences.featureEnabled(.explain),
              configuration.preferences.workflowSettings.explainPresetVersion == nil else { return }
        var candidate = configuration
        candidate.adoptExplainPreset(installed: localModels.installed)
        do { try persist(candidate) } catch { report(error) }
    }
    func ruleFeatureEnabled(_ rule: Rule) -> Bool {
        configuration.preferences.ruleFeatureEnabled(rule)
    }
    func openDocument(_ document: UtilityDocument) {
        let feature: FeatureID = switch document.kind { case .note: .scratchpad; case .snippet: .snippets; case .shelf: .shelf; case .script: .scripts }
        guard configuration.preferences.featureEnabled(feature) else { return }
        documents.selection[document.kind] = document.id
        openFeature(feature)
    }
    func runScript(_ document: UtilityDocument) {
        guard configuration.preferences.featureEnabled(.scripts), documents.items.contains(document) else { return }
        scripts.run(document)
    }
    func runRuleFromCommandBar(_ id: UUID) {
        guard let rule = configuration.rules.first(where: { $0.id == id && $0.enabled }), ruleFeatureEnabled(rule) else { return }
        switch rule.category {
        case .text: processSelection(ruleID: id)
        case .audio: startDictation(rule)
        case .application: launchApplication(rule)
        case .window: manageWindow(rule)
        case .system: performSystemAction(rule)
        }
    }
    func runWindowAction(_ action: WindowAction) {
        guard configuration.preferences.windowActionsEnabled else { return }
        manageWindow(action.rule)
    }
    func runSystemAction(_ action: SystemAction) {
        guard configuration.preferences.featureEnabled(.applicationShortcuts) else { return }
        performSystemAction(action.rule)
    }

    func refreshSystemStatus(forceLoginStatus: Bool = false) {
        let trusted = readAccessibility()
        if accessibilityGranted != trusted { accessibilityGranted = trusted }
        if started { configureWindowSwitcher(); configureSelectionWatcher() }
        refreshLoginStatus(force: forceLoginStatus)
    }

    private func refreshLoginStatus(force: Bool) {
        // A read begun before a pending change lands would snap the toggle back; the change reads afterwards.
        guard loginWriteTask == nil else { return }
        if force {
            loginStatusTask?.cancel(); loginStatusTask = nil
        } else {
            guard loginStatusTask == nil else { return }
            if let loginStatusUpdatedAt, loginStatusUpdatedAt.duration(to: .now) < .seconds(30) { return }
        }
        // ServiceManagement performs synchronous IPC that can take hundreds of
        // milliseconds. Neither the UI nor shortcut delivery may wait for it.
        loginStatusTask = Task { [weak self, readLoginStatus] in
            let result = await Task.detached(priority: .utility) { readLoginStatus() }.value
            guard !Task.isCancelled, let self else { return }
            self.loginStatusTask = nil
            self.loginStatusUpdatedAt = .now
            if self.startAtLogin != result.enabled { self.startAtLogin = result.enabled }
            if self.loginStatus != result.text { self.loginStatus = result.text }
            if self.loginNeedsAttention != result.needsAttention { self.loginNeedsAttention = result.needsAttention }
        }
    }

    func startSystemStatusMonitoring() {
        guard systemStatusTask == nil else { return }
        systemStatusTask = Task { [weak self, systemStatusTick] in
            while !Task.isCancelled {
                guard self != nil else { return }
                self?.refreshSystemStatus()
                do { try await systemStatusTick() } catch { return }
            }
        }
    }

    isolated deinit { systemStatusTask?.cancel(); loginStatusTask?.cancel(); loginWriteTask?.cancel() }

    func setStartAtLogin(_ enabled: Bool) {
        // Registering performs the same slow ServiceManagement IPC as reading the status. The toggle
        // shows the choice at once, and the status is read again once macOS has the change.
        if startAtLogin != enabled { startAtLogin = enabled }
        loginStatusTask?.cancel(); loginStatusTask = nil
        loginWrites += 1
        let write = loginWrites
        let previous = loginWriteTask
        loginWriteTask = Task { [weak self, writeLoginItem] in
            await previous?.value
            let result = await Task.detached(priority: .userInitiated) { Result { try writeLoginItem(enabled) } }.value
            guard !Task.isCancelled, let self else { return }
            if write == self.loginWrites {
                self.loginWriteTask = nil
                self.refreshSystemStatus(forceLoginStatus: true)
            }
            if case .failure(let error) = result { self.report(error) }
        }
    }

    func report(_ error: Error) {
        errorDismissal?.cancel()
        let message = error.localizedDescription
        errorMessage = message
        recentErrors.insert(AppIssue(message: message), at: 0)
        recentErrors = Array(recentErrors.prefix(100))
        let duration = errorDisplayDuration
        errorDismissal = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            self?.errorMessage = nil
        }
    }
    func dismissError() { errorDismissal?.cancel(); errorDismissal = nil; errorMessage = nil }
    func clearRecentErrors() { recentErrors = [] }
    func waitForErrorDismissal() async { await errorDismissal?.value }

    private func persist(_ candidate: Configuration) throws {
        if let error = configurationLoadError {
            throw FrogError.message("Settings could not be loaded, so they have not been overwritten. Repair the file in \(configurationStore.directory.path) and use Settings → Configuration → Reload, or import a valid configuration. \(error.localizedDescription)")
        }
        drainUsagePreferences()
        try ConfigurationFile.validate(candidate)
        try configurationStore.save(candidate)
        usagePreferenceWriter.didSave(candidate)
        applyConfiguration(candidate)
    }

    private func drainUsagePreferences() {
        let failure = usagePreferenceWriter.drain()
        usagePreferenceRevision += 1
        if let failure { restoreUsagePreferences(failure.saved); report(failure.error) }
    }
    private func restoreUsagePreferences(_ saved: UsageDisplayPreferences?) {
        configuration.preferences.toolkit?.usage = saved
        if saved == nil { toolkit.applyUsagePreferences(legacyUsagePreferences) }
        else { applyUsagePreferences(configuration.preferences) }
    }

    private func applyConfiguration(_ candidate: Configuration) {
        configuration = candidate
        applyUsagePreferences(candidate.preferences)
        toolkit.apply(candidate.preferences)
        systemMonitor.configure(enabled: candidate.preferences.featureEnabled(.systemMonitor))
        if candidate.preferences.toolkit?.usage == nil, let usage = toolkit.usage() { legacyUsagePreferences = usage.preferences }
        if candidate.preferences.featureEnabled(.commandBar) { commandBar.warm() }
        // Turning the switch or the Command bar off, here or in the configuration file, forgets what was learned.
        commandChoices.configure(enabled: Self.learnsCommandChoices(candidate.preferences))
        power.configureFeature(enabled: candidate.preferences.featureEnabled(.stayAwake))
        localModels.updateCatalog(candidate.modelCatalog)
        if registerShortcuts { FrogAppearance.shared.apply(candidate.preferences.appearance ?? AppearancePreferences()) }
        configureWindowLayout()
    }

    private func configureWindowLayout() { windowLayout.configure(configuration, active: started && registerShortcuts) }

    func saveRule(_ rule: Rule) throws {
        guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              rule.category.isShortcut || !rule.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FrogError.message("Give this rule a name and instructions.")
        }
        if rule.instructions.contains("{{language}}") && rule.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FrogError.message("Set a target language for this translation rule.")
        }
        if let providerID = rule.providerID, !configuration.providers.contains(where: { $0.id == providerID }) {
            throw FrogError.message("The rule's provider no longer exists. Choose another provider.")
        }
        if let hotkey = rule.hotkey, let issue = HotkeyManager.validationError(hotkey) {
            throw FrogError.message(issue)
        }
        if rule.enabled, let hotkey = rule.hotkey,
           let conflict = configuration.rules.first(where: { $0.id != rule.id && $0.enabled && $0.hotkey == hotkey }) {
            throw FrogError.message("That hotkey is already assigned to \(conflict.name).")
        }
        let rule = configuration.reconcilingModels(in: rule, installed: localModels.installed)
        var candidate = configuration
        if let index = candidate.rules.firstIndex(where: { $0.id == rule.id }) { candidate.rules[index] = rule }
        else { candidate.rules.append(rule) }
        try persist(candidate)
        registerHotkeys()
        configureWindowSwitcher()
    }

    func addLocalModel(_ item: LocalModelDescriptor) throws {
        var candidate = configuration
        guard try candidate.addLocalModel(item) else { return }
        try persist(candidate)
    }

    func removeLocalModelSource(_ item: LocalModelDescriptor) throws {
        guard !localModels.installed.contains(item.id), localModels.progress[item.id] == nil else {
            throw FrogError.message("Delete the downloaded model before removing its source.")
        }
        var candidate = configuration
        candidate.removeLocalModelSource(item.id)
        try persist(candidate)
    }

    func deleteLocalModel(_ item: LocalModelDescriptor) async throws {
        try await localModels.remove(item.id)
        var candidate = configuration
        candidate.modelsRemoved([RuleModelSelection(modelID: item.id, category: item.kind == .audio ? .audio : .text)], installed: localModels.installed)
        // The inventory change may already have saved the same repair; a model no rule names needs no save.
        if candidate != configuration { try persist(candidate) }
    }

    func deleteRule(id: UUID) throws {
        var candidate = configuration
        candidate.rules.removeAll { $0.id == id }
        try persist(candidate)
        registerHotkeys()
        configureWindowSwitcher()
    }

    func hasAPIKey(_ id: UUID) -> Bool {
        guard configuration.providers.first(where: { $0.id == id })?.kind.localTool == nil else { return false }
        return ((try? readKey(id)) ?? "").isEmpty == false
    }

    func useLocalTool(_ kind: LocalToolKind, model: String) throws {
        let providerKind: ProviderKind = switch kind { case .claudeCode: .claudeCode; case .codex: .codex; case .opencode: .opencode }
        let id = model.isEmpty ? LocalToolKind.defaultModelID : model
        var provider = configuration.providers.first { $0.kind == providerKind }
            ?? ProviderConfiguration(name: kind.title, kind: providerKind)
        if !provider.models.contains(where: { $0.id == id }) { provider.models.append(ProviderModel(id: id)) }
        provider.model = id
        try saveProvider(provider, apiKey: nil, clearKey: false)
    }

    func saveProvider(_ provider: ProviderConfiguration, apiKey: String?, clearKey: Bool) throws {
        try ConfigurationFile.validate(provider: provider)
        guard provider.kind.localTool == nil || (apiKey ?? "").isEmpty else { throw FrogError.message("Coding tools use their own login, without a Frog API key.") }
        var candidate = configuration
        let previousModels = candidate.providers.first(where: { $0.id == provider.id })?.models ?? []
        if let index = candidate.providers.firstIndex(where: { $0.id == provider.id }) { candidate.providers[index] = provider }
        else { candidate.providers.append(provider) }
        if candidate.defaultProviderID == nil { candidate.defaultProviderID = provider.id }
        let removed = previousModels.filter { old in !provider.models.contains { $0.id == old.id && $0.category == old.category } }
        candidate.modelsRemoved(removed.map { RuleModelSelection(providerID: provider.id, modelID: $0.id, category: $0.category) }, installed: localModels.installed)
        if candidate.explicitRuleModels == true {
            for item in provider.models where !previousModels.contains(where: { $0.id == item.id && $0.category == item.category }) {
                candidate.modelAdded(RuleModelSelection(providerID: provider.id, modelID: item.id, category: item.category))
            }
        }
        try ConfigurationFile.validate(candidate)
        let keyChanged = clearKey || !(apiKey ?? "").isEmpty
        let oldKey = keyChanged ? try credentials.read(providerID: provider.id) : nil
        if clearKey { try credentials.delete(providerID: provider.id) }
        else if let apiKey, !apiKey.isEmpty { try credentials.save(apiKey, providerID: provider.id) }
        do { try persist(candidate) }
        catch {
            if keyChanged {
                do {
                    if let oldKey { try credentials.save(oldKey, providerID: provider.id) }
                    else { try credentials.delete(providerID: provider.id) }
                } catch { report(FrogError.message("Settings could not be saved and the previous key could not be restored. Re-enter the key before retrying.")) }
            }
            throw error
        }
    }

    func deleteProvider(id: UUID) throws {
        var candidate = configuration
        let removed = candidate.providers.first(where: { $0.id == id })?.models ?? []
        candidate.providers.removeAll { $0.id == id }
        let removedDefault = candidate.defaultProviderID == id
        if removedDefault { candidate.defaultProviderID = candidate.providers.first?.id }
        candidate.modelsRemoved(removed.map { RuleModelSelection(providerID: id, modelID: $0.id, category: $0.category) }, installed: localModels.installed)
        for index in candidate.rules.indices {
            if candidate.rules[index].providerID == id || (candidate.explicitRuleModels != true && removedDefault && configuration.rules[index].providerID == nil) {
                candidate.rules[index].providerID = nil
                candidate.rules[index].model = ""
                candidate.rules[index].preset = false
            }
        }
        // Persist first: a Keychain deletion failure is explicit and can be retried by re-adding the provider ID.
        let previous = configuration
        try persist(candidate)
        do { if previous.providers.first(where: { $0.id == id })?.kind.localTool == nil { try credentials.delete(providerID: id) } }
        catch {
            try? persist(previous)
            throw error
        }
    }

    func setDefaultProvider(id: UUID?, activate: Bool = true) throws {
        if let id, !configuration.providers.contains(where: { $0.id == id }) { throw FrogError.message("Choose an existing provider.") }
        var candidate = configuration; candidate.defaultProviderID = id
        if activate { var workflow = candidate.preferences.workflowSettings; workflow.textSource = .provider; candidate.preferences.workflows = workflow }
        try persist(candidate)
    }

    func testProvider(_ provider: ProviderConfiguration, apiKey: String?) async throws -> String {
        guard !isTestingProvider else { throw FrogError.message("A provider test is already running.") }
        try ConfigurationFile.validate(provider: provider)
        isTestingProvider = true
        defer { isTestingProvider = false }
        let key = provider.kind.localTool != nil ? nil : (apiKey?.isEmpty == false) ? apiKey : try credentials.read(providerID: provider.id)
        if let textModel = provider.models.first(where: { $0.category == .text }) {
            var test = provider; test.model = textModel.id
            _ = try await complete("Reply with OK.", Rule(name: "Connection test", instructions: "Reply briefly to the user."), test, key)
            return "Connected using \(textModel.name)."
        }
        // Only speech models: the service is asked for its model list, which checks the endpoint and key.
        try await LLMClient().checkConnection(provider: provider, apiKey: key)
        return "Connected. Transcription is checked when you record."
    }

    func discoverModels(_ provider: ProviderConfiguration, apiKey: String?) async throws -> [ProviderModel] {
        if let kind = provider.kind.localTool {
            return try await localTools.models(for: kind).map { ProviderModel(id: $0.id.isEmpty ? LocalToolKind.defaultModelID : $0.id, name: $0.name) }
        }
        let key = (apiKey?.isEmpty == false) ? apiKey : try credentials.read(providerID: provider.id)
        return try await LLMClient().localModels(provider: provider, apiKey: key)
    }

    private enum ConfigurationChange { case reload, preferences, `import` }
    /// What FrogCore cannot judge: a global shortcut that macOS or the focused app keeps for itself,
    /// and a configuration that turns Stay awake off while it keeps this Mac awake.
    private func validateForThisMac(_ candidate: Configuration, change: ConfigurationChange) throws {
        guard candidate.preferences.featureEnabled(.stayAwake) || (!power.ownsSession && !power.isBusy) else {
            switch change {
            case .reload: throw FrogError.message("Restore sleep before reloading a configuration that disables Stay awake.")
            case .preferences: throw FrogError.message("Restore sleep before disabling Stay awake.")
            case .import: throw FrogError.message("Turn off the active Stay awake session before importing a configuration that disables it.")
            }
        }
        // Saving preferences keeps the rules; a rule shortcut that cannot be registered shows on its rule.
        if change != .preferences {
            for rule in candidate.rules {
                if let key = rule.hotkey, let issue = HotkeyManager.validationError(key) { throw FrogError.message(issue) }
            }
        }
        let workflow = candidate.preferences.workflowSettings, toolkit = candidate.preferences.toolkitSettings
        for key in [workflow.shortcutPanelHotkey, workflow.cancelRecordingHotkey, toolkit.effectiveCommandBarHotkey, toolkit.menuBar?.hotkey].compactMap({ $0 }) {
            if let issue = HotkeyManager.validationError(key) { throw FrogError.message(issue) }
        }
        if let issue = HotkeyManager.validationError(workflow.effectiveClipboardHistoryHotkey, purpose: .clipboardHistory) { throw FrogError.message(issue) }
        if let issue = HotkeyManager.validationError(toolkit.effectiveWindowSwitcherHotkey, purpose: .windowSwitcher) { throw FrogError.message(issue) }
        for (name, key) in toolkit.windows?.shortcuts ?? [:] where WindowCommand(rawValue: name) != nil {
            if let issue = HotkeyManager.validationError(key) { throw FrogError.message(issue) }
        }
    }

    func savePreferences(_ preferences: Preferences) throws {
        var candidate = configuration; candidate.preferences = preferences
        try validateForThisMac(candidate, change: .preferences)
        let historyChanged = preferences.historyEnabled != configuration.preferences.historyEnabled || preferences.historyLimit != configuration.preferences.historyLimit || preferences.historyRetentionDays != configuration.preferences.historyRetentionDays
        let previous = configuration
        try persist(candidate)
        if !preferences.historyEnabled { invalidateHistoryRecovery() }
        if !preferences.showProcessingIndicator { processingIndicator.hide() }
        configureWindowSwitcher()
        configureSelectionWatcher()
        configureClipboardHistory()
        localModels.idleSeconds = preferences.workflowSettings.idleUnloadSeconds
        if Self.registersShortcutsAgain(previous: previous, current: configuration, failed: !hotkeyErrors.isEmpty, holding: hotkeys.isHolding) { registerHotkeys(); shortcutPanel.hide() }
        // Only these settings decide what is kept; any other save need not read the history file.
        if historyChanged { refreshHistory() }
    }

    /// Changes toolkit settings through `ensureToolkit`, so a missing toolkit is created the way Features creates it.
    func updateToolkit(_ change: (inout ToolkitPreferences) -> Void) throws {
        var preferences = configuration.preferences
        preferences.ensureToolkit()
        change(&preferences.toolkit!)
        try savePreferences(preferences)
    }

    /// Learn from your choices counts only while the Command bar is on.
    static func learnsCommandChoices(_ preferences: Preferences) -> Bool {
        preferences.featureEnabled(.commandBar) && preferences.toolkitSettings.commandBarSettings.learnChoices
    }
    func forgetCommandChoices() { commandChoices.forget() }

    /// Gives every window layout and command without a shortcut the suggested one, where it is free.
    func applySuggestedWindowShortcuts() throws -> WindowShortcutScheme.Result {
        let taken = Self.windowSwitcherChords(configuration.preferences)
        let result = WindowShortcutScheme.apply(to: configuration, groups: [.simple], taken: taken)
        guard !result.added.isEmpty else { return result }
        for key in Set(WindowShortcutScheme.actions.values).union(WindowShortcutScheme.commands.values) {
            if let issue = HotkeyManager.validationError(key) { throw FrogError.message(issue) }
        }
        try persist(result.configuration)
        registerHotkeys()
        configureWindowSwitcher()
        return result
    }

    /// The switcher's chord and the same with Shift, which cycles backward, while the switcher is on:
    /// what `windowSwitcherStep` treats as a conflict, and validation cannot see.
    static func windowSwitcherChords(_ preferences: Preferences) -> Set<Hotkey> {
        guard preferences.windowSwitcherEnabled else { return [] }
        let key = preferences.toolkitSettings.effectiveWindowSwitcherHotkey
        return [key, Hotkey(keyCode: key.keyCode, modifiers: key.modifiers | 512)]
    }

    func useCommandBarShortcut(_ hotkey: Hotkey) throws {
        var preferences = configuration.preferences
        preferences.setFeature(.commandBar, enabled: true)
        preferences.toolkit?.commandBarHotkey = hotkey
        let unchanged = preferences.toolkit == configuration.preferences.toolkit
        try savePreferences(preferences)
        // The user may have just freed this same shortcut in System Settings.
        if unchanged { registerHotkeys() }
    }

    func refreshHistory() {
        do { adoptHistory(try historyStore.load(preferences: configuration.preferences)) }
        catch { report(error) }
    }
    /// Takes over what the store kept after a change, which saves reading the file a second time.
    private func adoptHistory(_ retained: [HistoryEntry]) {
        // Publishing an equal array would still redraw every view that observes the model.
        if history != retained { history = retained }
        let ids = Set(retained.map(\.id))
        for id in Array(recoveryHistoryEpochs.keys) where !ids.contains(id) {
            recoveryHistoryEpochs[id] = nil; dictation.cancelHistoryRecovery(id: id)
        }
    }
    var historyFileURL: URL { historyStore.directory.appendingPathComponent("history.json") }
    /// How many saved entries saving these preferences would delete. A history that cannot be read loses nothing.
    func historyEntriesDropped(by preferences: Preferences) -> Int {
        (try? historyStore.droppedCount(changing: configuration.preferences, to: preferences)) ?? 0
    }
    func deleteHistory(id: UUID) throws {
        if clipboardHistoryStore.entries.contains(where: { $0.id == id }) { clipboardHistoryStore.delete(id: id); return }
        adoptHistory(try historyStore.delete(id: id, preferences: configuration.preferences))
    }
    func clearHistory() throws {
        clipboardHistoryStore.clear(); invalidateHistoryRecovery()
        try historyStore.clear(); refreshHistory()
    }

    private func invalidateHistoryRecovery() {
        historyEpoch = UUID(); recoveryHistoryEpochs = [:]
        dictation.cancelHistoryRecovery()
    }

    private func saveInterruption(_ interruption: DictationInterruption) -> Bool {
        guard configuration.preferences.historyEnabled, dictationHistoryEpoch == historyEpoch else { return false }
        do {
            if interruption.transcriptPublished {
                // Delivery may be interrupted after the completed result was already saved.
                if var entry = history.first(where: { $0.id == interruption.id }) {
                    entry.interruption = interruption.reason; entry.transcriptState = .complete
                    try historyStore.update(entry, preferences: configuration.preferences)
                    refreshHistory()
                }
                return false
            }
            var entry = HistoryEntry(id: interruption.id, originalText: interruption.text, processedText: interruption.text,
                                     ruleName: interruption.rule.name, providerName: "Transcription",
                                     model: interruption.rule.action?.audioModelID ?? configuration.preferences.workflowSettings.audioModelID)
            entry.category = .audio; entry.interruption = interruption.reason; entry.transcriptState = .partial
            guard let retained = try historyStore.append(entry, preferences: configuration.preferences) else { return false }
            recoveryHistoryEpochs[entry.id] = historyEpoch
            adoptHistory(retained)
            return recoveryHistoryEpochs[entry.id] != nil
        } catch { report(error); return false }
    }

    private func finishHistoryRecovery(id: UUID, result: Result<String, Error>) {
        guard recoveryHistoryEpochs.removeValue(forKey: id) == historyEpoch,
              configuration.preferences.historyEnabled, var entry = history.first(where: { $0.id == id }) else { return }
        switch result {
        case .success(let text):
            entry.originalText = text; entry.processedText = text; entry.transcriptState = .complete
        case .failure(let error):
            entry.transcriptState = .failed
            report(FrogError.message("Interrupted recording transcription failed. \(error.localizedDescription)"))
        }
        do { try historyStore.update(entry, preferences: configuration.preferences); refreshHistory() }
        catch { report(error) }
    }

    func exportConfiguration(to url: URL) throws {
        guard configurationLoadError == nil else { throw FrogError.message("Repair the saved settings before exporting them.") }
        drainUsagePreferences()
        try ConfigurationFile.write(configuration, to: url)
    }

    func importConfiguration(_ imported: Configuration) throws {
        guard !isProcessing, !isTestingProvider, !dictation.active else { throw FrogError.message("Finish or cancel the current request before importing a configuration.") }
        // As when saving: the Mac's check first, so a shortcut is refused in the words Settings uses.
        try validateForThisMac(imported, change: .import)
        try ConfigurationFile.validate(imported)
        var candidate = imported
        var remapped: [UUID: UUID] = [:]
        for index in candidate.providers.indices {
            let incoming = candidate.providers[index]
            // Reuse keys only for an already-known connection with the same service and endpoint.
            let matchesExisting = configuration.providers.contains {
                $0.id == incoming.id && $0.kind == incoming.kind && $0.endpoint == incoming.endpoint
            }
            if !matchesExisting {
                let newID = UUID()
                remapped[incoming.id] = newID
            }
        }
        candidate.remapProviderIDs(remapped)
        candidate.adoptExplicitRuleSettings(installed: localModels.installed)
        drainUsagePreferences()
        try configurationStore.replaceFromImport(candidate)
        usagePreferenceWriter.didSave(candidate)
        applyConfiguration(candidate)
        configurationLoadError = nil
        localModels.idleSeconds = candidate.preferences.workflowSettings.idleUnloadSeconds
        errorMessage = nil
        invalidateHistoryRecovery()
        registerHotkeys()
        configureWindowSwitcher()
        configureSelectionWatcher()
        if registerShortcuts { clipboardHistory.stop() }
        clipboardHistoryStore.configure(enabled: false)
        configureClipboardHistory()
        refreshHistory()
    }

    /// Clicking a second recorder starts it before the first notices that it lost the keyboard,
    /// so shortcuts go off with the first recorder and come back only when the last one has ended.
    func beginShortcutRecording(_ id: UUID) {
        guard shortcutRecorders.insert(id).inserted, shortcutRecorders.count == 1 else { return }
        setShortcutRecording(true)
    }

    /// Harmless for a recorder that is not recording: one reports its end when it stops and again when it leaves the screen.
    func endShortcutRecording(_ id: UUID) {
        guard shortcutRecorders.remove(id) != nil, shortcutRecorders.isEmpty else { return }
        setShortcutRecording(false)
    }

    private func setShortcutRecording(_ recording: Bool) {
        toolkit.menuBarOrganizer.setShortcutRecording(recording)
        if recording { commandBar.hide() }
        if recording { dictation.cancel() }
        if recording, registerShortcuts { clipboardHistory.cancel() }
        isRecordingShortcut = recording
        if recording { hotkeys.unregister() }
        else { registerHotkeys() }
        configureWindowSwitcher()
    }

    /// What configuring the window switcher comes to. The status refresh asks once a second.
    enum WindowSwitcherStep: Equatable {
        /// Configure it from the preferences.
        case configure
        /// Stop it and say why: another shortcut takes its chord.
        case stop(String)
        /// Nothing: it is stopped for that conflict, and Settings says so already.
        case none
    }

    static func windowSwitcherStep(_ configuration: Configuration, status: String, ready: Bool) -> WindowSwitcherStep {
        let preferences = configuration.preferences
        let switcherHotkey = preferences.toolkitSettings.effectiveWindowSwitcherHotkey
        func conflicts(_ hotkey: Hotkey) -> Bool {
            hotkey.keyCode == switcherHotkey.keyCode &&
                (hotkey.modifiers == switcherHotkey.modifiers || hotkey.modifiers == (switcherHotkey.modifiers | 512))
        }
        // Preserve existing shortcuts, including the reverse-cycling combination.
        let conflict = configuration.rules.contains { rule in
            guard rule.enabled, preferences.ruleFeatureEnabled(rule), let hotkey = rule.hotkey else { return false }
            return conflicts(hotkey)
        }
        let workflow = preferences.workflowSettings
        let referenceConflict = ([workflow.shortcutPanelHotkey, preferences.featureEnabled(.dictation) ? workflow.cancelRecordingHotkey : nil, workflow.clipboardHistoryEnabled == true ? workflow.effectiveClipboardHistoryHotkey : nil, preferences.featureEnabled(.commandBar) ? preferences.toolkitSettings.effectiveCommandBarHotkey : nil, preferences.featureEnabled(.menuBar) ? preferences.toolkitSettings.menuBar?.hotkey : nil].compactMap { $0 }
            + WindowSwitches(preferences).shortcutRules.compactMap(\.hotkey)).contains(where: conflicts)
        guard preferences.windowSwitcherEnabled && (conflict || referenceConflict) else { return .configure }
        let message = "A configured shortcut conflicts with \(HotkeyManager.display(switcherHotkey)) — change it to enable window switching"
        // Stopping again would publish "Off" and then the conflict, redrawing Settings each second.
        // Once stopped, only switching it on again changes the status, and that stops it here once more.
        return status == message && !ready ? .none : .stop(message)
    }

    private func configureWindowSwitcher() {
        guard started, registerShortcuts else { return }
        switch Self.windowSwitcherStep(configuration, status: windowSwitcherStatus, ready: windowSwitcherReady) {
        case .none: return
        case .stop(let message):
            windowSwitcher.stop()
            if windowSwitcherStatus != message { windowSwitcherStatus = message }
            if windowSwitcherReady { windowSwitcherReady = false }
        case .configure:
            windowSwitcher.configure(enabled: configuration.preferences.featureEnabled(.windowSwitcher), suspended: isRecordingShortcut,
                                     hotkey: configuration.preferences.toolkitSettings.effectiveWindowSwitcherHotkey)
            windowSwitcher.updateShortcuts(configuration.rules.filter { ruleFeatureEnabled($0) && hotkeyErrors[$0.id] == nil })
        }
    }

    /// The global shortcuts a configuration registers: its enabled rules and Frog's own.
    static func hotkeyRules(for configuration: Configuration) -> [Rule] {
        let preferences = configuration.preferences
        var rules = configuration.rules.filter { preferences.ruleFeatureEnabled($0) }
        if let key = preferences.workflowSettings.shortcutPanelHotkey {
            rules.append(Rule(id: Self.shortcutPanelID, name: "Show shortcuts", hotkey: key))
        }
        if preferences.featureEnabled(.dictation), let key = preferences.workflowSettings.cancelRecordingHotkey { rules.append(Rule(id: Self.cancelRecordingID, name: "Cancel recording", hotkey: key)) }
        if preferences.workflowSettings.clipboardHistoryEnabled == true {
            rules.append(Rule(id: Self.clipboardHistoryID, name: "Clipboard history", hotkey: preferences.workflowSettings.effectiveClipboardHistoryHotkey))
        }
        if preferences.featureEnabled(.commandBar) {
            rules.append(Rule(id: Self.commandBarID, name: "Command bar", hotkey: preferences.toolkitSettings.effectiveCommandBarHotkey))
        }
        rules.append(contentsOf: WindowSwitches(preferences).shortcutRules)
        return rules
    }

    /// Whether saving settings registers the global shortcuts again. Registering forgets a shortcut held down
    /// right now, so only a change in what they register does it, or a shortcut that could not be registered,
    /// which is tried again only while no shortcut is held.
    static func registersShortcutsAgain(previous: Configuration, current: Configuration, failed: Bool, holding: Bool) -> Bool {
        hotkeyRules(for: current) != hotkeyRules(for: previous) || (failed && !holding)
    }

    private func registerHotkeys() {
        guard registerShortcuts, !isRecordingShortcut else { return }
        hotkeyErrors = hotkeys.register(rules: Self.hotkeyRules(for: configuration), purposes: [Self.clipboardHistoryID: .clipboardHistory], onPress: { [weak self] id in self?.handleShortcut(id, pressed: true) }) { [weak self] id in self?.handleShortcut(id, pressed: false) }
    }

    func resolved(_ rule: Rule) throws -> ProviderConfiguration {
        if let id = rule.action?.localTextModelID ?? (!rule.answersInPanel && configuration.explicitRuleModels != true && rule.providerID == nil && configuration.preferences.workflowSettings.effectiveTextSource == .frog ? configuration.preferences.workflowSettings.defaultLocalTextModelID ?? LocalModelDescriptor.legacyTextModelID : nil),
           let model = configuration.localModel(id) {
            return ProviderConfiguration(id: Self.localProviderID, name: model.name, kind: .compatible, model: id)
        }
        guard let providerID = rule.providerID ?? (!rule.answersInPanel && configuration.explicitRuleModels != true ? configuration.defaultProviderID : nil),
              var provider = configuration.providers.first(where: { $0.id == providerID }) else {
            // An answer rule never inherits a model, so it has to name one.
            if rule.answersInPanel { throw FrogError.message("Choose a text model for \(rule.name).") }
            throw FrogError.message("Choose a text model in \(rule.name). Add a provider or download a model in Models first.")
        }
        if configuration.explicitRuleModels == true, rule.model.isEmpty { throw FrogError.message("Choose a text model for \(rule.name).") }
        if !rule.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { provider.model = rule.model }
        guard provider.models.contains(where: { $0.id == provider.model && $0.category == .text }) else { throw FrogError.message("Choose a configured text model for \(rule.name).") }
        try ConfigurationFile.validate(provider: provider)
        return provider
    }

    func processSelection(ruleID: UUID) {
        if let rule = configuration.rules.first(where: { $0.id == ruleID }), rule.answersInPanel {
            guard configuration.preferences.featureEnabled(.explain), rule.enabled else { return }
            startAnswer(rule)
            return
        }
        guard configuration.preferences.featureEnabled(.writing) else { return }
        begin(ruleID: ruleID, manualText: nil)
    }

    /// Reads the selection and answers it in the panel. Nothing is replaced. From the selection bubble, the
    /// selection is the one the bubble was shown for.
    private func startAnswer(_ rule: Rule, from snapshot: SelectionSnapshot? = nil) {
        answerCapture?.cancel()
        answerHistoryEpoch = historyEpoch
        answerHistoryWasEnabled = configuration.preferences.historyEnabled
        answerCapture = Task { [weak self] in
            guard let self else { return }
            do {
                let capture: AnswerCapture
                if let snapshot { capture = await self.bubbleSelection(snapshot) }
                else { capture = try await self.answerSelection() }
                try Task.checkCancellation()
                self.answers.start(rule: rule, capture: capture)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.answers.fail(rule: rule, message: error.localizedDescription)
            }
        }
    }

    /// The longest selection an answer reads through Accessibility, in UTF-16 units.
    static let answerReadLimit = 100_000

    /// The selection an answer rule answers: read through Accessibility first, so Safari and other apps that expose
    /// it answer without a Copy. Only an app that does not expose it that way gets the compatibility Copy, which
    /// restores the clipboard. A password field, a caret in a text field and a selection that is too long stop here.
    private func answerSelection() async throws -> AnswerCapture {
        let includeContext = configuration.preferences.explainSettings.includeContext
        if let selectionReader {
            let pid = try await selectionTarget()
            try Task.checkCancellation()
            switch await selectionReader.read(pid: pid, maxCharacters: Self.answerReadLimit, includeContext: includeContext) {
            case .selection(let snapshot):
                return AnswerCapture(text: snapshot.text, context: includeContext ? snapshot.context : nil, anchor: snapshot.bounds,
                                     application: snapshot.applicationName, source: snapshot.source)
            case .empty: throw FrogError.message(AnswerController.emptySelection)
            case .secure: throw FrogError.message("Frog does not read password fields.")
            case .tooLong: throw FrogError.message(AnswerPrompt.selectionTooLong(limit: Self.answerReadLimit))
            case .unavailable: try Task.checkCancellation()
            }
        }
        let captured = try await captureSelection()
        return AnswerCapture(text: captured.text, context: includeContext ? captured.context : nil, anchor: captured.anchor,
                             application: captured.applicationName, source: captured.source)
    }

    /// The bubble's selection, read again with its context through Accessibility only. A selection that changed
    /// since the bubble appeared is answered as the bubble read it, without context.
    private func bubbleSelection(_ snapshot: SelectionSnapshot) async -> AnswerCapture {
        let includeContext = configuration.preferences.explainSettings.includeContext
        if includeContext, let selectionReader,
           case let .selection(fresh) = await selectionReader.read(pid: snapshot.pid, maxCharacters: Self.answerReadLimit, includeContext: true),
           fresh.fingerprint == snapshot.fingerprint {
            return AnswerCapture(text: fresh.text, context: fresh.context, anchor: fresh.bounds,
                                 application: fresh.applicationName, source: fresh.source)
        }
        return AnswerCapture(text: snapshot.text, context: nil, anchor: snapshot.bounds,
                             application: snapshot.applicationName, source: snapshot.source)
    }

    // MARK: Selection bubble

    /// A rule chosen in the selection bubble: an answer rule answers the bubble's selection without the clipboard
    /// or a shortcut wait; a Writing rule runs exactly as from its shortcut.
    func runBubbleItem(_ item: BubbleItem, snapshot: SelectionSnapshot) {
        guard let rule = configuration.rules.first(where: { $0.id == item.id }), rule.enabled, ruleFeatureEnabled(rule) else { return }
        if rule.answersInPanel { startAnswer(rule, from: snapshot) }
        else { processSelection(ruleID: rule.id) }
    }

    private func configureSelectionWatcher() {
        let preferences = configuration.preferences
        let runs = started && preferences.featureEnabled(.explain) && preferences.explainSettings.selectionBubble && accessibilityGranted
        if runs, !selectionWatcher.isRunning { selectionWatcher.start() }
        else if !runs, selectionWatcher.isRunning { selectionWatcher.stop() }
    }

    private func makeSelectionWatcher() -> any SelectionWatching {
        // Tests without a watcher of their own never install global monitors.
        guard registerShortcuts else { return SilentSelectionWatcher() }
        return SelectionWatcher(reader: selectionReader ?? SelectionReader(), presenter: SelectionBubbleController(), hooks: .init(
            options: { [weak self] in self?.configuration.preferences.explainSettings.bubbleOptions ?? SelectionBubbleOptions() },
            state: { [weak self] in self?.bubbleState ?? BubbleState(explainEnabled: false, bubbleEnabled: false, writingEnabled: false,
                                                                    accessibilityTrusted: false, busy: true) },
            items: { [weak self] in self?.bubbleItems(for: $0) ?? ([], []) },
            run: { [weak self] in self?.runBubbleItem($0, snapshot: $1) }))
    }

    private var bubbleState: BubbleState {
        let preferences = configuration.preferences
        return BubbleState(explainEnabled: preferences.featureEnabled(.explain), bubbleEnabled: preferences.explainSettings.selectionBubble,
                           writingEnabled: preferences.featureEnabled(.writing), accessibilityTrusted: accessibilityGranted,
                           busy: isProcessing || dictation.active || isRecordingShortcut || answerPresenter.isKey)
    }

    private func bubbleItems(for snapshot: SelectionSnapshot) -> (visible: [BubbleItem], more: [BubbleItem]) {
        let preferences = configuration.preferences
        return SelectionBubbleItems.items(rules: configuration.rules, explainEnabled: preferences.featureEnabled(.explain),
                                          writingEnabled: preferences.featureEnabled(.writing), editable: snapshot.isEditable,
                                          configured: { (try? self.resolved($0)) != nil })
    }

    /// Saves an answer whose first reply completed, when History was on as the answer started and still is.
    private func recordAnswer(_ session: AnswerSession) -> UUID? {
        guard answerHistoryWasEnabled, configuration.preferences.historyEnabled, historyEpoch == answerHistoryEpoch,
              let provider = answers.provider else { return nil }
        let entry = HistoryEntry(answer: session, providerName: provider.id == Self.localProviderID ? "Frog" : provider.name,
                                 model: session.modelName)
        do {
            guard let retained = try historyStore.append(entry, preferences: configuration.preferences) else { return nil }
            adoptHistory(retained)
            return entry.id
        } catch {
            report(FrogError.message("Answer shown, but history could not be saved: \(error.localizedDescription)"))
            return nil
        }
    }

    /// Adds the session's follow-ups to its saved entry. False when the entry is gone, so the answer stops updating it.
    private func updateAnswerRecord(_ session: AnswerSession) -> Bool {
        guard answerHistoryWasEnabled, configuration.preferences.historyEnabled, historyEpoch == answerHistoryEpoch,
              let id = session.historyEntryID, var entry = history.first(where: { $0.id == id }) else { return false }
        entry.updateAnswer(from: session)
        do {
            let kept = try historyStore.update(entry, preferences: configuration.preferences)
            refreshHistory()
            return kept
        } catch {
            report(FrogError.message("Answer shown, but history could not be saved: \(error.localizedDescription)"))
            return false
        }
    }

    static let notesOff = "Turn on Save answers to notes on the Explain page."

    /// Whether answers offer Save to note.
    var answerNotesEnabled: Bool {
        configuration.preferences.featureEnabled(.explain) && configuration.preferences.explainSettings.notes
    }

    /// Saves an answer and its follow-ups as a Markdown note in the notes folder, asking for the
    /// folder first when none is set. Saving is something the person asks for, so it works with
    /// History off. Returns the file written; a cancelled folder choice throws `CancellationError`.
    func saveAnswerNote(_ content: AnswerNoteContent) async throws -> URL {
        guard configuration.preferences.explainSettings.notes else { throw FrogError.message(Self.notesOff) }
        do {
            if configuration.preferences.explainSettings.notesFolder == nil {
                guard try await chooseAnswerNotesFolder() else { throw CancellationError() }
            }
            let settings = configuration.preferences.explainSettings
            guard let folder = settings.notesFolderURL else { throw CancellationError() }
            let mode = settings.notesMode, pattern = settings.notesFile
            let url = try await Task.detached {
                try AnswerNoteWriter().save(content, folder: folder, mode: mode, file: pattern, now: Date())
            }.value
            if settings.notesOpen { NoteOpener.open(url) }
            return url
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            report(FrogError.message("Note not saved: \(error.localizedDescription)"))
            throw error
        }
    }

    /// Asks for the notes folder and stores it, tilde-abbreviated. False when the choice was cancelled.
    @discardableResult
    func chooseAnswerNotesFolder() async throws -> Bool {
        guard let chosen = await chooseNotesFolder() else { return false }
        try updateToolkit { toolkit in
            var settings = toolkit.explain ?? ExplainSettings()
            settings.notesFolder = (chosen.path as NSString).abbreviatingWithTildeInPath
            toolkit.explain = settings
        }
        return true
    }

    /// The folder chooser for notes, in front of the app the selection came from.
    private static func chooseNotesFolderInPanel() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("Choose")
        panel.message = L10n.text("Choose the folder for notes, such as an Obsidian vault.")
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    func processManual(text: String, ruleID: UUID, providerID: UUID? = nil, modelID: String? = nil) {
        guard configuration.preferences.featureEnabled(.writing) else { return }
        begin(ruleID: ruleID, manualText: text, providerID: providerID, modelID: modelID)
    }
    func cancelProcessing() { processingTask?.cancel(); status = "Cancelling…" }

    func showShortcuts() {
        let items = ShortcutReference.items(configuration: configuration, ruleEnabled: configuration.preferences.ruleFeatureEnabled,
                                            extraRules: WindowSwitches(configuration.preferences).shortcutRules)
        shortcutPanel.show(groups: ShortcutReference.grouped(items))
    }

    private func configureClipboardHistory() {
        guard started else { return }
        let enabled = configuration.preferences.workflowSettings.clipboardHistoryEnabled == true
        if registerShortcuts { clipboardHistory.configure(enabled: enabled) }
        else { clipboardHistoryStore.configure(enabled: enabled, automaticallyPoll: false) }
    }

    func showClipboardHistory() {
        guard !isRecordingShortcut else { return }
        clipboardHistory.show()
    }

    func saveWorkflowPreferences(_ value: WorkflowPreferences) throws {
        var prefs = configuration.preferences; prefs.workflows = value
        try savePreferences(prefs)
    }

    func startDictation(_ rule: Rule, shortcutHeld: Bool = false) {
        guard configuration.preferences.featureEnabled(.dictation) else { return }
        guard !isProcessing else { report(FrogError.message("Wait for the current request to finish.")); return }
        guard !dictation.active else { return }
        dictationHistoryEpoch = configuration.preferences.historyEnabled ? historyEpoch : nil
        dictation.start(rule: rule, preferences: configuration.preferences.workflowSettings, models: localModels, shortcutHeld: shortcutHeld)
    }

    func ensureDictationRule() throws {
        if !configuration.rules.contains(where: { $0.category == .audio }) { try saveRule(.dictationPreset) }
    }

    private func handleShortcut(_ id: UUID, pressed: Bool) {
        if let command = WindowCommand.command(for: id) { windowLayout.handle(command, pressed: pressed); return }
        if id == Self.commandBarID { if pressed { showCommandBar() }; return }
        if id == Self.clipboardHistoryID { if !pressed { showClipboardHistory() }; return }
        if id == Self.cancelRecordingID {
            if pressed { dictation.interrupt(reason: configuration.preferences.workflowSettings.cancelRecordingHotkey?.keyCode == 53 ? .escape : .cancelled) }
            return
        }
        if id == Self.shortcutPanelID { if pressed { showShortcuts() } else { shortcutPanel.hide() }; return }
        guard let rule = configuration.rules.first(where: { $0.id == id && $0.enabled }), ruleFeatureEnabled(rule) else { return }
        switch rule.category {
        case .text: if !pressed { processSelection(ruleID: id) }
        case .application:
            if pressed && configuration.preferences.shortcutsEnabled { launchApplication(rule) }
        case .window:
            if pressed { manageWindow(rule) }
        case .system:
            if pressed && configuration.preferences.shortcutsEnabled { performSystemAction(rule) }
        case .audio:
            let mode = rule.action?.recordingMode ?? configuration.preferences.workflowSettings.recordingMode
            switch RecordingShortcut.action(mode: mode, pressed: pressed, target: id, active: dictation.ruleID, finishing: dictation.finishing) {
            case .start: startDictation(rule, shortcutHeld: true)
            case .stop: dictation.stop(models: localModels)
            case .busy: showPressWhileFinishing()
            case nil: break
            }
        }
    }

    /// A recording starts only after the last one was delivered. Without its popup, the processing
    /// indicator says why the press did nothing.
    private func showPressWhileFinishing() {
        guard !dictation.showPressWhileFinishing(), registerShortcuts, configuration.preferences.showProcessingIndicator else { return }
        processingIndicator.note(dictation.phase == .correcting ? "Still cleaning up…" : "Still transcribing…")
    }

    private func launchApplication(_ rule: Rule) {
        applicationTask?.cancel()
        applicationTask = Task {
            do {
                try await ApplicationLauncher().launch(rule)
                try Task.checkCancellation()
                statistics.recordRuleExecution(kind: .application)
            }
            catch is CancellationError { }
            catch { report(error) }
        }
    }

    private func performSystemAction(_ rule: Rule) {
        guard let action = rule.action?.systemAction, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        systemActionTask?.cancel()
        systemActionTask = Task {
            do {
                try await ClipboardSelection.waitForShortcutRelease()
                try Task.checkCancellation()
                try await SystemActionController.shared.perform(action, pid: pid)
                try Task.checkCancellation()
                if configuration.rules.contains(where: { $0.id == rule.id }) { statistics.recordRuleExecution(kind: .system) }
                else { statistics.recordToolUse(.systemCommand) }
            } catch is CancellationError { }
            catch { report(error) }
        }
    }

    private func manageWindow(_ rule: Rule) {
        guard let action = rule.action?.windowAction, let app = NSWorkspace.shared.frontmostApplication else { return }
        let displays = WindowDisplays.current()
        let options = WindowSwitches(configuration.preferences).layoutOptions(MacWindowManagerReader.read())
        let pid = app.processIdentifier
        windowActionTask?.cancel()
        windowActionTask = Task {
            do {
                try await windowManager.perform(action, pid: pid, displays: displays, options: options)
                try Task.checkCancellation()
                if configuration.rules.contains(where: { $0.id == rule.id }) { statistics.recordRuleExecution(kind: .window) }
                else { statistics.recordToolUse(.windowCommand) }
            }
            catch is CancellationError { }
            catch { report(error) }
        }
    }

    private func begin(ruleID: UUID, manualText: String?, providerID: UUID? = nil, modelID: String? = nil) {
        guard !isProcessing, !dictation.active else {
            // A shortcut press is answered by the indicator or popup of what is running.
            if manualText != nil {
                let error = FrogError.message("A rule is already running. Wait or cancel it from the menu.")
                report(error); ruleOutcome = .failed(error.localizedDescription)
            }
            return
        }
        ruleOutcome = nil
        guard var rule = configuration.rules.first(where: { $0.id == ruleID }), rule.enabled else {
            let error = FrogError.message("Select an enabled rule.")
            report(error); ruleOutcome = .failed(error.localizedDescription); return
        }
        // An answer belongs in the panel: this path would send the selection and paste over it.
        if rule.answersInPanel {
            let error = FrogError.message("This rule answers in a panel. Turn on Explain in Features.")
            report(error); ruleOutcome = .failed(error.localizedDescription); return
        }
        if manualText != nil { manualResult = "" }
        if let providerID { rule.providerID = providerID; rule.model = modelID ?? "" }
        else if let modelID { rule.model = modelID }
        let provider: ProviderConfiguration
        do { provider = try resolved(rule) }
        catch { finish(outcome(of: error), background: manualText == nil); return }
        isProcessing = true
        status = "\(rule.name)…"
        if manualText == nil { showIndicatorWorking() }
        let recordingEpoch = historyEpoch
        let recordingWasEnabled = configuration.preferences.historyEnabled
        processingTask = Task { [weak self] in
            guard let self else { return }
            var ended = RuleOutcome.done
            defer {
                self.finish(ended, background: manualText == nil)
                self.isProcessing = false; self.processingTask = nil
            }
            do {
                let selection: (any CapturedTextSelection)?
                let text: String
                if let manualText { selection = nil; text = manualText }
                else { let captured = try await self.captureSelection(); selection = captured; text = captured.text }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FrogError.message("Select or enter some text first.") }
                let key = provider.id == Self.localProviderID || provider.kind.localTool != nil ? nil : try self.readKey(provider.id)
                try Task.checkCancellation()
                let result: String
                if provider.id == Self.localProviderID {
                    if !self.localModels.loaded.contains(provider.model) {
                        self.status = "Loading \(self.configuration.localModel(provider.model)?.name ?? provider.model)…"
                        try await self.localModels.prepare(provider.model)
                        try Task.checkCancellation()
                    }
                    self.status = "\(rule.name)…"
                    result = try await self.localModels.complete(text, instructions: rule.expandedInstructions(), modelID: provider.model)
                }
                else { result = try await self.complete(text, rule, provider, key) }
                try Task.checkCancellation()
                guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FrogError.message("The model returned no text. Nothing was replaced.") }
                var delivered = true
                if let selection {
                    do { try await selection.replace(with: result) }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        delivered = false
                        self.report(error); ended = .failed(error.localizedDescription)
                    }
                    self.clipboardHistoryStore.recordCopiedText(result)
                } else {
                    self.manualResult = result
                    self.writeClipboard(result)
                    self.clipboardHistoryStore.recordCopiedText(result)
                }
                try Task.checkCancellation()
                if delivered { self.statistics.recordRuleExecution(kind: provider.id == Self.localProviderID || provider.kind.isLocal ? .local : provider.kind.localTool != nil ? .cli : .remote) }
                if recordingWasEnabled && self.configuration.preferences.historyEnabled && self.historyEpoch == recordingEpoch {
                    do {
                        if let retained = try self.historyStore.append(HistoryEntry(originalText: text, processedText: result, ruleName: rule.name, providerName: provider.name, model: provider.model, targetLanguage: rule.targetLanguage), preferences: self.configuration.preferences) { self.adoptHistory(retained) }
                    } catch {
                        let failure = FrogError.message("Text processed, but history could not be saved: \(error.localizedDescription)")
                        self.report(failure); ended = .failed(failure.localizedDescription)
                    }
                }
            } catch { ended = self.outcome(of: error) }
        }
    }

    private func outcome(of error: Error) -> RuleOutcome {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
        report(error)
        return .failed(error.localizedDescription)
    }

    /// `background`: a shortcut ran the rule, so the processing indicator shows how it ended.
    private func finish(_ outcome: RuleOutcome, background: Bool) {
        ruleOutcome = outcome
        if background, showsProcessingIndicator { processingIndicator.show(outcome) }
    }

    private func showIndicatorWorking() {
        if showsProcessingIndicator { processingIndicator.showWorking() }
    }

    private var showsProcessingIndicator: Bool {
        registerShortcuts && configuration.preferences.featureEnabled(.writing) && configuration.preferences.showProcessingIndicator
    }
}

enum RuleOutcome: Equatable {
    case done, cancelled, failed(String)
    var failure: String? { if case .failed(let message) = self { message } else { nil } }
}
