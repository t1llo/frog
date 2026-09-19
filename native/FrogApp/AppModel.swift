import AppKit
import Combine
import FrogCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var configuration = Configuration()
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var hotkeyErrors: [UUID: String] = [:]
    @Published private(set) var isProcessing = false
    @Published private(set) var status = "Ready"
    @Published private(set) var errorMessage: String?
    @Published private(set) var manualResult = ""
    @Published private(set) var isTestingProvider = false
    @Published private(set) var startAtLogin = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var loginStatus = ""

    var openSettings: (() -> Void)?
    private let configurationStore: ConfigurationStore
    private let historyStore: HistoryStore
    private let keychain = KeychainStore()
    private let complete: (String, Rule, ProviderConfiguration, String?) async throws -> String
    private let readKey: (UUID) throws -> String?
    private let writeClipboard: (String) -> Void
    private let registerShortcuts: Bool
    private let hotkeys = HotkeyManager()
    private let selectionService = SelectionService()
    private var processingTask: Task<Void, Never>?
    private var historyEpoch = UUID()
    private var configurationLoadError: Error?

    init(dataDirectory: URL? = nil, registerShortcuts: Bool = true,
         complete: ((String, Rule, ProviderConfiguration, String?) async throws -> String)? = nil,
         readKey: ((UUID) throws -> String?)? = nil,
         writeClipboard: ((String) -> Void)? = nil) {
        let dataDirectory = dataDirectory ?? ProcessInfo.processInfo.environment["FROG_DATA_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.registerShortcuts = registerShortcuts
        self.complete = complete ?? { text, rule, provider, key in try await LLMClient().complete(text: text, rule: rule, provider: provider, apiKey: key) }
        self.readKey = readKey ?? { try KeychainStore().read(providerID: $0) }
        self.writeClipboard = writeClipboard ?? { text in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        configurationStore = ConfigurationStore(directory: dataDirectory)
        historyStore = HistoryStore(directory: dataDirectory)
        do { configuration = try configurationStore.load() }
        catch { configurationLoadError = error; report(error) }
        refreshHistory()
        refreshSystemStatus()
    }

    func start() {
        registerHotkeys()
        if configuration.providers.isEmpty { status = "Add a provider in Settings to get started." }
    }

    func shutdown() {
        processingTask?.cancel()
        hotkeys.unregister()
    }

    func showSettings() { refreshSystemStatus(); openSettings?() }

    func refreshSystemStatus() {
        accessibilityGranted = SelectionService.isTrusted
        startAtLogin = LoginService.isEnabled
        loginStatus = LoginService.statusText
    }

    func setStartAtLogin(_ enabled: Bool) {
        do { try LoginService.setEnabled(enabled); refreshSystemStatus() }
        catch { refreshSystemStatus(); report(error) }
    }

    func report(_ error: Error) { errorMessage = error.localizedDescription }
    func dismissError() { errorMessage = nil }

    private func persist(_ candidate: Configuration) throws {
        if let error = configurationLoadError {
            throw FrogError.message("Settings could not be loaded, so they have not been overwritten. Repair or move the settings file in \(configurationStore.directory.path), then relaunch Frog. \(error.localizedDescription)")
        }
        try configurationStore.save(candidate)
        configuration = candidate
    }

    func saveRule(_ rule: Rule) throws {
        guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !rule.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FrogError.message("Give this rule a name and instructions.")
        }
        if rule.instructions.contains("{{language}}") && rule.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FrogError.message("Set a target language for this translation rule.")
        }
        if let providerID = rule.providerID, !configuration.providers.contains(where: { $0.id == providerID }) {
            throw FrogError.message("The rule's provider no longer exists. Choose another provider.")
        }
        if rule.enabled, let hotkey = rule.hotkey,
           let conflict = configuration.rules.first(where: { $0.id != rule.id && $0.enabled && $0.hotkey == hotkey }) {
            throw FrogError.message("That hotkey is already assigned to \(conflict.name).")
        }
        var candidate = configuration
        if let index = candidate.rules.firstIndex(where: { $0.id == rule.id }) { candidate.rules[index] = rule }
        else { candidate.rules.append(rule) }
        try persist(candidate)
        registerHotkeys()
    }

    func deleteRule(id: UUID) throws {
        var candidate = configuration
        candidate.rules.removeAll { $0.id == id }
        try persist(candidate)
        registerHotkeys()
    }

    func hasAPIKey(_ id: UUID) -> Bool { ((try? keychain.read(providerID: id)) ?? "").isEmpty == false }

    func saveProvider(_ provider: ProviderConfiguration, apiKey: String?, clearKey: Bool) throws {
        try validateProvider(provider)
        var candidate = configuration
        if let index = candidate.providers.firstIndex(where: { $0.id == provider.id }) { candidate.providers[index] = provider }
        else { candidate.providers.append(provider) }
        if candidate.defaultProviderID == nil { candidate.defaultProviderID = provider.id }
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
        let references = configuration.rules.filter { $0.providerID == id }
        guard references.isEmpty else {
            throw FrogError.message("Choose a different provider for these rules first: \(references.map(\.name).joined(separator: ", ")).")
        }
        var candidate = configuration
        candidate.providers.removeAll { $0.id == id }
        if candidate.defaultProviderID == id { candidate.defaultProviderID = nil }
        // Persist first: a Keychain deletion failure is explicit and can be retried by re-adding the provider ID.
        let previous = configuration
        try persist(candidate)
        do { try keychain.delete(providerID: id) }
        catch {
            try? persist(previous)
            throw error
        }
    }

    func setDefaultProvider(id: UUID?) throws {
        if let id, !configuration.providers.contains(where: { $0.id == id }) { throw FrogError.message("Choose an existing provider.") }
        var candidate = configuration; candidate.defaultProviderID = id
        try persist(candidate)
    }

    private func validateProvider(_ provider: ProviderConfiguration) throws {
        guard !provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FrogError.message("Provider name and model are required.") }
        guard let url = URL(string: provider.endpoint), let host = url.host, !host.isEmpty,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw FrogError.message("Enter an HTTP(S) API base URL without credentials, query parameters or fragments.") }
        let scheme = url.scheme?.lowercased()
        if [.openAI, .anthropic, .gemini].contains(provider.kind), scheme != "https" {
            throw FrogError.message("Cloud providers require an HTTPS endpoint.")
        }
        if scheme == "http" && !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) {
            throw FrogError.message("Use HTTPS for remote providers. HTTP is supported only for localhost model services.")
        }
    }

    func testProvider(_ provider: ProviderConfiguration, apiKey: String?) async throws -> String {
        guard !isTestingProvider else { throw FrogError.message("A provider test is already running.") }
        try validateProvider(provider)
        isTestingProvider = true
        defer { isTestingProvider = false }
        let key = (apiKey?.isEmpty == false) ? apiKey : try keychain.read(providerID: provider.id)
        _ = try await complete("Reply with OK.", Rule(name: "Connection test", instructions: "Reply briefly to the user."), provider, key)
        return "Connected to \(provider.name) using \(provider.model)."
    }

    func savePreferences(_ preferences: Preferences) throws {
        guard (1...200).contains(preferences.historyLimit), (1...30).contains(preferences.historyRetentionDays) else {
            throw FrogError.message("History must keep 1–200 entries for 1–30 days.")
        }
        var candidate = configuration; candidate.preferences = preferences
        try persist(candidate)
        if !preferences.historyEnabled { historyEpoch = UUID() }
        refreshHistory()
    }

    func refreshHistory() {
        do { history = try historyStore.load(preferences: configuration.preferences) }
        catch { report(error) }
    }
    func deleteHistory(id: UUID) throws { try historyStore.delete(id: id); refreshHistory() }
    func clearHistory() throws { try historyStore.clear(); historyEpoch = UUID(); refreshHistory() }

    private func registerHotkeys() {
        guard registerShortcuts else { return }
        hotkeyErrors = hotkeys.register(rules: configuration.rules) { [weak self] id in self?.processSelection(ruleID: id) }
    }

    private func resolved(_ rule: Rule) throws -> ProviderConfiguration {
        guard let providerID = rule.providerID ?? configuration.defaultProviderID,
              var provider = configuration.providers.first(where: { $0.id == providerID }) else {
            throw FrogError.message("Choose a provider for \(rule.name), or set a default provider in Settings.")
        }
        if !rule.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { provider.model = rule.model }
        try validateProvider(provider)
        return provider
    }

    private func processSelection(ruleID: UUID) {
        begin(ruleID: ruleID, manualText: nil)
    }

    func processManual(text: String, ruleID: UUID) { begin(ruleID: ruleID, manualText: text) }
    func cancelProcessing() { processingTask?.cancel(); status = "Cancelling…" }

    private func begin(ruleID: UUID, manualText: String?) {
        guard !isProcessing else { status = "A rule is already running. Wait or cancel it from the menu."; return }
        guard let rule = configuration.rules.first(where: { $0.id == ruleID }), rule.enabled else { report(FrogError.message("Select an enabled rule.")); return }
        let provider: ProviderConfiguration
        do { provider = try resolved(rule) }
        catch { finishFailure(error, background: manualText == nil); return }
        isProcessing = true
        errorMessage = nil
        status = "\(rule.name)…"
        let recordingEpoch = historyEpoch
        let recordingWasEnabled = configuration.preferences.historyEnabled
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isProcessing = false; self.processingTask = nil }
            do {
                let selection: TextSelection?
                let text: String
                if let manualText { selection = nil; text = manualText }
                else { let captured = try await self.selectionService.capture(); selection = captured; text = captured.text }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FrogError.message("Select or enter some text first.") }
                let key = try self.readKey(provider.id)
                try Task.checkCancellation()
                let result = try await self.complete(text, rule, provider, key)
                try Task.checkCancellation()
                guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FrogError.message("The model returned no text. Nothing was replaced.") }
                if let selection {
                    do { try await selection.replace(with: result); self.status = "\(rule.name) complete — selection replaced and copied." }
                    catch {
                        self.status = "Result ready on clipboard; replacement skipped."
                        self.errorMessage = error.localizedDescription
                        DesktopNotifications.post(title: "Frog: result copied", body: error.localizedDescription)
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
        if background { DesktopNotifications.post(title: "Frog", body: error.localizedDescription) }
    }
}
