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
    /// The Core ML components of a Parakeet conversion, each a `.mlmodelc` folder.
    /// Ultra ships only the joint with top-K outputs; v2 and v3 keep the joint they
    /// were first downloaded with.
    public var parakeetComponents: [String] {
        ["Preprocessor", "Encoder", "Decoder", variant == "ultra" ? "JointDecisionv3" : "JointDecision"]
    }
    public var streaming: String { kind == .audio ? "Live preview" : "Token streaming" }
    // `downloadBytes` sums the files that Frog's download fetches, as the Hugging Face
    // API (`api/models/<repository>?blobs=true`) listed them: the WhisperKit variant
    // folder plus the tokenizer files of the upstream OpenAI model, the four Parakeet
    // Core ML components and their vocabulary, and the MLX files that match
    // `mlxDownloadPatterns`. Checked on 2026-10-14; Parakeet Ultra and Qwen3.5 on 2026-10-30.
    //
    // The list is short on purpose: one recommended model of each kind, and one
    // alternative where it covers what the recommended one does not. Every other
    // model can be added from Hugging Face. Entries are never removed, only
    // hidden (`defaultCatalog`), so that saved rules and downloads keep resolving.
    public static let catalog: [Self] = [
        // Shown: speech.
        .init(id: "parakeet-ultra", name: "Parakeet Ultra", kind: .audio, repository: "FluidInference/parakeet-ultra-coreml", variant: "ultra", downloadBytes: 632_162_964, backend: .parakeet, originalRepository: "moondream/parakeet-ultra", license: "CC-BY-4.0"),
        whisper("whisper-large-v3-turbo-626mb", "Whisper Large v3 Turbo", "openai_whisper-large-v3-v20240930_626MB", 629_482_970, "openai/whisper-large-v3-turbo"),
        // Shown: text.
        .init(id: "qwen3.5-2b", name: "Qwen3.5 2B · 4-bit", kind: .text, repository: "mlx-community/Qwen3.5-2B-4bit", downloadBytes: 1_749_079_691, originalRepository: "Qwen/Qwen3.5-2B", license: "Apache-2.0"),
        .init(id: "qwen3.5-0.8b", name: "Qwen3.5 0.8B · 4-bit", kind: .text, repository: "mlx-community/Qwen3.5-0.8B-4bit", downloadBytes: 652_027_143, originalRepository: "Qwen/Qwen3.5-0.8B", license: "Apache-2.0"),
        // Hidden: kept resolvable for saved rules and downloads. Parakeet Ultra supersedes
        // Parakeet v3, Qwen3.5 the Qwen3 models.
        .init(id: "parakeet-v3", name: "NVIDIA Parakeet TDT v3", kind: .audio, repository: "FluidInference/parakeet-tdt-0.6b-v3-coreml", variant: "v3", downloadBytes: 483_103_089, backend: .parakeet, originalRepository: "nvidia/parakeet-tdt-0.6b-v3", license: "CC-BY-4.0"),
        whisper("whisper-tiny", "Whisper Tiny", "openai_whisper-tiny", 79_400_529, "openai/whisper-tiny"),
        whisper("whisper-small-216mb", "Whisper Small · Compact", "openai_whisper-small_216MB", 220_115_879, "openai/whisper-small"),
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
    /// The speech model that configurations from before per-rule model choices fall
    /// back to. Changing it would change how those configurations migrate; the model
    /// Frog recommends is `recommendedSpeechModelID`.
    public static let defaultAudioModelID = "whisper-large-v3-turbo-626mb"
    /// The text model that configurations from before per-rule model choices fall back to.
    /// Changing it would change how those configurations migrate.
    public static let legacyTextModelID = "qwen-0.6b"
    /// The models a fresh Models list shows. Others appear once downloaded, chosen in a
    /// rule or added from Hugging Face.
    public static let shownModelIDs: Set<String> = ["parakeet-ultra", "whisper-large-v3-turbo-626mb", "qwen3.5-2b", "qwen3.5-0.8b"]
    public static var defaultCatalog: [Self] { catalog.filter { shownModelIDs.contains($0.id) } }
    /// The one speech model Frog recommends: fast, accurate dictation in 25 European
    /// languages through FluidAudio on the Neural Engine or GPU.
    public static let recommendedSpeechModelID = "parakeet-ultra"
    /// The one text model Frog recommends: small and fast enough for corrections and
    /// short rewrites, and it does not think before it answers.
    public static let recommendedTextModelID = "qwen3.5-2b"
    /// The recommended model of a kind, for a one-click download.
    public static func recommended(_ kind: Kind) -> Self {
        find(kind == .audio ? recommendedSpeechModelID : recommendedTextModelID)!
    }
    /// Onboarding downloads one speech model and one optional text model, speech first.
    public static var recommendedPair: [Self] { [recommended(.audio), recommended(.text)] }
    public var isRecommended: Bool { id == Self.recommendedSpeechModelID || id == Self.recommendedTextModelID }
    /// One line about what a shown model is for; nil for the others.
    public var recommendationSummary: String? {
        switch id {
        case Self.recommendedSpeechModelID: "Fast, accurate dictation · 25 European languages"
        case "whisper-large-v3-turbo-626mb": "Broad multilingual coverage · 99+ languages"
        case Self.recommendedTextModelID: "Fast corrections and short rewrites · 201 languages"
        case "qwen3.5-0.8b": "Smallest and fastest · spelling and punctuation"
        default: nil
        }
    }
}

extension Configuration {
    public var modelCatalog: [LocalModelDescriptor] { LocalModelDescriptor.catalog + (localModels ?? []) }
    public func localModel(_ id: String) -> LocalModelDescriptor? { modelCatalog.first { $0.id == id } }
    /// Saves a source found by checking a Hugging Face link. A saved source that was
    /// added before Frog read download sizes takes the size that the new check found,
    /// so that its download is checked against the free space too. False when
    /// nothing changes.
    @discardableResult
    public mutating func addLocalModel(_ item: LocalModelDescriptor) throws -> Bool {
        if let index = localModels?.firstIndex(where: { $0.id == item.id }), let saved = localModels?[index] {
            guard saved.downloadBytes == nil, let bytes = item.downloadBytes else { return false }
            let sized = LocalModelDescriptor(id: saved.id, name: saved.name, kind: saved.kind, repository: saved.repository, variant: saved.variant, size: saved.size, downloadBytes: bytes, backend: saved.backend, originalRepository: saved.originalRepository, license: saved.license)
            try sized.validateCustom()
            localModels?[index] = sized
            return true
        }
        guard localModel(item.id) == nil else { return false }
        try item.validateCustom()
        localModels = (localModels ?? []) + [item]
        return true
    }
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

/// Where a model download stands: the fraction its bar shows, and the line under
/// the bar about bytes, speed and the time left.
public struct DownloadProgress: Equatable, Sendable {
    /// From 0 to 1, by bytes when their total is known. 1 says that the files are in
    /// and the model is being made ready, which has no fraction.
    public var fraction: Double
    public var bytesReceived: Int64?
    public var bytesExpected: Int64?
    /// Averaged over the last few seconds; nil until that average is steady.
    public var bytesPerSecond: Double?
    public init(fraction: Double, bytesReceived: Int64? = nil, bytesExpected: Int64? = nil, bytesPerSecond: Double? = nil) {
        self.fraction = fraction; self.bytesReceived = bytesReceived; self.bytesExpected = bytesExpected; self.bytesPerSecond = bytesPerSecond
    }
    public static let filesAreIn = DownloadProgress(fraction: 1)
    public var hasAllFiles: Bool { fraction >= 1 }

    /// "412 MB of 1 GB · 8.1 MB/s · about 1 min left". What is not known is left
    /// out; a download that reports only a fraction has no line.
    public var summary: String? {
        var parts: [String] = []
        if let received = bytesReceived {
            parts.append(bytesExpected.map { "\(Self.bytes(received)) of \(Self.bytes($0))" } ?? Self.bytes(received))
        }
        if let rate = bytesPerSecond {
            // A speed of zero promises no time left: nothing has arrived for a while.
            if rate < 1 { parts.append("stalled") } else {
                parts.append("\(Self.bytes(Int64(rate)))/s")
                if let received = bytesReceived, let expected = bytesExpected, expected > received {
                    parts.append(Self.timeLeft(Double(expected - received) / rate))
                }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    static func timeLeft(_ seconds: Double) -> String {
        if seconds < 60 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        return minutes < 90 ? "about \(minutes) min left" : "about \(Int((seconds / 3600).rounded())) h left"
    }
    /// Like `LocalModelDescriptor.byteCount`, with "0 bytes" for a download that has none yet.
    private static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file, spellsOutZero: false).locale(Locale(identifier: "en")))
    }
}
