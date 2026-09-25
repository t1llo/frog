import Foundation

public enum RuleCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case text, audio, application
    public var id: String { rawValue }
    public var title: String { switch self { case .text: "Text"; case .audio: "Audio"; case .application: "Applications" } }
}

public enum RecordingMode: String, Codable, CaseIterable, Sendable {
    case toggle, hold
    public var title: String { self == .toggle ? "Press to toggle" : "Hold to record" }
}

public enum TranscriptOutput: String, Codable, CaseIterable, Sendable {
    case copy, paste
    public var title: String { self == .copy ? "Copy" : "Copy and paste" }
}

public struct RuleAction: Codable, Equatable, Sendable {
    public var category: RuleCategory = .text
    public var applicationPath: String?
    public var applicationBundleID: String?
    public var audioModelID: String?
    public var localTextModelID: String?
    public var recordingMode: RecordingMode?
    public var output: TranscriptOutput?
    public var cleanup = true
    public init(category: RuleCategory = .text) { self.category = category }
}

public struct WorkflowPreferences: Codable, Equatable, Sendable {
    public var audioModelID = "whisper-small"
    public var cleanupModelID = "qwen-0.6b"
    public var defaultLocalTextModelID: String?
    public var recordingMode: RecordingMode = .toggle
    public var output: TranscriptOutput = .copy
    public var microphoneID: String?
    public var idleUnloadSeconds = 120
    public var showDictationPopup = true
    public var shortcutPanelHotkey: Hotkey?
    public init() {}
}

public struct LocalModelDescriptor: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case text, audio }
    public let id: String
    public let name: String
    public let kind: Kind
    public let repository: String
    public let variant: String?
    public let size: String
    public static let catalog: [Self] = [
        .init(id: "whisper-small", name: "Whisper Small", kind: .audio, repository: "argmaxinc/whisperkit-coreml", variant: "openai_whisper-small", size: "≈500 MB"),
        .init(id: "whisper-base", name: "Whisper Base", kind: .audio, repository: "argmaxinc/whisperkit-coreml", variant: "openai_whisper-base", size: "≈150 MB"),
        .init(id: "qwen-0.6b", name: "Qwen3 0.6B · 4-bit", kind: .text, repository: "mlx-community/Qwen3-0.6B-4bit", variant: nil, size: "≈400 MB"),
        .init(id: "qwen-1.7b", name: "Qwen3 1.7B · 4-bit", kind: .text, repository: "mlx-community/Qwen3-1.7B-4bit", variant: nil, size: "≈1 GB")
    ]
    public static func find(_ id: String) -> Self? { catalog.first { $0.id == id } }
}

extension Rule {
    public var category: RuleCategory { action?.category ?? .text }
    public static var dictationPreset: Rule {
        var rule = Rule(name: "Dictate", instructions: "Clean up this transcript. Fix punctuation, spelling and obvious speech recognition mistakes. Preserve meaning and language. Return only the corrected text, without commentary.", preset: true)
        rule.action = RuleAction(category: .audio)
        return rule
    }
}
