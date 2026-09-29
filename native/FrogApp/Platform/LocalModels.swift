import Foundation
import Combine
import FrogCore
import WhisperKit
#if arch(arm64)
import MLXLLM
import MLXLMCommon
import MLX
import Hub
#endif

/// Download ownership, installed paths and model residency stay behind one service.
@MainActor
final class LocalModels: ObservableObject {
    typealias Downloader = @Sendable (LocalModelDescriptor, URL, @escaping @Sendable (Double) -> Void) async throws -> URL
    static var supported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
    @Published private(set) var installed = Set<String>()
    @Published private(set) var catalog = LocalModelDescriptor.catalog
    var onInstall: ((LocalModelDescriptor) -> Void)?
    var onInventoryChanged: (() -> Void)?
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var loaded = Set<String>()
    @Published private(set) var busy = false
    @Published private(set) var root: URL
    let defaultDirectory: URL
    private let storagePreference: URL
    @Published private(set) var changingDirectory = false
    private var downloads: [String: Task<Void, Never>] = [:]
    private let runtime: any LocalInferenceEngine
    private let downloader: Downloader
    private var unloadTask: Task<Void, Never>?
    var idleSeconds = 120 {
        didSet { if idleSeconds != oldValue, !busy, !loaded.isEmpty { scheduleUnload() } }
    }
    func updateCatalog(_ models: [LocalModelDescriptor]) {
        guard catalog != models else { return }
        catalog = models
        installed = Set(catalog.filter { modelURL($0.id) != nil }.map(\.id))
    }
    func descriptor(_ id: String) -> LocalModelDescriptor? { catalog.first { $0.id == id } }

    init(directory: URL? = nil, runtime: any LocalInferenceEngine = LocalInference(), downloader: @escaping Downloader = LocalInference.download) {
        self.runtime = runtime; self.downloader = downloader
        let support = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Frog")
        defaultDirectory = support.appendingPathComponent("Models", isDirectory: true)
        storagePreference = support.appendingPathComponent("model-storage.json")
        if let data = try? Data(contentsOf: storagePreference), let path = try? JSONDecoder().decode(String.self, from: data), path.hasPrefix("/") {
            root = URL(fileURLWithPath: path, isDirectory: true)
        } else { root = defaultDirectory }
        for model in LocalModelDescriptor.catalog where modelURL(model.id) != nil { installed.insert(model.id) }
    }
    /// Storage location is device-local, intentionally excluded from configuration exports.
    func changeDirectory(to location: URL) async throws {
        guard !busy, downloads.isEmpty, !changingDirectory else { throw FrogError.message("Wait for model operations to finish before changing the download folder.") }
        guard location.isFileURL else { throw FrogError.message("Choose a local model folder.") }
        let location = URL(fileURLWithPath: location.standardizedFileURL.path, isDirectory: true)
        if location == root { return }
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: location.path) else { throw FrogError.message("The selected model folder is not writable.") }
        changingDirectory = true; busy = true
        defer { changingDirectory = false; busy = false }
        unloadTask?.cancel(); unloadTask = nil
        await runtime.unload(); loaded = []
        try FileManager.default.createDirectory(at: storagePreference.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(location.path).write(to: storagePreference, options: [.atomic])
        root = location
        installed = Set(catalog.filter { modelURL($0.id) != nil }.map(\.id))
        errors = [:]
        onInventoryChanged?()
    }
    private func directory(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    private func modelURL(_ id: String) -> URL? {
        let base = directory(id)
        guard let relative = try? String(contentsOf: base.appendingPathComponent("installed.txt"), encoding: .utf8),
              !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return nil }
        let url = base.appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func download(_ model: LocalModelDescriptor) {
        guard Self.supported, !changingDirectory, downloads[model.id] == nil, !installed.contains(model.id) else { return }
        let base = directory(model.id)
        guard !FileManager.default.fileExists(atPath: base.path) else {
            errors[model.id] = "A folder named \(model.id) already exists without a completed Frog installation. Choose another download folder or move that folder aside."
            return
        }
        errors[model.id] = nil; progress[model.id] = 0
        downloads[model.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.downloads[model.id] = nil; self.progress[model.id] = nil }
            do {
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                let url = try await self.downloader(model, base) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.downloads[model.id] != nil else { return }
                        self.progress[model.id] = fraction
                    }
                }
                try Task.checkCancellation()
                guard url.path.hasPrefix(base.path + "/") else { throw FrogError.message("Invalid model installation path.") }
                let relative = String(url.path.dropFirst(base.path.count + 1))
                try relative.write(to: base.appendingPathComponent("installed.txt"), atomically: true, encoding: .utf8)
                self.installed.insert(model.id)
                self.onInstall?(model)
            } catch {
                // No completed installation exists yet. Cancel/failure must not
                // leave gigabytes that the UI has no installed row to delete.
                try? FileManager.default.removeItem(at: base)
                if !Task.isCancelled { self.errors[model.id] = error.localizedDescription }
            }
        }
    }
    func cancelDownload(_ id: String) { downloads[id]?.cancel() }
    func waitForDownload(_ id: String) async { await downloads[id]?.value }
    func waitForIdleUnload() async { await unloadTask?.value }
    func waitUntilAvailable() async throws {
        guard busy else { try Task.checkCancellation(); return }
        for await _ in $busy.values {
            try Task.checkCancellation()
            if !busy { return }
        }
        try Task.checkCancellation()
    }
    func remove(_ id: String) async throws {
        guard !busy, downloads[id] == nil else { throw FrogError.message("Wait for the model operation to finish before deleting it.") }
        busy = true
        defer { busy = false }
        unloadTask?.cancel(); unloadTask = nil
        await runtime.unload(); loaded = []
        try FileManager.default.removeItem(at: directory(id))
        installed.remove(id); errors[id] = nil
        onInventoryChanged?()
    }
    func unload() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        unloadTask?.cancel(); unloadTask = nil
        await runtime.unload(); loaded = []
    }
    private func acquire(_ id: String) throws -> URL {
        guard Self.supported else { throw FrogError.message("Built-in local models require Apple silicon.") }
        guard !busy else { throw FrogError.message("A local model is already processing.") }
        guard descriptor(id) != nil, let url = modelURL(id) else { throw FrogError.message("Download \(descriptor(id)?.name ?? id) in Models first.") }
        busy = true; unloadTask?.cancel(); return url
    }
    private func release() {
        busy = false
        scheduleUnload()
    }
    private func scheduleUnload() {
        unloadTask?.cancel()
        guard !loaded.isEmpty else { unloadTask = nil; return }
        let delay = idleSeconds
        unloadTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            // Do not cancel this very task inside unload(): the native engine
            // must receive a live task while releasing its resources.
            self?.unloadTask = nil
            await self?.unload()
        }
    }
    func transcribe(_ samples: [Float], modelID: String, language: String? = nil) async throws -> String {
        let url = try acquire(modelID); defer { release() }
        do {
            guard let model = descriptor(modelID) else { throw FrogError.message("The speech model is no longer configured.") }
            let selectedLanguage = model.englishOnly ? "en" : model.supportsLanguageSelection && language != "auto" ? language : nil
            let result = try await runtime.transcribe(samples, model: model, url: url, language: selectedLanguage, residency: { [weak self] ids in await self?.updateResidency(ids) })
            loaded = await runtime.loadedIDs
            return result
        } catch { loaded = await runtime.loadedIDs; throw error }
    }
    func complete(_ text: String, instructions: String, modelID: String) async throws -> String {
        let url = try acquire(modelID); defer { release() }
        do {
            let result = try await runtime.complete(text, instructions: instructions, id: modelID, url: url, residency: { [weak self] ids in await self?.updateResidency(ids) })
            loaded = await runtime.loadedIDs
            return result
        } catch { loaded = await runtime.loadedIDs; throw error }
    }
    private func updateResidency(_ ids: Set<String>) { loaded = ids }
    func shutdown() {
        downloads.values.forEach { $0.cancel() }
        unloadTask?.cancel()
        if !busy { Task { await self.unload() } }
    }
}

protocol LocalInferenceEngine: Actor {
    var loadedIDs: Set<String> { get }
    func transcribe(_ samples: [Float], model: LocalModelDescriptor, url: URL, language: String?, residency: @Sendable (Set<String>) async -> Void) async throws -> String
    func complete(_ text: String, instructions: String, id: String, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws -> String
    func unload() async
}

actor LocalInference: LocalInferenceEngine {
    // Avoid lengthy Neural Engine encoder specialization on a cold model store.
    // Installation and inference use the same compute policy so their compiled caches match.
    private static let whisperCompute = ModelComputeOptions(audioEncoderCompute: .cpuAndGPU)
    private var speech: WhisperKit?
    private var speechID: String?
    #if arch(arm64)
    private var textModel: ModelContainer?
    private var parakeet: ParakeetRuntime?
    #endif
    private var textID: String?
    var loadedIDs: Set<String> { Set([speechID, textID].compactMap { $0 }) }

    static func download(_ model: LocalModelDescriptor, base: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        #if arch(arm64)
        if model.backend == .parakeet { return try await ParakeetRuntime.download(model, base: base, progress: progress) }
        if model.backend == .whisperKit {
            let url = try await WhisperKit.download(variant: model.variant!, downloadBase: base, from: model.repository) { progress($0.fractionCompleted * 0.9) }
            try Task.checkCancellation()
            // Download/tokenize during explicit installation, not the first recording.
            let kit = try await WhisperKit(WhisperKitConfig(modelFolder: url.path, tokenizerFolder: base, computeOptions: whisperCompute, verbose: false, logLevel: .none, prewarm: false, load: true, download: false))
            await kit.unloadModels()
            progress(1)
            return url
        }
        return try await HubApi(downloadBase: base).snapshot(from: model.repository, matching: ["*.json", "*.safetensors", "*.jinja", "*.txt", "*.model"]) { progress($0.fractionCompleted) }
        #else
        throw FrogError.message("Built-in local models require Apple silicon.")
        #endif
    }
    func transcribe(_ samples: [Float], model: LocalModelDescriptor, url: URL, language: String?, residency: @Sendable (Set<String>) async -> Void) async throws -> String {
        let id = model.id
        try Task.checkCancellation()
        #if arch(arm64)
        if model.backend == .parakeet {
            if speechID != id {
                await speech?.unloadModels(); speech = nil
                await parakeet?.unload(); parakeet = nil; speechID = nil
                await residency(loadedIDs); try Task.checkCancellation()
                let engine = ParakeetRuntime()
                try await engine.load(from: url, version: model.variant == "v2" ? .v2 : .v3)
                parakeet = engine; speechID = id
                await residency(loadedIDs)
            }
            try Task.checkCancellation()
            let result = try await parakeet!.transcribe(samples)
            try Task.checkCancellation()
            return result
        }
        #endif
        if speechID != id {
            await speech?.unloadModels(); speech = nil; speechID = nil
            #if arch(arm64)
            await parakeet?.unload(); parakeet = nil
            #endif
            await residency(loadedIDs)
            try Task.checkCancellation()
            // WhisperKit's cache base contains its model and tokenizer snapshots.
            var base = url
            while base.lastPathComponent != id && base.path != "/" { base.deleteLastPathComponent() }
            speech = try await WhisperKit(WhisperKitConfig(modelFolder: url.path, tokenizerFolder: base, computeOptions: Self.whisperCompute, verbose: false, logLevel: .none, prewarm: false, load: true, download: false))
            speechID = id
            await residency(loadedIDs)
        }
        try Task.checkCancellation()
        let results = try await speech!.transcribe(audioArray: samples, decodeOptions: DecodingOptions(verbose: false, language: language, detectLanguage: language == nil, skipSpecialTokens: true, withoutTimestamps: true))
        try Task.checkCancellation()
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func complete(_ text: String, instructions: String, id: String, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws -> String {
        #if arch(arm64)
        try Task.checkCancellation()
        if textID != id {
            textModel = nil; textID = nil
            await residency(loadedIDs)
            try Task.checkCancellation()
            textModel = try await LLMModelFactory.shared.loadContainer(configuration: ModelConfiguration(directory: url))
            textID = id
            await residency(loadedIDs)
        }
        try Task.checkCancellation()
        let input = try await textModel!.prepare(input: UserInput(prompt: .chat([
            .system(instructions),
            .user(text)
        ]), additionalContext: ["enable_thinking": false]))
        try Task.checkCancellation()
        let stream = try await textModel!.generate(input: input, parameters: GenerateParameters(maxTokens: 2048, temperature: 0.1))
        var output = ""
        for await generation in stream {
            try Task.checkCancellation()
            if case .chunk(let text) = generation { output += text }
        }
        if let end = output.range(of: "</think>") { output = String(output[end.upperBound...]) }
        let result = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw FrogError.message("The local model returned no text.") }
        return result
        #else
        throw FrogError.message("Built-in local models require Apple silicon.")
        #endif
    }
    func unload() async {
        await speech?.unloadModels(); speech = nil; speechID = nil
        #if arch(arm64)
        await parakeet?.unload(); parakeet = nil
        textModel = nil
        MLX.Memory.clearCache()
        #endif
        textID = nil
    }
}
