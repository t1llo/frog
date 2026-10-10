import Foundation

/// Portable identity only. Executable paths and CLI credentials are machine-local.
public enum LocalToolKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode, codex, opencode
    /// Portable nonempty selection for rule pickers; omitted from CLI arguments.
    public static let defaultModelID = "@default"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        }
    }
    public var executableName: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .opencode: "opencode"
        }
    }
    public var loginInstructions: String {
        switch self {
        case .claudeCode: "Install Claude Code, then run claude auth login in your terminal. Claude Desktop alone is not supported."
        case .codex: "Install Codex CLI, then run codex login in your terminal."
        case .opencode: "Install OpenCode V2, then connect your provider in OpenCode with /connect."
        }
    }
    /// Suggestions, not claims about the account's entitlements. Empty means CLI default.
    public var suggestedModels: [LocalToolModel] {
        let defaults = [LocalToolModel(id: "", name: "Tool default")]
        switch self {
        case .claudeCode: return defaults + ["haiku", "sonnet", "opus"].map { LocalToolModel(id: $0, name: $0.capitalized) }
        case .codex, .opencode: return defaults
        }
    }
}

public struct LocalToolModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public enum LocalToolAuthentication: String, Sendable {
    case notChecked, signedIn, signedOut, unknown
}

/// A status check never exports credentials or proves that a paid request will succeed.
public struct LocalToolStatus: Identifiable, Sendable {
    public let kind: LocalToolKind
    public let installed: Bool
    public let authentication: LocalToolAuthentication
    public let supportsTextTransforms: Bool
    public let detail: String
    public var id: LocalToolKind { kind }
    public init(kind: LocalToolKind, installed: Bool, authentication: LocalToolAuthentication,
                supportsTextTransforms: Bool, detail: String) {
        self.kind = kind; self.installed = installed; self.authentication = authentication
        self.supportsTextTransforms = supportsTextTransforms; self.detail = detail
    }
}

public struct LocalToolRequest: Sendable {
    public let kind: LocalToolKind
    public let model: String
    public let instructions: String
    public let text: String

    public init(kind: LocalToolKind, model: String = "", instructions: String, text: String) throws {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidModel(model) else { throw FrogError.message("Enter a valid coding-tool model name, or leave it empty for the tool default.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 1_000_000, !text.contains("\0") else {
            throw FrogError.message("Enter text of at most 1,000,000 bytes without null characters.")
        }
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              instructions.utf8.count <= 100_000, !instructions.contains("\0") else {
            throw FrogError.message("Enter rule instructions of at most 100,000 bytes without null characters.")
        }
        self.kind = kind; self.model = model; self.instructions = instructions; self.text = text
    }

    public init(kind: LocalToolKind, text: String, rule: Rule, providerModel: String = "") throws {
        var instructions = rule.instructions
        if instructions.contains("{{language}}") {
            let language = rule.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !language.isEmpty, language.utf8.count <= 256 else { throw FrogError.message("Choose a target language for this rule.") }
            instructions = instructions.replacingOccurrences(of: "{{language}}", with: language)
        }
        let override = rule.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = override.isEmpty ? providerModel : override
        try self.init(kind: kind, model: selected == LocalToolKind.defaultModelID ? "" : selected, instructions: instructions, text: text)
    }

    public static func isValidModel(_ value: String) -> Bool {
        value.utf8.count <= 256 && !value.hasPrefix("-") && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:/#@").contains($0)
        }
    }
}
