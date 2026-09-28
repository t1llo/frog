import Foundation

/// The portable JSON format contains settings only. Credentials and history have separate stores.
public enum ConfigurationFile {
    public static let maximumBytes = 4 * 1_024 * 1_024

    public static func encode(_ configuration: Configuration) throws -> Data {
        try validate(configuration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(configuration)
        data.append(0x0A)
        guard data.count <= maximumBytes else { throw FrogError.message("The configuration file is too large (maximum 4 MB).") }
        return data
    }

    public static func decode(_ data: Data) throws -> Configuration {
        guard data.count <= maximumBytes else { throw FrogError.message("The configuration file is too large (maximum 4 MB).") }
        let configuration: Configuration
        do { configuration = try JSONDecoder().decode(Configuration.self, from: data) }
        catch { throw FrogError.message("This is not a valid Frog configuration file. Check its JSON fields and values.") }
        try validate(configuration)
        return configuration
    }

    public static func read(from url: URL) throws -> Configuration {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw FrogError.message("Choose a regular JSON configuration file.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try decode(handle.read(upToCount: maximumBytes + 1) ?? Data())
    }

    public static func write(_ configuration: Configuration, to url: URL) throws {
        try encode(configuration).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func validate(_ configuration: Configuration) throws {
        guard configuration.version == 1 else { throw FrogError.message("This configuration version is not supported by this version of Frog.") }
        guard (configuration.localModels?.count ?? 0) <= 100,
              Set(configuration.modelCatalog.map(\.id)).count == configuration.modelCatalog.count else {
            throw FrogError.message("Keep at most 100 custom models with unique IDs.")
        }
        for model in configuration.localModels ?? [] { try model.validateCustom() }
        let providerIDs = Set(configuration.providers.map(\.id))
        guard providerIDs.count == configuration.providers.count,
              Set(configuration.rules.map(\.id)).count == configuration.rules.count else {
            throw FrogError.message("The configuration contains duplicate provider or rule IDs.")
        }
        if let id = configuration.defaultProviderID, !providerIDs.contains(id) {
            throw FrogError.message("The default provider is missing from this configuration.")
        }
        for provider in configuration.providers { try validate(provider: provider) }
        var shortcuts = Set<Hotkey>()
        if let key = configuration.preferences.workflowSettings.shortcutPanelHotkey { shortcuts.insert(key) }
        if let key = configuration.preferences.workflowSettings.cancelRecordingHotkey, !shortcuts.insert(key).inserted { throw FrogError.message("The cancel shortcut conflicts with the shortcut panel.") }
        for rule in configuration.rules {
            if rule.category == .application {
                guard let path = rule.action?.applicationPath, path.hasSuffix(".app"), path.hasPrefix("/"),
                      rule.action?.applicationBundleID?.isEmpty == false else {
                    throw FrogError.message("Choose an application for \(rule.name).")
                }
            }
            if let id = rule.action?.audioModelID {
                if let providerID = rule.action?.audioProviderID {
                    guard let provider = configuration.providers.first(where: { $0.id == providerID }), provider.kind.supportsTranscription,
                          provider.models.contains(where: { $0.id == id && $0.category == .audio }) else { throw FrogError.message("Choose a configured speech-to-text model.") }
                } else if configuration.localModel(id)?.kind != .audio { throw FrogError.message("Choose an available audio model.") }
            }
            if let id = rule.action?.localTextModelID, configuration.localModel(id)?.kind != .text {
                throw FrogError.message("Choose an available local text model.")
            }
            guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  rule.category == .application || !rule.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  rule.instructions.utf8.count <= 100_000 else {
                throw FrogError.message("Each rule needs a name and instructions of at most 100,000 bytes.")
            }
            if let id = rule.providerID, !providerIDs.contains(id) {
                throw FrogError.message("A rule refers to a provider that is missing from this configuration.")
            }
            guard rule.model.utf8.count <= 256,
                  !rule.model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw FrogError.message("A rule contains an invalid model name.")
            }
            if !rule.model.isEmpty {
                guard let provider = configuration.providers.first(where: { $0.id == (rule.providerID ?? configuration.defaultProviderID) }),
                      provider.models.contains(where: { $0.id == rule.model && $0.category == .text }) else {
                    throw FrogError.message("Choose a configured model for \(rule.name). Add it in Providers first.")
                }
            }
            if rule.instructions.contains("{{language}}") {
                let language = rule.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !language.isEmpty, language.utf8.count <= 256 else { throw FrogError.message("Each translation rule needs a target language.") }
            }
            if rule.enabled, let hotkey = rule.hotkey, !shortcuts.insert(hotkey).inserted {
                throw FrogError.message("Two enabled rules use the same shortcut. Give each rule its own shortcut before importing.")
            }
        }
        let preferences = configuration.preferences
        guard (preferences.appearance ?? AppearancePreferences()).valid else {
            throw FrogError.message("Appearance requires a six-digit accent hex color and transparency between 0 and 1.")
        }
        let workflow = preferences.workflowSettings
        if let language = workflow.applicationLanguage, !WorkflowPreferences.interfaceLanguages.contains(language) { throw FrogError.message("Choose English, German or the system language.") }
        if let language = workflow.transcriptionLanguage, !WorkflowPreferences.speechLanguages.contains(language) { throw FrogError.message("Choose a supported transcription language.") }
        guard configuration.localModel(workflow.audioModelID)?.kind == .audio,
              configuration.localModel(workflow.cleanupModelID)?.kind == .text,
              workflow.defaultLocalTextModelID == nil || configuration.localModel(workflow.defaultLocalTextModelID!)?.kind == .text,
              (0...3600).contains(workflow.idleUnloadSeconds) else {
            throw FrogError.message("Choose valid default local models and an unload delay between 0 and 3600 seconds.")
        }
        guard (1...200).contains(preferences.historyLimit), (1...30).contains(preferences.historyRetentionDays) else {
            throw FrogError.message("History must keep 1–200 entries for 1–30 days.")
        }
    }

    public static func validate(provider: ProviderConfiguration) throws {
        guard !provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              provider.model.utf8.count <= 256,
              !provider.model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FrogError.message("Provider name and a valid model are required.")
        }
        guard !provider.models.isEmpty, provider.models.count <= 200,
              Set(provider.models.map(\.id)).count == provider.models.count,
              provider.models.contains(where: { $0.id == provider.model }),
              provider.models.allSatisfy({ model in
                  !model.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.id.utf8.count <= 256 &&
                  model.id == model.id.trimmingCharacters(in: .whitespacesAndNewlines) &&
                  !model.id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
                  !model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.name.utf8.count <= 256
               }) else { throw FrogError.message("Configure 1–200 unique models.") }
        if provider.models.contains(where: { $0.category == .audio }), !provider.kind.supportsTranscription {
            throw FrogError.message("This service supports text models only. Use OpenAI, Gemini or a compatible transcription endpoint for speech-to-text.")
        }
        try validateEndpoint(provider)
    }

    public static func validateEndpoint(_ provider: ProviderConfiguration) throws {
        guard let url = URLComponents(string: provider.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty, let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.url != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw FrogError.message("Enter an HTTP(S) API base URL without credentials, query parameters or fragments.")
        }
        if [.openAI, .anthropic, .gemini].contains(provider.kind), scheme != "https" {
            throw FrogError.message("Cloud providers require an HTTPS endpoint.")
        }
        if scheme == "http" && !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) {
            throw FrogError.message("Use HTTPS for remote providers. HTTP is supported only for localhost model services.")
        }
    }
}
