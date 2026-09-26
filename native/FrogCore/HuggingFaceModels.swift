import Foundation
import CryptoKit

/// A repository or a WhisperKit variant folder on Hugging Face's main branch.
public struct HuggingFaceSource: Equatable, Sendable {
    public let repository: String
    public let variant: String?

    public init(_ input: String) throws {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts: [String]
        if input.contains("://") {
            guard let url = URLComponents(string: input), url.scheme == "https", url.host == "huggingface.co",
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else {
                throw FrogError.message("Use an HTTPS huggingface.co model link, without query parameters or credentials.")
            }
            parts = url.path.split(separator: "/").map(String.init)
        } else { parts = input.split(separator: "/", omittingEmptySubsequences: false).map(String.init) }
        guard parts.count == 2 || (parts.count == 5 && parts[2] == "tree" && parts[3] == "main"),
              Self.validComponent(parts[0]), Self.validComponent(parts[1]),
              parts.count == 2 || Self.validComponent(parts[4]) else {
            throw FrogError.message("Enter owner/model or a model repository URL. For WhisperKit, a tree/main/variant folder link is supported; individual files and other revisions are not.")
        }
        repository = parts[0] + "/" + parts[1]
        variant = parts.count == 5 ? parts[4] : nil
    }
    public static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value != "." && value != ".." &&
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }
    public static func modelID(repository: String, variant: String?, backend: LocalModelDescriptor.Backend) -> String {
        let data = Data("\(backend.rawValue):\(repository):\(variant ?? "")".utf8)
        return "hf-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Inspects small metadata/config files only. Adding a source never downloads weights.
public struct HuggingFaceModels: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func inspect(_ input: String) async throws -> [LocalModelDescriptor] {
        let source = try HuggingFaceSource(input)
        let metadata = try await fetch(URL(string: "https://huggingface.co/api/models/\(source.repository)")!)
        let object = try JSONSerialization.jsonObject(with: metadata) as? [String: Any] ?? [:]
        let files = Set((object["siblings"] as? [[String: Any]] ?? []).compactMap { $0["rfilename"] as? String })
        let textConfig: Data?
        if files.contains("config.json"), files.contains(where: { $0.hasSuffix(".safetensors") }), source.variant == nil {
            textConfig = try await fetch(URL(string: "https://huggingface.co/\(source.repository)/resolve/main/config.json")!)
        } else { textConfig = nil }
        return try Self.descriptors(source: source, metadata: metadata, textConfig: textConfig)
    }

    public static func descriptors(source: HuggingFaceSource, metadata: Data, textConfig: Data?) throws -> [LocalModelDescriptor] {
        let object = try JSONSerialization.jsonObject(with: metadata) as? [String: Any] ?? [:]
        guard object["private"] as? Bool != true,
              object["gated"] == nil || object["gated"] as? Bool == false else {
            throw FrogError.message("This model requires Hugging Face access approval or authentication. Add a public, ungated conversion instead.")
        }
        let files = Set((object["siblings"] as? [[String: Any]] ?? []).compactMap { $0["rfilename"] as? String })
        let card = object["cardData"] as? [String: Any] ?? [:]
        let license = card["license"] as? String
        // Known Parakeet sources use the bundled, version-specific native adapter.
        if let known = LocalModelDescriptor.catalog.first(where: { $0.backend == .parakeet && $0.repository == source.repository }), source.variant == nil {
            guard files.contains("parakeet_vocab.json"), ["Preprocessor", "Encoder", "Decoder", "JointDecision"].allSatisfy({ files.contains("\($0).mlmodelc/coremldata.bin") }) else {
                throw FrogError.message("The Parakeet source is missing required Core ML components or vocabulary.")
            }
            return [known]
        }
        let folders = Set(files.compactMap { path -> String? in
            let parts = path.split(separator: "/")
            return parts.count > 2 && parts[1] == "AudioEncoder.mlmodelc" ? String(parts[0]) : nil
        })
        let variants = folders.filter { folder in
            HuggingFaceSource.validComponent(folder) && (source.variant == nil || source.variant == folder) &&
            ["AudioEncoder", "TextDecoder", "MelSpectrogram"].allSatisfy { files.contains("\(folder)/\($0).mlmodelc/coremldata.bin") }
        }.sorted()
        if !variants.isEmpty {
            return variants.map { variant in
                LocalModelDescriptor.findMatching(repository: source.repository, variant: variant, backend: .whisperKit) ??
                .init(id: HuggingFaceSource.modelID(repository: source.repository, variant: variant, backend: .whisperKit), name: variant, kind: .audio, repository: source.repository, variant: variant, size: "See source for size", license: license)
            }
        }
        if let data = textConfig, source.variant == nil,
           let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           config["model_type"] as? String != nil,
           (config["quantization"] != nil || object["library_name"] as? String == "mlx" || (object["tags"] as? [String] ?? []).contains("mlx")),
           files.contains("tokenizer.json"), files.contains("tokenizer_config.json"), files.contains(where: { $0.hasSuffix(".safetensors") }) {
            return [LocalModelDescriptor.findMatching(repository: source.repository, variant: nil, backend: .mlx) ??
                .init(id: HuggingFaceSource.modelID(repository: source.repository, variant: nil, backend: .mlx), name: source.repository.components(separatedBy: "/").last!, kind: .text, repository: source.repository, size: "See source for size", license: license)]
        }
        throw FrogError.message("No supported model files found. Use an MLX text conversion, a WhisperKit Core ML variant folder, or one of the supported Parakeet sources. Raw PyTorch, GGUF and arbitrary NeMo weights cannot run in Frog.")
    }
    private func fetch(_ url: URL) async throws -> Data {
        let request = URLRequest(url: url, timeoutInterval: 30)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw FrogError.message("Could not read the Hugging Face model. Check the link and that the repository is public and ungated.")
        }
        guard data.count <= 4 * 1024 * 1024 else { throw FrogError.message("The model metadata is too large.") }
        return data
    }
}

extension LocalModelDescriptor {
    public static func findMatching(repository: String, variant: String?, backend: Backend) -> Self? {
        catalog.first { $0.repository == repository && $0.variant == variant && $0.backend == backend }
    }
    public func validateCustom() throws {
        let source = try HuggingFaceSource(repository)
        guard source.variant == nil, source.repository == repository,
              id == HuggingFaceSource.modelID(repository: repository, variant: variant, backend: backend),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 256,
              size.count <= 100, (license?.count ?? 0) <= 256,
              (backend == .mlx && kind == .text && variant == nil) ||
                (backend == .whisperKit && kind == .audio && variant.map(HuggingFaceSource.validComponent) == true) else {
            throw FrogError.message("Invalid custom model source, ID, or runtime. Add the Hugging Face link again.")
        }
        if let originalRepository {
            let original = try HuggingFaceSource(originalRepository)
            guard original.repository == originalRepository, original.variant == nil else { throw FrogError.message("Use owner/model for the original model source.") }
        }
    }
}
