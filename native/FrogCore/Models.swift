import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI, anthropic, gemini, ollama, lmStudio, compatible, claudeCode, codex, opencode
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic / Claude"
        case .gemini: return "Google Gemini"
        case .ollama: return "Ollama (local)"
        case .lmStudio: return "LM Studio (local)"
        case .compatible: return "OpenAI-compatible"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }
    public var endpoint: String {
        switch self {
        case .openAI, .compatible: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .ollama: return "http://localhost:11434"
        case .lmStudio: return "http://localhost:1234/v1"
        case .claudeCode, .codex, .opencode: return ""
        }
    }
    public var defaultModel: String {
        switch self {
        case .openAI: return "gpt-6-luna"
        case .anthropic: return "claude-sonnet-5"
        case .gemini: return "gemini-3.8-flash"
        case .ollama: return "llama3.2"
        case .lmStudio, .compatible: return ""
        case .claudeCode, .codex, .opencode: return LocalToolKind.defaultModelID
        }
    }

    public var isLocal: Bool { self == .ollama || self == .lmStudio }
    public var localTool: LocalToolKind? {
        switch self {
        case .claudeCode: .claudeCode
        case .codex: .codex
        case .opencode: .opencode
        default: nil
        }
    }

    /// Text models verified against the official catalogs on 2026-09-22.
    public var suggestedModels: [ProviderModel] {
        switch self {
        case .openAI: return [.init(id: "gpt-6-luna", name: "GPT-6 Luna"), .init(id: "gpt-6-sol", name: "GPT-6 Sol"), .init(id: "gpt-6-astra", name: "GPT-6 Astra")]
        case .anthropic: return [.init(id: "claude-sonnet-5", name: "Claude Sonnet 5"), .init(id: "claude-haiku-4-5-20251001", name: "Claude Haiku 4.5"), .init(id: "claude-opus-5-5", name: "Claude Opus 5.5"), .init(id: "claude-fable-5-1", name: "Claude Fable 5.1")]
        case .gemini: return [
            .init(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash"),
            .init(id: "gemini-3.7-flash", name: "Gemini 3.7 Flash"),
            .init(id: "gemini-3.6-flash", name: "Gemini 3.6 Flash"),
            .init(id: "gemini-3.5-flash", name: "Gemini 3.5 Flash"),
            .init(id: "gemini-3.5-flash-lite", name: "Gemini 3.5 Flash-Lite"),
            .init(id: "gemini-3.1-flash-lite", name: "Gemini 3.1 Flash-Lite"),
            .init(id: "gemini-3.1-pro-preview", name: "Gemini 3.1 Pro (preview)"),
            .init(id: "gemini-3-flash-preview", name: "Gemini 3 Flash (preview)"),
            .init(id: "gemini-2.5-flash", name: "Gemini 2.5 Flash (existing API users)"),
            .init(id: "gemini-2.5-flash-lite", name: "Gemini 2.5 Flash-Lite (existing API users)"),
            .init(id: "gemini-2.5-pro", name: "Gemini 2.5 Pro (existing API users)")
        ]
        case .ollama: return [.init(id: "llama3.2", name: "Llama 3.2")]
        case .lmStudio, .compatible: return []
        case .claudeCode, .codex, .opencode:
            return localTool!.suggestedModels.map { ProviderModel(id: $0.id.isEmpty ? LocalToolKind.defaultModelID : $0.id, name: $0.name) }
        }
    }

    public var setupURL: URL {
        switch self {
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")!
        case .anthropic: return URL(string: "https://platform.claude.com/settings/keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        case .ollama: return URL(string: "https://ollama.com/download")!
        case .lmStudio: return URL(string: "https://lmstudio.ai/docs/developer/core/server")!
        case .compatible: return URL(string: "https://platform.openai.com/docs/api-reference")!
        case .claudeCode: return URL(string: "https://code.claude.com/docs/en/setup")!
        case .codex: return URL(string: "https://developers.openai.com/codex/cli/")!
        case .opencode: return URL(string: "https://opencode.ai/docs/")!
        }
    }
}

public struct ProviderModel: Codable, Identifiable, Equatable, Sendable {
    public enum Category: String, Codable, CaseIterable, Sendable { case text, audio }
    public var id: String
    public var name: String
    public var category: Category
    public init(id: String, name: String? = nil, category: Category = .text) { self.id = id; self.name = name ?? id; self.category = category }
    private enum CodingKeys: String, CodingKey { case id, name, category }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        category = try values.decodeIfPresent(Category.self, forKey: .category) ?? .text
    }
}

public struct ProviderConfiguration: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ProviderKind
    public var endpoint: String
    public var model: String
    public var models: [ProviderModel]
    public init(id: UUID = UUID(), name: String = "OpenAI", kind: ProviderKind = .openAI, endpoint: String? = nil, model: String? = nil, models: [ProviderModel]? = nil) {
        self.id = id; self.name = name; self.kind = kind
        self.endpoint = endpoint ?? kind.endpoint; self.model = model ?? kind.defaultModel
        self.models = models ?? (model.map { [ProviderModel(id: $0)] } ?? kind.suggestedModels)
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, endpoint, model, models }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(ProviderKind.self, forKey: .kind)
        endpoint = try values.decode(String.self, forKey: .endpoint)
        model = try values.decode(String.self, forKey: .model)
        // Existing connections keep their exact model; catalog updates never overwrite user settings.
        models = try values.decodeIfPresent([ProviderModel].self, forKey: .models) ?? [ProviderModel(id: model)]
    }

    public func modelName(_ id: String) -> String { models.first { $0.id == id }?.name ?? id }
}

/// Carbon-compatible virtual key code and modifier bits; persisted independently of UI events.
public struct Hotkey: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
}

public struct Rule: Codable, Identifiable, Equatable, Sendable {
    public var action: RuleAction?
    public var id: UUID
    public var name: String
    public var instructions: String
    public var providerID: UUID?
    public var model: String
    public var targetLanguage: String
    public var hotkey: Hotkey?
    public var enabled: Bool
    public var preset: Bool
    public init(id: UUID = UUID(), name: String = "Custom rule", instructions: String = "Improve the following text. Return only the revised text.", providerID: UUID? = nil, model: String = "", targetLanguage: String = "", hotkey: Hotkey? = nil, enabled: Bool = true, preset: Bool = false) {
        self.id = id; self.name = name; self.instructions = instructions; self.providerID = providerID
        self.model = model; self.targetLanguage = targetLanguage; self.hotkey = hotkey; self.enabled = enabled; self.preset = preset
    }
    public static var presets: [Rule] {
        let mods: UInt32 = 4096 | 512 // Control + Shift
        return [
            Rule(name: "Proofread", instructions: "Fix grammar, punctuation, and spelling while preserving meaning, tone, and formatting. Return only the corrected text.", hotkey: Hotkey(keyCode: 8, modifiers: mods), preset: true),
            Rule(name: "Spelling only", instructions: "Correct spelling mistakes only. Preserve wording, grammar, tone, and formatting otherwise. Return only the corrected text.", hotkey: Hotkey(keyCode: 1, modifiers: mods), preset: true),
            Rule(name: "Polish email", instructions: "Polish this email for clarity and a professional, friendly tone. Preserve facts and intent. Return only the revised email.", hotkey: Hotkey(keyCode: 14, modifiers: mods), preset: true),
            Rule(name: "Translate to English", instructions: "Translate into English, preserving meaning, tone, and formatting. Return only the translation.", hotkey: Hotkey(keyCode: 17, modifiers: mods), preset: true),
            Rule(name: "Translate to German", instructions: "Translate into German, preserving meaning, tone, and formatting. Return only the translation.", hotkey: Hotkey(keyCode: 5, modifiers: mods), preset: true)
        ]
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var historyEnabled = false
    public var hideHistoryText = false
    public var historyLimit = 200
    public var historyRetentionDays = 30
    public var showProcessingIndicator = true
    public var windowSwitcherEnabled = true
    public var applicationShortcutsEnabled: Bool?
    public var shortcutsEnabled: Bool { applicationShortcutsEnabled ?? true }
    public var workflows: WorkflowPreferences?
    public var appearance: AppearancePreferences?
    public var toolkit: ToolkitPreferences?
    public var workflowSettings: WorkflowPreferences { workflows ?? WorkflowPreferences() }
    public init() {}

    private enum CodingKeys: String, CodingKey { case historyEnabled, hideHistoryText, historyLimit, historyRetentionDays, showProcessingIndicator, windowSwitcherEnabled, applicationShortcutsEnabled, workflows, appearance, toolkit }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        historyEnabled = try values.decode(Bool.self, forKey: .historyEnabled)
        hideHistoryText = try values.decodeIfPresent(Bool.self, forKey: .hideHistoryText) ?? false
        historyLimit = try values.decode(Int.self, forKey: .historyLimit)
        historyRetentionDays = try values.decode(Int.self, forKey: .historyRetentionDays)
        showProcessingIndicator = try values.decodeIfPresent(Bool.self, forKey: .showProcessingIndicator) ?? true
        windowSwitcherEnabled = try values.decodeIfPresent(Bool.self, forKey: .windowSwitcherEnabled) ?? true
        applicationShortcutsEnabled = try values.decodeIfPresent(Bool.self, forKey: .applicationShortcutsEnabled)
        workflows = try values.decodeIfPresent(WorkflowPreferences.self, forKey: .workflows)
        appearance = try values.decodeIfPresent(AppearancePreferences.self, forKey: .appearance)
        toolkit = try values.decodeIfPresent(ToolkitPreferences.self, forKey: .toolkit)
    }
}

public struct Configuration: Codable, Equatable, Sendable {
    var originalJSON: ConfigurationJSON?
    var knownJSON: ConfigurationJSON?
    public var explicitRuleModels: Bool?
    public var recentModels: [RuleModelSelection]?
    public var localModels: [LocalModelDescriptor]?
    public var version = 1
    public var providers: [ProviderConfiguration] = []
    public var defaultProviderID: UUID?
    public var rules: [Rule] = Rule.presets
    public var preferences = Preferences()
    public init() {}

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version && lhs.explicitRuleModels == rhs.explicitRuleModels && lhs.recentModels == rhs.recentModels &&
        lhs.localModels == rhs.localModels && lhs.providers == rhs.providers && lhs.defaultProviderID == rhs.defaultProviderID &&
        lhs.rules == rhs.rules && lhs.preferences == rhs.preferences
    }

    /// Imports may change credential identities without losing connection extension fields.
    public mutating func remapProviderIDs(_ ids: [UUID: UUID]) {
        for index in providers.indices { providers[index].id = ids[providers[index].id] ?? providers[index].id }
        if let id = defaultProviderID { defaultProviderID = ids[id] ?? id }
        for index in rules.indices {
            if let id = rules[index].providerID { rules[index].providerID = ids[id] ?? id }
            if let id = rules[index].action?.audioProviderID { rules[index].action?.audioProviderID = ids[id] ?? id }
        }
        recentModels = recentModels?.map { var item = $0; if let id = item.providerID { item.providerID = ids[id] ?? id }; return item }
        originalJSON = originalJSON?.remappingProviders(ids)
        knownJSON = knownJSON?.remappingProviders(ids)
    }

    private enum CodingKeys: String, CodingKey { case version, providers, defaultProviderID, rules, preferences, localModels, explicitRuleModels, recentModels }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        explicitRuleModels = try values.decodeIfPresent(Bool.self, forKey: .explicitRuleModels)
        recentModels = try values.decodeIfPresent([RuleModelSelection].self, forKey: .recentModels)
        localModels = try values.decodeIfPresent([LocalModelDescriptor].self, forKey: .localModels)
        providers = try values.decode([ProviderConfiguration].self, forKey: .providers)
        defaultProviderID = try values.decodeIfPresent(UUID.self, forKey: .defaultProviderID)
        rules = try values.decode([Rule].self, forKey: .rules)
        preferences = try values.decode(Preferences.self, forKey: .preferences)
        // Bring legacy free-text overrides into their connection's model list.
        let rawProviders = try values.decode([LegacyProviderFields].self, forKey: .providers)
        for rule in rules where !rule.model.isEmpty {
            if let index = providers.firstIndex(where: { $0.id == (rule.providerID ?? defaultProviderID) }),
               rawProviders[index].models == nil, !providers[index].models.contains(where: { $0.id == rule.model }) {
                providers[index].models.append(ProviderModel(id: rule.model))
            }
        }
    }

    private struct LegacyProviderFields: Decodable { var models: [ProviderModel]? }
}

public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Interruption: String, Codable, Sendable { case escape, cancelled }
    public enum TranscriptState: String, Codable, Sendable { case partial, complete, failed }
    // Optional metadata keeps history written by older versions readable.
    public var interruption: Interruption?
    public var transcriptState: TranscriptState?
    public var category: RuleCategory?
    public var id: UUID
    public var timestamp: Date
    public var originalText: String
    public var processedText: String
    public var ruleName: String
    public var providerName: String
    public var model: String
    public var targetLanguage: String
    public init(id: UUID = UUID(), timestamp: Date = Date(), originalText: String, processedText: String, ruleName: String, providerName: String, model: String, targetLanguage: String = "") {
        self.id = id; self.timestamp = timestamp; self.originalText = originalText; self.processedText = processedText
        self.ruleName = ruleName; self.providerName = providerName; self.model = model; self.targetLanguage = targetLanguage
    }
}

public enum FrogError: LocalizedError, Equatable {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
