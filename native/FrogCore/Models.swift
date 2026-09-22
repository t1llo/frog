import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI, anthropic, gemini, ollama, compatible
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic / Claude"
        case .gemini: return "Google Gemini"
        case .ollama: return "Ollama (local)"
        case .compatible: return "OpenAI-compatible"
        }
    }
    public var endpoint: String {
        switch self {
        case .openAI, .compatible: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .ollama: return "http://localhost:11434"
        }
    }
    public var defaultModel: String {
        switch self {
        case .openAI, .compatible: return "gpt-4o-mini"
        case .anthropic: return "claude-sonnet-4-20250514"
        case .gemini: return "gemini-2.5-flash"
        case .ollama: return "llama3.2"
        }
    }
}

public struct ProviderConfiguration: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ProviderKind
    public var endpoint: String
    public var model: String
    public init(id: UUID = UUID(), name: String = "OpenAI", kind: ProviderKind = .openAI, endpoint: String? = nil, model: String? = nil) {
        self.id = id; self.name = name; self.kind = kind
        self.endpoint = endpoint ?? kind.endpoint; self.model = model ?? kind.defaultModel
    }
}

/// Carbon-compatible virtual key code and modifier bits; persisted independently of UI events.
public struct Hotkey: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
}

public struct Rule: Codable, Identifiable, Equatable, Sendable {
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
            Rule(name: "Translate to English", instructions: "Translate into {{language}}, preserving meaning, tone, and formatting. Return only the translation.", targetLanguage: "English", hotkey: Hotkey(keyCode: 17, modifiers: mods), preset: true),
            Rule(name: "Translate to German", instructions: "Translate into {{language}}, preserving meaning, tone, and formatting. Return only the translation.", targetLanguage: "German", hotkey: Hotkey(keyCode: 5, modifiers: mods), preset: true)
        ]
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var historyEnabled = false
    public var historyLimit = 200
    public var historyRetentionDays = 30
    public init() {}
}

public struct Configuration: Codable, Equatable, Sendable {
    public var version = 1
    public var providers: [ProviderConfiguration] = []
    public var defaultProviderID: UUID?
    public var rules: [Rule] = Rule.presets
    public var preferences = Preferences()
    public init() {}
}

public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
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
