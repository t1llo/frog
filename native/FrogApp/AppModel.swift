import AppKit
import Combine
import FrogCore

struct AppIssue: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var configuration = Configuration()
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var hotkeyErrors: [UUID: String] = [:]
    @Published private(set) var isProcessing = false
    @Published private(set) var status = "Ready"
    @Published private(set) var errorMessage: String?
    @Published private(set) var recentErrors: [AppIssue] = []
    private var errorDismissal: Task<Void, Never>?
    private let errorDisplayDuration: Duration
    @Published private(set) var manualResult = ""
    @Published private(set) var isTestingProvider = false
    @Published private(set) var startAtLogin = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var loginStatus = ""
    @Published private(set) var windowSwitcherStatus = "Not started"
    @Published private(set) var windowSwitcherReady = false
    @Published private(set) var setupPresented = false

    var openSettings: (() -> Void)?
    private let configurationStore: ConfigurationStore
    private let historyStore: HistoryStore
    private let keychain = KeychainStore()
    private let complete: (String, Rule, ProviderConfiguration, String?) async throws -> String
    private let readKey: (UUID) throws -> String?
    private let writeClipboard: (String) -> Void
    private let registerShortcuts: Bool
    private let readAccessibility: () -> Bool
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
    private var observations = Set<AnyCancellable>()
    private var dictationHistoryEpoch: UUID?
    static let localProviderID = UUID(uuidString: "7C05FB97-5BEF-48FD-9C28-A67605107251")!
    static let shortcutPanelID = UUID(uuidString: "85F8DE80-89BC-4506-B82D-DCFB71AFE292")!
    static let cancelRecordingID = UUID(uuidString: "E4A8A2D5-7F72-42CA-924C-9100A213D030")!
    private let shortcutPanel = ShortcutReferencePanel()
    private let captureSelection: () async throws -> any CapturedTextSelection
    private let processingIndicator = ProcessingIndicator()
    private var processingTask: Task<Void, Never>?
    private var applicationTask: Task<Void, Never>?
    private let windowManager = WindowManager()
    private var windowActionTask: Task<Void, Never>?
    private var historyEpoch = UUID()
    private var configurationLoadError: Error?
    private var isRecordingShortcut = false

    init(dataDirectory: URL? = nil, registerShortcuts: Bool = true,
         complete: ((String, Rule, ProviderConfiguration, String?) async throws -> String)? = nil,
         readKey: ((UUID) throws -> String?)? = nil,
         writeClipboard: ((String) -> Void)? = nil,
         readAccessibility: (() -> Bool)? = nil,
         captureSelection: (() async throws -> any CapturedTextSelection)? = nil,
         dictationController: DictationController? = nil,
         modelService: LocalModels? = nil,
         errorDisplayDuration: Duration = .seconds(6)) {
        let dataDirectory = dataDirectory ?? ProcessInfo.processInfo.environment["FROG_DATA_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.registerShortcuts = registerShortcuts
        self.dictation = dictationController ?? DictationController()
        self.errorDisplayDuration = errorDisplayDuration
        localModels = modelService ?? LocalModels(directory: dataDirectory)
        self.readAccessibility = readAccessibility ?? { SelectionService.isTrusted }
        self.captureSelection = captureSelection ?? { try await SelectionService().capture() }
        self.complete = complete ?? { text, rule, provider, key in try await LLMClient().complete(text: text, rule: rule, provider: provider, apiKey: key) }
        self.readKey = readKey ?? { try KeychainStore().read(providerID: $0) }
        self.writeClipboard = writeClipboard ?? { text in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        configurationStore = ConfigurationStore(directory: dataDirectory)
        historyStore = HistoryStore(directory: dataDirectory)
        if registerShortcuts {
            do {
                setupPresented = try SetupStore(directory: historyStore.directory).needsSetup(
                    existingConfiguration: configurationStore.hasExistingConfiguration)
            } catch { report(error) }
        }
        do { configuration = try configurationStore.load() }
        catch { configurationLoadError = error; report(error) }
        localModels.updateCatalog(configuration.modelCatalog)
        if configurationLoadError == nil {
            var candidate = configuration
            if registerShortcuts { candidate.adoptExplicitRuleSettings(installed: localModels.installed) }
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
        localModels.onInventoryChanged = { [weak self] in self?.objectWillChange.send() }
        refreshHistory()
        refreshSystemStatus()
        if registerShortcuts { FrogAppearance.shared.apply(configuration.preferences.appearance ?? AppearancePreferences()) }
        if registerShortcuts { AppLanguage.shared.selection = configuration.preferences.workflowSettings.applicationLanguage ?? "system" }
        localModels.idleSeconds = configuration.preferences.workflowSettings.idleUnloadSeconds
        localModels.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        dictation.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        dictation.onError = { [weak self] in self?.report($0) }
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
                return try await self.complete(text, rule, provider, self.readKey(provider.id))
            }
            return try await self.localModels.complete(text, instructions: rule.instructions, modelID: provider.model)
        }
        dictation.localCleanupModel = { [weak self] rule in
            guard let self else { throw CancellationError() }
            let provider = try self.resolved(rule)
            return provider.id == Self.localProviderID ? provider.model : nil
        }
        dictation.onFinish = { [weak self] rule, _, _, delivery in
            guard let self else { return }
            self.status = "\(rule.name) · \(delivery)"
        }
        dictation.onTranscript = { [weak self] rule, original, result in
            guard let self else { return }
            if self.configuration.preferences.historyEnabled, self.dictationHistoryEpoch == self.historyEpoch {
                var entry = HistoryEntry(originalText: original, processedText: result, ruleName: rule.name, providerName: "Transcription", model: rule.action?.audioModelID ?? self.configuration.preferences.workflowSettings.audioModelID)
                entry.category = .audio
                do { try self.historyStore.append(entry, preferences: self.configuration.preferences); self.refreshHistory() }
                catch { self.report(error) }
            }
        }
    }

    func showSetup() { setupPresented = true }
    var configurationFileURL: URL { configurationStore.file }
    func finishSetup() {
        do { try SetupStore(directory: historyStore.directory).complete(); setupPresented = false }
        catch { report(error) }
    }

    func start() {
        started = true
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
        registerHotkeys()
        configureWindowSwitcher()
        if configuration.providers.isEmpty && localModels.installed.isEmpty { status = "Add a model in Models to get started." }
    }

    func shutdown() {
        dictation.cancel(); localModels.shutdown(); shortcutPanel.hide()
        started = false
        if registerShortcuts { windowSwitcher.stop() }
        processingIndicator.hide()
        processingTask?.cancel()
        applicationTask?.cancel()
        windowActionTask?.cancel()
        hotkeys.unregister()
    }

    func showSettings() { refreshSystemStatus(); openSettings?() }

    func refreshSystemStatus() {
        let trusted = readAccessibility()
        let loginEnabled = LoginService.isEnabled
        let loginText = LoginService.statusText
        if accessibilityGranted != trusted { accessibilityGranted = trusted }
        if startAtLogin != loginEnabled { startAtLogin = loginEnabled }
        if loginStatus != loginText { loginStatus = loginText }
        if started { configureWindowSwitcher() }
    }

    func monitorSystemStatus() async {
        while !Task.isCancelled {
            refreshSystemStatus()
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
        }
    }

    func setStartAtLogin(_ enabled: Bool) {
        do { try LoginService.setEnabled(enabled); refreshSystemStatus() }
        catch { refreshSystemStatus(); report(error) }
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
            throw FrogError.message("Settings could not be loaded, so they have not been overwritten. Import a valid configuration in Settings, or repair the file in \(configurationStore.directory.path) and relaunch Frog. \(error.localizedDescription)")
        }
        try ConfigurationFile.validate(candidate)
        try configurationStore.save(candidate)
        configuration = candidate
        localModels.updateCatalog(candidate.modelCatalog)
        if registerShortcuts { FrogAppearance.shared.apply(candidate.preferences.appearance ?? AppearancePreferences()) }
        if registerShortcuts { AppLanguage.shared.selection = candidate.preferences.workflowSettings.applicationLanguage ?? "system" }
    }

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

    private func reconcileLocalModelDefaults() {
        var candidate = configuration
        for item in candidate.modelCatalog where localModels.installed.contains(item.id) {
            candidate.selectSoleInstalledModel(item, installed: localModels.installed)
        }
        if candidate != configuration { do { try persist(candidate) } catch { report(error) } }
    }

    func addLocalModel(_ item: LocalModelDescriptor) throws {
        guard !configuration.modelCatalog.contains(where: { $0.id == item.id }) else { return }
        try item.validateCustom()
        var candidate = configuration
        candidate.localModels = (candidate.localModels ?? []) + [item]
        try persist(candidate)
    }

    func removeLocalModelSource(_ item: LocalModelDescriptor) throws {
        guard !localModels.installed.contains(item.id), localModels.progress[item.id] == nil else {
            throw FrogError.message("Delete the downloaded model before removing its source.")
        }
        var candidate = configuration
        candidate.localModels?.removeAll { $0.id == item.id }
        try persist(candidate)
    }

    func deleteLocalModel(_ item: LocalModelDescriptor) async throws {
        try await localModels.remove(item.id)
        var candidate = configuration
        candidate.modelsRemoved([RuleModelSelection(modelID: item.id, category: item.kind == .audio ? .audio : .text)], installed: localModels.installed)
        try persist(candidate)
    }

    func deleteRule(id: UUID) throws {
        var candidate = configuration
        candidate.rules.removeAll { $0.id == id }
        try persist(candidate)
        registerHotkeys()
        configureWindowSwitcher()
    }

    func hasAPIKey(_ id: UUID) -> Bool { ((try? keychain.read(providerID: id)) ?? "").isEmpty == false }

    func saveProvider(_ provider: ProviderConfiguration, apiKey: String?, clearKey: Bool) throws {
        try ConfigurationFile.validate(provider: provider)
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
        let oldKey = keyChanged ? try keychain.read(providerID: provider.id) : nil
        if clearKey { try keychain.delete(providerID: provider.id) }
        else if let apiKey, !apiKey.isEmpty { try keychain.save(apiKey, providerID: provider.id) }
        do { try persist(candidate) }
        catch {
            if keyChanged {
                do {
                    if let oldKey { try keychain.save(oldKey, providerID: provider.id) }
                    else { try keychain.delete(providerID: provider.id) }
                } catch { report(FrogError.message("Settings could not be saved and the previous key could not be restored. Re-enter the key before retrying.")) }
            }
            throw error
        }
        status = "Provider saved"
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
        do { try keychain.delete(providerID: id) }
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
        let key = (apiKey?.isEmpty == false) ? apiKey : try keychain.read(providerID: provider.id)
        if let textModel = provider.models.first(where: { $0.category == .text }) {
            var test = provider; test.model = textModel.id
            _ = try await complete("Reply with OK.", Rule(name: "Connection test", instructions: "Reply briefly to the user."), test, key)
            return "Connected using \(textModel.name)."
        }
        _ = try await discoverModels(provider, apiKey: key)
        return "Connected. Transcription is checked when you record."
    }

    func discoverModels(_ provider: ProviderConfiguration, apiKey: String?) async throws -> [ProviderModel] {
        let key = (apiKey?.isEmpty == false) ? apiKey : try keychain.read(providerID: provider.id)
        return try await LLMClient().localModels(provider: provider, apiKey: key)
    }

    func savePreferences(_ preferences: Preferences) throws {
        let shortcutChanged = preferences.workflowSettings.shortcutPanelHotkey != configuration.preferences.workflowSettings.shortcutPanelHotkey || preferences.workflowSettings.cancelRecordingHotkey != configuration.preferences.workflowSettings.cancelRecordingHotkey
        if let key = preferences.workflowSettings.shortcutPanelHotkey, let issue = HotkeyManager.validationError(key) { throw FrogError.message(issue) }
        if let key = preferences.workflowSettings.cancelRecordingHotkey, let issue = HotkeyManager.validationError(key) { throw FrogError.message(issue) }
        guard (1...200).contains(preferences.historyLimit), (1...30).contains(preferences.historyRetentionDays) else {
            throw FrogError.message("History must keep 1–200 entries for 1–30 days.")
        }
        var candidate = configuration; candidate.preferences = preferences
        try persist(candidate)
        if !preferences.historyEnabled { historyEpoch = UUID() }
        if !preferences.showProcessingIndicator { processingIndicator.hide() }
        configureWindowSwitcher()
        localModels.idleSeconds = preferences.workflowSettings.idleUnloadSeconds
        if shortcutChanged || preferences.applicationShortcutsEnabled != nil { registerHotkeys(); shortcutPanel.hide() }
        refreshHistory()
    }

    func refreshHistory() {
        do { history = try historyStore.load(preferences: configuration.preferences) }
        catch { report(error) }
    }
    var historyFileURL: URL { historyStore.directory.appendingPathComponent("history.json") }
    func deleteHistory(id: UUID) throws { try historyStore.delete(id: id); refreshHistory() }
    func clearHistory() throws { try historyStore.clear(); historyEpoch = UUID(); refreshHistory() }

    func exportConfiguration(to url: URL) throws {
        guard configurationLoadError == nil else { throw FrogError.message("Repair the saved settings before exporting them.") }
        try ConfigurationFile.write(configuration, to: url)
        status = "Configuration exported. API keys and history were not included."
    }

    func importConfiguration(_ imported: Configuration) throws {
        guard !isProcessing, !isTestingProvider, !dictation.active else { throw FrogError.message("Finish or cancel the current request before importing a configuration.") }
        try ConfigurationFile.validate(imported)
        for rule in imported.rules {
            if let hotkey = rule.hotkey, let issue = HotkeyManager.validationError(hotkey) { throw FrogError.message(issue) }
        }
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
                candidate.providers[index].id = newID
            }
        }
        if let id = candidate.defaultProviderID { candidate.defaultProviderID = remapped[id] ?? id }
        for index in candidate.rules.indices {
            if let id = candidate.rules[index].providerID { candidate.rules[index].providerID = remapped[id] ?? id }
            if let id = candidate.rules[index].action?.audioProviderID { candidate.rules[index].action?.audioProviderID = remapped[id] ?? id }
        }
        if let recent = candidate.recentModels {
            candidate.recentModels = recent.map { var item = $0; if let id = item.providerID { item.providerID = remapped[id] ?? id }; return item }
        }
        candidate.adoptExplicitRuleSettings(installed: localModels.installed)
        try configurationStore.replaceFromImport(candidate)
        configuration = candidate
        localModels.updateCatalog(candidate.modelCatalog)
        if registerShortcuts { FrogAppearance.shared.apply(candidate.preferences.appearance ?? AppearancePreferences()) }
        if registerShortcuts { AppLanguage.shared.selection = candidate.preferences.workflowSettings.applicationLanguage ?? "system" }
        configurationLoadError = nil
        localModels.idleSeconds = candidate.preferences.workflowSettings.idleUnloadSeconds
        errorMessage = nil
        historyEpoch = UUID()
        registerHotkeys()
        configureWindowSwitcher()
        refreshHistory()
        status = "Configuration imported. Check provider credentials and shortcut status."
    }

    func setShortcutRecording(_ recording: Bool) {
        if recording { dictation.cancel() }
        isRecordingShortcut = recording
        if recording { hotkeys.unregister() }
        else { registerHotkeys() }
        configureWindowSwitcher()
    }

    private func configureWindowSwitcher() {
        guard started, registerShortcuts else { return }
        // Preserve any existing rule that owns Command–Tab instead of silently
        // intercepting it. The user can reassign that rule to enable switching.
        let conflict = configuration.rules.contains { rule in
            guard rule.enabled, let hotkey = rule.hotkey else { return false }
            return hotkey.keyCode == 48 && (hotkey.modifiers == 256 || hotkey.modifiers == 768)
        }
        let workflow = configuration.preferences.workflowSettings
        let referenceConflict = [workflow.shortcutPanelHotkey, workflow.cancelRecordingHotkey].compactMap { $0 }.contains { $0.keyCode == 48 && [UInt32(256), 768].contains($0.modifiers) }
        if configuration.preferences.windowSwitcherEnabled && (conflict || referenceConflict) {
            windowSwitcher.stop()
            let message = "A configured shortcut uses ⌘Tab — change it to enable window switching"
            if windowSwitcherStatus != message { windowSwitcherStatus = message }
            if windowSwitcherReady { windowSwitcherReady = false }
            return
        }
        windowSwitcher.configure(enabled: configuration.preferences.shortcutsEnabled && configuration.preferences.windowSwitcherEnabled, suspended: isRecordingShortcut)
        windowSwitcher.updateShortcuts(configuration.rules.filter { hotkeyErrors[$0.id] == nil })
    }

    private func registerHotkeys() {
        guard registerShortcuts, !isRecordingShortcut else { return }
        var rules = configuration.rules.filter { configuration.preferences.shortcutsEnabled || !$0.category.isShortcut }
        if let key = configuration.preferences.workflowSettings.shortcutPanelHotkey {
            rules.append(Rule(id: Self.shortcutPanelID, name: "Show shortcuts", hotkey: key))
        }
        if let key = configuration.preferences.workflowSettings.cancelRecordingHotkey { rules.append(Rule(id: Self.cancelRecordingID, name: "Cancel recording", hotkey: key)) }
        hotkeyErrors = hotkeys.register(rules: rules, onPress: { [weak self] id in self?.handleShortcut(id, pressed: true) }) { [weak self] id in self?.handleShortcut(id, pressed: false) }
    }

    func resolved(_ rule: Rule) throws -> ProviderConfiguration {
        if let id = rule.action?.localTextModelID ?? (configuration.explicitRuleModels != true && rule.providerID == nil && configuration.preferences.workflowSettings.effectiveTextSource == .frog ? configuration.preferences.workflowSettings.defaultLocalTextModelID ?? "qwen-0.6b" : nil),
           let model = configuration.localModel(id) {
            return ProviderConfiguration(id: Self.localProviderID, name: model.name, kind: .compatible, model: id)
        }
        guard let providerID = rule.providerID ?? (configuration.explicitRuleModels == true ? nil : configuration.defaultProviderID),
              var provider = configuration.providers.first(where: { $0.id == providerID }) else {
            throw FrogError.message("Choose a text model in \(rule.name). Add a provider or download a model in Models first.")
        }
        if configuration.explicitRuleModels == true, rule.model.isEmpty { throw FrogError.message("Choose a text model for \(rule.name).") }
        if !rule.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { provider.model = rule.model }
        guard provider.models.contains(where: { $0.id == provider.model && $0.category == .text }) else { throw FrogError.message("Choose a configured text model for \(rule.name).") }
        try ConfigurationFile.validate(provider: provider)
        return provider
    }

    func processSelection(ruleID: UUID) {
        begin(ruleID: ruleID, manualText: nil)
    }

    func processManual(text: String, ruleID: UUID, providerID: UUID? = nil, modelID: String? = nil) {
        begin(ruleID: ruleID, manualText: text, providerID: providerID, modelID: modelID)
    }
    func cancelProcessing() { dictation.cancel(); processingTask?.cancel(); status = "Cancelling…" }

    func showShortcuts() { shortcutPanel.show(rules: configuration.rules.filter { configuration.preferences.shortcutsEnabled || !$0.category.isShortcut }) }

    func saveWorkflowPreferences(_ value: WorkflowPreferences) throws {
        var prefs = configuration.preferences; prefs.workflows = value
        try savePreferences(prefs)
    }

    func startDictation(_ rule: Rule) {
        guard !isProcessing else { report(FrogError.message("Wait for the current request to finish.")); return }
        dictationHistoryEpoch = configuration.preferences.historyEnabled ? historyEpoch : nil
        dictation.start(rule: rule, preferences: configuration.preferences.workflowSettings, models: localModels)
    }

    func ensureDictationRule() throws {
        if !configuration.rules.contains(where: { $0.category == .audio }) { try saveRule(.dictationPreset) }
    }

    private func handleShortcut(_ id: UUID, pressed: Bool) {
        if id == Self.cancelRecordingID { if pressed { dictation.cancel() }; return }
        if id == Self.shortcutPanelID { if pressed { showShortcuts() } else { shortcutPanel.hide() }; return }
        guard let rule = configuration.rules.first(where: { $0.id == id && $0.enabled }) else { return }
        switch rule.category {
        case .text: if !pressed { processSelection(ruleID: id) }
        case .application:
            if pressed && configuration.preferences.shortcutsEnabled { launchApplication(rule) }
        case .window:
            if pressed && configuration.preferences.shortcutsEnabled { manageWindow(rule) }
        case .system:
            if pressed && configuration.preferences.shortcutsEnabled { performSystemAction(rule) }
        case .audio:
            let mode = rule.action?.recordingMode ?? configuration.preferences.workflowSettings.recordingMode
            switch RecordingShortcut.action(mode: mode, pressed: pressed, target: id, active: dictation.ruleID) {
            case .start: startDictation(rule)
            case .stop: dictation.stop(models: localModels)
            case nil: break
            }
        }
    }

    private func launchApplication(_ rule: Rule) {
        applicationTask?.cancel()
        applicationTask = Task {
            do { try await ApplicationLauncher().launch(rule) }
            catch is CancellationError { }
            catch { report(error) }
        }
    }

    private func performSystemAction(_ rule: Rule) {
        guard let action = rule.action?.systemAction, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        applicationTask?.cancel()
        applicationTask = Task {
            do {
                try await ClipboardSelection.waitForShortcutRelease()
                try Task.checkCancellation()
                try await SystemActionController.shared.perform(action, pid: pid)
            } catch is CancellationError { }
            catch { report(error) }
        }
    }

    private func manageWindow(_ rule: Rule) {
        guard let action = rule.action?.windowAction, let app = NSWorkspace.shared.frontmostApplication else { return }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        var displays: [CGRect] = NSScreen.screens.map { screen -> CGRect in
            let frame = screen.visibleFrame
            return CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
        }
        displays.sort { left, right in
            if left.minX == right.minX { return left.minY < right.minY }
            return left.minX < right.minX
        }
        let pid = app.processIdentifier
        windowActionTask?.cancel()
        windowActionTask = Task {
            do { try await windowManager.perform(action, pid: pid, displays: displays) }
            catch is CancellationError { }
            catch { report(error) }
        }
    }

    private func begin(ruleID: UUID, manualText: String?, providerID: UUID? = nil, modelID: String? = nil) {
        guard !isProcessing, !dictation.active else { status = "A rule is already running. Wait or cancel it from the menu."; return }
        guard var rule = configuration.rules.first(where: { $0.id == ruleID }), rule.enabled else { report(FrogError.message("Select an enabled rule.")); return }
        if let providerID { rule.providerID = providerID; rule.model = modelID ?? "" }
        else if let modelID { rule.model = modelID }
        let provider: ProviderConfiguration
        do { provider = try resolved(rule) }
        catch { finishFailure(error, background: manualText == nil); return }
        isProcessing = true
        errorMessage = nil
        status = "\(rule.name)…"
        if manualText == nil { showIndicator("Reading selection…", working: true) }
        let recordingEpoch = historyEpoch
        let recordingWasEnabled = configuration.preferences.historyEnabled
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isProcessing = false; self.processingTask = nil
                if manualText == nil { self.showIndicator(self.errorMessage ?? self.status, working: false) }
            }
            do {
                let selection: (any CapturedTextSelection)?
                let text: String
                if let manualText { selection = nil; text = manualText }
                else { let captured = try await self.captureSelection(); selection = captured; text = captured.text }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FrogError.message("Select or enter some text first.") }
                let key = provider.id == Self.localProviderID ? nil : try self.readKey(provider.id)
                try Task.checkCancellation()
                if manualText == nil { self.showIndicator("\(rule.name)…", working: true) }
                let result: String
                if provider.id == Self.localProviderID { result = try await self.localModels.complete(text, instructions: rule.instructions.replacingOccurrences(of: "{{language}}", with: rule.targetLanguage), modelID: provider.model) }
                else { result = try await self.complete(text, rule, provider, key) }
                try Task.checkCancellation()
                guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FrogError.message("The model returned no text. Nothing was replaced.") }
                if let selection {
                    do { try await selection.replace(with: result); self.status = "\(rule.name) complete — result pasted and copied." }
                    catch {
                        self.status = "Result ready on clipboard; replacement skipped."
                        self.report(error)
                    }
                } else {
                    self.manualResult = result
                    self.writeClipboard(result)
                    self.status = "\(rule.name) complete — result copied."
                }
                if recordingWasEnabled && self.configuration.preferences.historyEnabled && self.historyEpoch == recordingEpoch {
                    do {
                        try self.historyStore.append(HistoryEntry(originalText: text, processedText: result, ruleName: rule.name, providerName: provider.name, model: provider.model, targetLanguage: rule.targetLanguage), preferences: self.configuration.preferences)
                        self.refreshHistory()
                    } catch { self.report(FrogError.message("Text processed, but history could not be saved: \(error.localizedDescription)")) }
                }
            } catch { self.finishFailure(error, background: manualText == nil) }
        }
    }

    private func finishFailure(_ error: Error, background: Bool) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            status = "Cancelled — original text unchanged."
            return
        }
        status = "Could not complete the rule."
        report(error)
        if background {
            showIndicator(error.localizedDescription, working: false)
        }
    }

    private func showIndicator(_ message: String, working: Bool) {
        guard registerShortcuts, configuration.preferences.showProcessingIndicator else { return }
        processingIndicator.show(message, working: working, failed: errorMessage != nil)
    }
}
