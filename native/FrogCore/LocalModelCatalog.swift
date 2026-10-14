import Foundation

public struct LocalModelDescriptor: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, audio }
    public enum Backend: String, Codable, Sendable { case whisperKit, parakeet, mlx }
    public let id: String
    public let name: String
    public let kind: Kind
    public let repository: String
    public let variant: String?
    /// What to say about the size when `downloadBytes` is unknown.
    public let size: String
    /// The bytes that Frog's download of the model fetches. Optional, so saved
    /// custom models from before it still load.
    public let downloadBytes: Int64?
    public let backend: Backend
    public let originalRepository: String?
    public let license: String?

    public init(id: String, name: String, kind: Kind, repository: String, variant: String? = nil, size: String = "", downloadBytes: Int64? = nil, backend: Backend? = nil, originalRepository: String? = nil, license: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.repository = repository; self.variant = variant; self.size = size; self.downloadBytes = downloadBytes
        self.backend = backend ?? (kind == .audio ? .whisperKit : .mlx)
        self.originalRepository = originalRepository; self.license = license
    }
    /// The download size to show: the byte count when known, otherwise the text.
    public var downloadSize: String { downloadBytes.map(Self.byteCount) ?? size }
    /// Bytes as Frog shows them, in its English interface whatever the region.
    public static func byteCount(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(Locale(identifier: "en")))
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
    // `downloadBytes` sums the files that Frog's download fetches, as the Hugging Face
    // API (`api/models/<repository>?blobs=true`) listed them on 2026-10-14: the WhisperKit
    // variant folder plus the tokenizer files of the upstream OpenAI model, the four
    // Parakeet Core ML components and their vocabulary, and the MLX files that match
    // `mlxDownloadPatterns`.
    public static let catalog: [Self] = [
        whisper("whisper-tiny", "Whisper Tiny", "openai_whisper-tiny", 79_400_529, "openai/whisper-tiny"),
        whisper("whisper-small-216mb", "Whisper Small · Compact", "openai_whisper-small_216MB", 220_115_879, "openai/whisper-small"),
        .init(id: "parakeet-v3", name: "NVIDIA Parakeet TDT v3", kind: .audio, repository: "FluidInference/parakeet-tdt-0.6b-v3-coreml", variant: "v3", downloadBytes: 483_103_089, backend: .parakeet, originalRepository: "nvidia/parakeet-tdt-0.6b-v3", license: "CC-BY-4.0"),
        whisper("whisper-large-v3-turbo-626mb", "Whisper Large v3 Turbo", "openai_whisper-large-v3-v20240930_626MB", 629_482_970, "openai/whisper-large-v3-turbo"),
        // Keep original IDs and variants resolvable for saved rules and downloads.
        whisper("whisper-base", "Whisper Base", "openai_whisper-base", 149_484_585, "openai/whisper-base"),
        whisper("whisper-small", "Whisper Small", "openai_whisper-small", 489_252_581, "openai/whisper-small"),
        whisper("whisper-medium", "Whisper Medium", "openai_whisper-medium", 1_532_419_373, "openai/whisper-medium"),
        whisper("whisper-large-v3", "Whisper Large v3", "openai_whisper-large-v3", 3_093_084_631, "openai/whisper-large-v3"),
        whisper("whisper-large-v3-turbo", "Whisper Large v3 Turbo · earlier build", "openai_whisper-large-v3-v20240930_turbo_632MB", 648_433_645, "openai/whisper-large-v3-turbo"),
        .init(id: "parakeet-v2", name: "NVIDIA Parakeet TDT v2 · English", kind: .audio, repository: "FluidInference/parakeet-tdt-0.6b-v2-coreml", variant: "v2", downloadBytes: 464_413_247, backend: .parakeet, originalRepository: "nvidia/parakeet-tdt-0.6b-v2", license: "CC-BY-4.0"),
        .init(id: "qwen-0.6b", name: "Qwen3 0.6B · 4-bit", kind: .text, repository: "mlx-community/Qwen3-0.6B-4bit", downloadBytes: 351_383_618, originalRepository: "Qwen/Qwen3-0.6B", license: "Apache-2.0"),
        .init(id: "qwen-1.7b", name: "Qwen3 1.7B · 4-bit", kind: .text, repository: "mlx-community/Qwen3-1.7B-4bit", downloadBytes: 984_013_244, originalRepository: "Qwen/Qwen3-1.7B", license: "Apache-2.0"),
        .init(id: "qwen-4b", name: "Qwen3 4B · 4-bit", kind: .text, repository: "mlx-community/Qwen3-4B-4bit", downloadBytes: 2_278_969_756, originalRepository: "Qwen/Qwen3-4B", license: "Apache-2.0"),
        .init(id: "llama-1b", name: "Llama 3.2 1B Instruct · 4-bit", kind: .text, repository: "mlx-community/Llama-3.2-1B-Instruct-4bit", downloadBytes: 712_575_975, originalRepository: "meta-llama/Llama-3.2-1B-Instruct", license: "Llama 3.2 Community License"),
        .init(id: "llama-3b", name: "Llama 3.2 3B Instruct · 4-bit", kind: .text, repository: "mlx-community/Llama-3.2-3B-Instruct-4bit", downloadBytes: 1_824_807_894, originalRepository: "meta-llama/Llama-3.2-3B-Instruct", license: "Llama 3.2 Community License"),
        .init(id: "gemma-1b", name: "Gemma 3 1B · 4-bit", kind: .text, repository: "mlx-community/gemma-3-1b-it-4bit", downloadBytes: 771_860_852, originalRepository: "google/gemma-3-1b-it", license: "Gemma Terms")
    ]
    /// The files of an MLX repository that Frog downloads, as globs on their paths.
    public static let mlxDownloadPatterns = ["*.json", "*.safetensors", "*.jinja", "*.txt", "*.model"]
    private static func whisper(_ id: String, _ name: String, _ variant: String, _ bytes: Int64, _ original: String) -> Self {
        .init(id: id, name: name, kind: .audio, repository: "argmaxinc/whisperkit-coreml", variant: variant, downloadBytes: bytes, originalRepository: original, license: "MIT")
    }
    public static func find(_ id: String) -> Self? { catalog.first { $0.id == id } }
    public static let defaultAudioModelID = "whisper-large-v3-turbo-626mb"
    public static var defaultCatalog: [Self] {
        catalog.filter { $0.kind == .text || ["whisper-tiny", "whisper-small-216mb", "parakeet-v3", defaultAudioModelID].contains($0.id) }
    }
    /// Onboarding downloads one speech model and one optional text model.
    public static var recommendedPair: [Self] { defaultCatalog.filter { $0.id == defaultAudioModelID || $0.id == "qwen-1.7b" } }
    public var isRecommended: Bool { id == "parakeet-v3" || id == Self.defaultAudioModelID || id == "qwen-1.7b" }
    public var recommendationSummary: String? {
        switch id {
        case "parakeet-v3": "Fast dictation · 25 European languages"
        case Self.defaultAudioModelID: "Broad multilingual coverage · 99+ languages"
        default: nil
        }
    }
}

extension Configuration {
    public var modelCatalog: [LocalModelDescriptor] { LocalModelDescriptor.catalog + (localModels ?? []) }
    public func localModel(_ id: String) -> LocalModelDescriptor? { modelCatalog.first { $0.id == id } }
    /// Older built-ins remain manageable when installed, selected, or explicitly requested.
    public func modelInventory(installed: Set<String>, including: Set<String> = []) -> [LocalModelDescriptor] {
        let workflow = preferences.workflowSettings
        let selected = rules.compactMap { $0.action?.audioProviderID == nil ? $0.action?.audioModelID : nil }
        let visible = Set(LocalModelDescriptor.defaultCatalog.map(\.id))
            .union((localModels ?? []).map(\.id)).union(installed).union(including)
            .union(selected).union([workflow.audioModelID])
        return modelCatalog.filter { visible.contains($0.id) }
    }
}
