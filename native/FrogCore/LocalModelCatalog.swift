import Foundation

public struct LocalModelDescriptor: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, audio }
    public enum Backend: String, Codable, Sendable { case whisperKit, parakeet, mlx }
    public let id: String
    public let name: String
    public let kind: Kind
    public let repository: String
    public let variant: String?
    public let size: String
    public let backend: Backend
    public let originalRepository: String?
    public let license: String?

    public init(id: String, name: String, kind: Kind, repository: String, variant: String? = nil, size: String, backend: Backend? = nil, originalRepository: String? = nil, license: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.repository = repository; self.variant = variant; self.size = size
        self.backend = backend ?? (kind == .audio ? .whisperKit : .mlx)
        self.originalRepository = originalRepository; self.license = license
    }
    public var sourceURL: URL { URL(string: "https://huggingface.co/\(repository)")! }
    public var filesURL: URL { sourceURL.appendingPathComponent("tree/main").appendingPathComponent(backend == .whisperKit ? variant ?? "" : "") }
    public var runtimeName: String { switch backend { case .whisperKit: "WhisperKit / Core ML"; case .parakeet: "FluidAudio / Core ML"; case .mlx: "MLX" } }
    public var englishOnly: Bool { (backend == .parakeet && variant == "v2") || (backend == .whisperKit && variant?.contains(".en") == true) }
    public var supportsLanguageSelection: Bool { backend == .whisperKit && !englishOnly }
    public var languages: String {
        if englishOnly { return "English only" }
        if backend == .parakeet { return "25 European languages · automatic" }
        return kind == .audio ? "Multilingual · automatic or selected language" : "See model card for languages"
    }
    public var streaming: String { kind == .audio ? "Live preview" : "Token streaming" }
    public static let catalog: [Self] = [
        whisper("whisper-tiny", "Whisper Tiny", "openai_whisper-tiny", "≈80 MB", "openai/whisper-tiny"),
        whisper("whisper-base", "Whisper Base", "openai_whisper-base", "≈150 MB", "openai/whisper-base"),
        whisper("whisper-small", "Whisper Small", "openai_whisper-small", "≈500 MB", "openai/whisper-small"),
        whisper("whisper-medium", "Whisper Medium", "openai_whisper-medium", "≈1.5 GB", "openai/whisper-medium"),
        whisper("whisper-large-v3", "Whisper Large v3", "openai_whisper-large-v3", "≈3 GB", "openai/whisper-large-v3"),
        whisper("whisper-large-v3-turbo", "Whisper Large v3 Turbo", "openai_whisper-large-v3-v20240930_turbo_632MB", "≈650 MB", "openai/whisper-large-v3-turbo"),
        .init(id: "parakeet-v3", name: "NVIDIA Parakeet TDT v3", kind: .audio, repository: "FluidInference/parakeet-tdt-0.6b-v3-coreml", variant: "v3", size: "≈485 MB", backend: .parakeet, originalRepository: "nvidia/parakeet-tdt-0.6b-v3", license: "CC-BY-4.0"),
        .init(id: "parakeet-v2", name: "NVIDIA Parakeet TDT v2 · English", kind: .audio, repository: "FluidInference/parakeet-tdt-0.6b-v2-coreml", variant: "v2", size: "≈465 MB", backend: .parakeet, originalRepository: "nvidia/parakeet-tdt-0.6b-v2", license: "CC-BY-4.0"),
        .init(id: "qwen-0.6b", name: "Qwen3 0.6B · 4-bit", kind: .text, repository: "mlx-community/Qwen3-0.6B-4bit", size: "≈400 MB", originalRepository: "Qwen/Qwen3-0.6B", license: "Apache-2.0"),
        .init(id: "qwen-1.7b", name: "Qwen3 1.7B · 4-bit", kind: .text, repository: "mlx-community/Qwen3-1.7B-4bit", size: "≈1 GB", originalRepository: "Qwen/Qwen3-1.7B", license: "Apache-2.0"),
        .init(id: "qwen-4b", name: "Qwen3 4B · 4-bit", kind: .text, repository: "mlx-community/Qwen3-4B-4bit", size: "≈2.5 GB", originalRepository: "Qwen/Qwen3-4B", license: "Apache-2.0"),
        .init(id: "llama-1b", name: "Llama 3.2 1B Instruct · 4-bit", kind: .text, repository: "mlx-community/Llama-3.2-1B-Instruct-4bit", size: "≈800 MB", originalRepository: "meta-llama/Llama-3.2-1B-Instruct", license: "Llama 3.2 Community License"),
        .init(id: "llama-3b", name: "Llama 3.2 3B Instruct · 4-bit", kind: .text, repository: "mlx-community/Llama-3.2-3B-Instruct-4bit", size: "≈2 GB", originalRepository: "meta-llama/Llama-3.2-3B-Instruct", license: "Llama 3.2 Community License"),
        .init(id: "gemma-1b", name: "Gemma 3 1B · 4-bit", kind: .text, repository: "mlx-community/gemma-3-1b-it-4bit", size: "≈800 MB", originalRepository: "google/gemma-3-1b-it", license: "Gemma Terms")
    ]
    private static func whisper(_ id: String, _ name: String, _ variant: String, _ size: String, _ original: String) -> Self {
        .init(id: id, name: name, kind: .audio, repository: "argmaxinc/whisperkit-coreml", variant: variant, size: size, originalRepository: original, license: "MIT")
    }
    public static func find(_ id: String) -> Self? { catalog.first { $0.id == id } }
    public static var recommended: [Self] { catalog.filter(\.isRecommended) }
    public var isRecommended: Bool { id == "whisper-small" || id == "qwen-1.7b" }
}

extension Configuration {
    public var modelCatalog: [LocalModelDescriptor] { LocalModelDescriptor.catalog + (localModels ?? []) }
    public func localModel(_ id: String) -> LocalModelDescriptor? { modelCatalog.first { $0.id == id } }
    public mutating func selectSoleInstalledModel(_ model: LocalModelDescriptor, installed: Set<String>) {
        guard installed.contains(model.id), modelCatalog.filter({ $0.kind == model.kind && installed.contains($0.id) }).count == 1 else { return }
        var workflow = preferences.workflowSettings
        if model.kind == .audio { workflow.audioModelID = model.id }
        else {
            let useLocal = workflow.effectiveTextSource == .frog || defaultProviderID == nil
            workflow.defaultLocalTextModelID = model.id
            workflow.cleanupModelID = model.id
            workflow.textSource = useLocal ? .frog : .provider
        }
        preferences.workflows = workflow
    }
}
