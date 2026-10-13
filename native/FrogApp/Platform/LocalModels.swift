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
    /// The fraction counts the files being fetched. A downloader that reports 1 and
    /// keeps working is preparing the model, which has no fraction (`preparing`).
    typealias Downloader = @Sendable (LocalModelDescriptor, URL, @escaping @Sendable (Double) -> Void) async throws -> URL
    static var supported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
    @Published private(set) var installed = Set<String>()
    /// Models whose download stopped part-way and left its files in place.
    @Published private(set) var unfinished = Set<String>()
    @Published private(set) var catalog = LocalModelDescriptor.catalog
    var onInstall: ((LocalModelDescriptor) -> Void)?
    var onInventoryChanged: (() -> Void)?
    @Published private(set) var progress: [String: Double] = [:]
    /// Downloads whose files are in and whose model is being made ready for use.
    @Published private(set) var preparing = Set<String>()
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var loaded = Set<String>()
    @Published private(set) var busy = false
    @Published private(set) var root: URL
    let defaultDirectory: URL
    private let storagePreference: URL
    @Published private(set) var changingDirectory = false
    private var downloads: [String: Task<Void, Never>] = [:]
    /// Downloads the person cancelled: only those lose their files.
    private var discarding = Set<String>()
    private let runtime: any LocalInferenceEngine
    private let downloader: Downloader
    private var unloadTask: Task<Void, Never>?
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var residencyHolds = Set<UUID>()
    var idleSeconds = 120 {
        didSet { if idleSeconds != oldValue, !busy, !loaded.isEmpty { scheduleUnload() } }
    }
    func updateCatalog(_ models: [LocalModelDescriptor]) {
        guard catalog != models else { return }
        catalog = models
        installed = Set(catalog.filter { modelURL($0.id) != nil }.map(\.id))
        unfinished = unfinishedDownloads()
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
        unfinished = unfinishedDownloads()
    }
    /// Storage location is device-local, intentionally excluded from configuration exports.
    func changeDirectory(to location: URL) async throws {
        guard !busy, residencyHolds.isEmpty, downloads.isEmpty, !changingDirectory else { throw FrogError.message("Wait for model operations to finish before changing the download folder.") }
        guard location.isFileURL else { throw FrogError.message("Choose a local model folder.") }
        let location = URL(fileURLWithPath: location.standardizedFileURL.path, isDirectory: true)
        if location == root { return }
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: location.path) else { throw FrogError.message("The selected model folder is not writable.") }
        changingDirectory = true; busy = true
        defer { changingDirectory = false; busy = false }
        unloadTask?.cancel(); unloadTask = nil
        loaded = []; await runtime.unload(keepingMetadata: false)
        try FileManager.default.createDirectory(at: storagePreference.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(location.path).write(to: storagePreference, options: [.atomic])
        root = location
        installed = Set(catalog.filter { modelURL($0.id) != nil }.map(\.id))
        unfinished = unfinishedDownloads()
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
    /// Lies in a model folder from the start of its download until `installed.txt`
    /// exists. A failure, a quit or a crash in between leaves both the folder and
    /// this file, which tells Frog's own unfinished download from a folder it must
    /// not touch.
    private static let downloadMarker = ".frog-download"
    private func downloadMarker(_ id: String) -> URL { directory(id).appendingPathComponent(Self.downloadMarker) }
    private func unfinishedDownloads() -> Set<String> {
        Set(catalog.filter { !installed.contains($0.id) && FileManager.default.fileExists(atPath: downloadMarker($0.id).path) }.map(\.id))
    }
    /// Model folders can be gigabytes: remove them off the main thread.
    nonisolated private static func discard(_ folder: URL) async throws {
        do { try FileManager.default.removeItem(at: folder) }
        catch CocoaError.fileNoSuchFile { /* Already gone. */ }
    }
    func download(_ model: LocalModelDescriptor) {
        guard Self.supported, !changingDirectory, downloads[model.id] == nil, !installed.contains(model.id) else { return }
        let base = directory(model.id)
        let marker = downloadMarker(model.id)
        // An unfinished download of Frog's own continues in its folder.
        let resuming = FileManager.default.fileExists(atPath: marker.path)
        guard resuming || !FileManager.default.fileExists(atPath: base.path) else {
            errors[model.id] = "A folder named \(model.id) already exists without a completed Frog installation. Choose another download folder or move that folder aside."
            return
        }
        errors[model.id] = nil; progress[model.id] = 0
        downloads[model.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.downloads[model.id] = nil; self.progress[model.id] = nil; self.preparing.remove(model.id); self.discarding.remove(model.id) }
            var marked = resuming
            do {
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                if !marked { try Data().write(to: marker); marked = true }
                self.unfinished.insert(model.id)
                let url = try await self.downloader(model, base) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.downloads[model.id] != nil else { return }
                        self.progress[model.id] = fraction
                        if fraction >= 1 { self.preparing.insert(model.id) }
                    }
                }
                try Task.checkCancellation()
                guard url.path.hasPrefix(base.path + "/") else { throw FrogError.message("Invalid model installation path.") }
                let relative = String(url.path.dropFirst(base.path.count + 1))
                try relative.write(to: base.appendingPathComponent("installed.txt"), atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: marker)
                self.unfinished.remove(model.id)
                self.installed.insert(model.id)
                self.onInstall?(model)
            } catch {
                // A failure or a quit keeps what was fetched, so the next attempt
                // continues from it; the row offers to discard it. Cancel removes it,
                // and so does a start that never got to mark the folder as Frog's.
                if self.discarding.contains(model.id) || !marked {
                    try? await Self.discard(base)
                    self.unfinished = self.unfinishedDownloads()
                }
                if !Task.isCancelled { self.errors[model.id] = error.localizedDescription }
            }
        }
    }
    /// Cancelling is the person's decision against this download: its files go too.
    func cancelDownload(_ id: String) {
        guard let task = downloads[id], progress[id] != nil else { return }
        discarding.insert(id); task.cancel()
    }
    /// Removes what an unfinished download left behind, and only that: a folder
    /// with Frog's marker and without an installation.
    func discardDownload(_ id: String) {
        let base = directory(id)
        guard !changingDirectory, downloads[id] == nil, modelURL(id) == nil, FileManager.default.fileExists(atPath: downloadMarker(id).path) else { return }
        downloads[id] = Task { [weak self] in
            var failure: String?
            do { try await Self.discard(base) } catch { failure = error.localizedDescription }
            guard let self else { return }
            self.downloads[id] = nil
            self.unfinished = self.unfinishedDownloads()
            self.errors[id] = failure
        }
    }
    func waitForDownload(_ id: String) async { await downloads[id]?.value }
    func waitForIdleUnload() async { await unloadTask?.value }
    func holdResidency() -> UUID {
        let id = UUID(); residencyHolds.insert(id)
        unloadTask?.cancel(); unloadTask = nil
        return id
    }
    func releaseResidency(_ id: UUID) {
        residencyHolds.remove(id)
        if !busy { scheduleUnload() }
    }
    func prepare(_ id: String) async throws {
        try Task.checkCancellation()
        // Readiness is use too: an already-loaded model should get the same idle
        // interval as one that needed loading. Active work/holds own their timer.
        if loaded.contains(id) {
            if !busy { scheduleUnload() }
            return
        }
        try await waitUntilAvailable()
        try Task.checkCancellation()
        if loaded.contains(id) {
            if !busy { scheduleUnload() }
            return
        }
        try await exclusively(id, waiting: true) { url in
            guard let model = descriptor(id) else { throw FrogError.message("The model is no longer configured.") }
            try await runtime.prepare(model: model, url: url, residency: { [weak self] ids in await self?.updateResidency(ids) })
        }
        try Task.checkCancellation()
    }
    private func waitUntilAvailable() async throws {
        guard busy else { try Task.checkCancellation(); return }
        for await _ in $busy.values {
            try Task.checkCancellation()
            if !busy { return }
        }
        try Task.checkCancellation()
    }
    /// The one place that takes the inference lock for work on a model. A caller
    /// that waits takes it in the same turn of the main actor in which it became
    /// free, so "already processing" reaches only a caller that chose not to wait.
    private func exclusively<T>(_ id: String, waiting: Bool, _ work: (URL) async throws -> T) async throws -> T {
        if waiting { try await waitUntilAvailable() }
        let url = try acquire(id); defer { release() }
        do {
            let result = try await work(url)
            loaded = await runtime.loadedIDs
            return result
        } catch { loaded = await runtime.loadedIDs; throw error }
    }
    func remove(_ id: String) async throws {
        guard !busy, residencyHolds.isEmpty, downloads[id] == nil else { throw FrogError.message("Wait for the model operation to finish before deleting it.") }
        busy = true
        defer { busy = false }
        unloadTask?.cancel(); unloadTask = nil
        loaded = []; await runtime.unload(keepingMetadata: false)
        do { try FileManager.default.removeItem(at: directory(id)) }
        catch CocoaError.fileNoSuchFile { /* Already removed outside Frog. Repair the inventory below. */ }
        installed.remove(id); unfinished.remove(id); errors[id] = nil
        onInventoryChanged?()
    }
    func unload(keepingMetadata: Bool = false) async {
        guard !busy, residencyHolds.isEmpty else { return }
        busy = true
        defer { busy = false }
        unloadTask?.cancel(); unloadTask = nil
        loaded = []; await runtime.unload(keepingMetadata: keepingMetadata)
    }
    /// The app turns this on once; tests call `relieveMemoryPressure` themselves.
    func unloadUnderMemoryPressure() {
        guard memoryPressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in Task { @MainActor [weak self] in await self?.relieveMemoryPressure() } }
        source.activate()
        memoryPressure = source
    }
    /// macOS reports that memory is short: an idle model goes now instead of at the
    /// end of its idle interval. Running work and held sessions keep theirs,
    /// because `unload` refuses then.
    func relieveMemoryPressure() async {
        guard !loaded.isEmpty else { return }
        await unload(keepingMetadata: true)
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
        guard !loaded.isEmpty, residencyHolds.isEmpty else { unloadTask = nil; return }
        let delay = idleSeconds
        unloadTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            // Do not cancel this very task inside unload(): the native engine
            // must receive a live task while releasing its resources.
            self?.unloadTask = nil
            await self?.unload(keepingMetadata: true)
        }
    }
    /// The transcript of a finished recording waits for running work. A live
    /// preview does not: it fails on a busy engine and its loop tries again.
    func transcribe(_ samples: [Float], modelID: String, language: String? = nil, waiting: Bool = false) async throws -> String {
        try await exclusively(modelID, waiting: waiting) { url in
            guard let model = descriptor(modelID) else { throw FrogError.message("The speech model is no longer configured.") }
            let selectedLanguage = model.englishOnly ? "en" : model.supportsLanguageSelection && language != "auto" ? language : nil
            return try await runtime.transcribe(samples, model: model, url: url, language: selectedLanguage, residency: { [weak self] ids in await self?.updateResidency(ids) })
        }
    }
    func complete(_ text: String, instructions: String, modelID: String) async throws -> String {
        // An interrupted recording may still be transcribing for History.
        try await exclusively(modelID, waiting: true) { url in
            try await runtime.complete(text, instructions: instructions, id: modelID, url: url, residency: { [weak self] ids in await self?.updateResidency(ids) })
        }
    }
    private func updateResidency(_ ids: Set<String>) { loaded = ids }
    func shutdown() {
        downloads.values.forEach { $0.cancel() }
        unloadTask?.cancel()
        memoryPressure?.cancel(); memoryPressure = nil
        if !busy { Task { await self.unload() } }
    }
}

protocol LocalInferenceEngine: Actor {
    var loadedIDs: Set<String> { get }
    func prepare(model: LocalModelDescriptor, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws
    func transcribe(_ samples: [Float], model: LocalModelDescriptor, url: URL, language: String?, residency: @Sendable (Set<String>) async -> Void) async throws -> String
    func complete(_ text: String, instructions: String, id: String, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws -> String
    func unload(keepingMetadata: Bool) async
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
        do { return try await fetch(model, base: base, progress: progress) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Task.isCancelled ? error : FrogError.message(downloadFailure(error, model: model)) }
    }
    /// The libraries word their failures for developers ("Offline mode error:
    /// Repository not available locally", "Please provide a valid Hugging Face
    /// token"). The Models row says what happened to this download instead.
    static func downloadFailure(_ error: Error, model: LocalModelDescriptor) -> String {
        let offline = "No internet connection. Reconnect and try again; the files already downloaded are kept."
        var cause = error
        #if arch(arm64)
        let limited = "Hugging Face is limiting downloads at the moment. Try again in a few minutes; the files already downloaded are kept."
        switch error {
        case Hub.HubClientError.networkError(let inner): cause = inner
        case Hub.HubClientError.fileSystemError(let inner): cause = inner
        case HubApi.EnvironmentError.offlineModeError: return offline
        case Hub.HubClientError.authorizationRequired:
            return "Hugging Face asks for an account or an accepted license for \(model.repository). Frog downloads without signing in and cannot fetch this model."
        case Hub.HubClientError.fileNotFound, Hub.HubClientError.resourceNotFound:
            return "A file of \(model.name) is missing from \(model.repository) on Hugging Face. The repository may have been renamed or removed."
        case Hub.HubClientError.httpStatusCode(429): return limited
        case Hub.HubClientError.downloadError(let text) where text.hasPrefix("Rate limited"): return limited
        default: break
        }
        #endif
        if error is FrogError { return error.localizedDescription }
        let unreachable: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff]
        if let network = cause as? URLError, unreachable.contains(network.code) { return offline }
        let code = cause as NSError
        if (code.domain == NSCocoaErrorDomain && code.code == NSFileWriteOutOfSpaceError) || (code.domain == NSPOSIXErrorDomain && code.code == Int(ENOSPC)) {
            return "Not enough free disk space for \(model.name) (\(model.size)). Free up space and try again; the files already downloaded are kept."
        }
        return "Could not download \(model.name). \(error.localizedDescription)"
    }
    private static func fetch(_ model: LocalModelDescriptor, base: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        #if arch(arm64)
        if model.backend == .parakeet { return try await ParakeetRuntime.download(model, base: base, progress: progress) }
        if model.backend == .whisperKit {
            let url = try await WhisperKit.download(variant: model.variant!, downloadBase: base, from: model.repository) { progress($0.fractionCompleted) }
            try Task.checkCancellation()
            // Download/tokenize during explicit installation, not the first recording.
            // Loading the model once takes a while and reports nothing: say so
            // instead of leaving a bar that stands still.
            progress(1)
            let kit = try await WhisperKit(WhisperKitConfig(modelFolder: url.path, tokenizerFolder: base, computeOptions: whisperCompute, verbose: false, logLevel: .none, prewarm: false, load: true, download: false))
            await kit.unloadModels()
            return url
        }
        return try await HubApi.modelFolder(base).snapshot(from: model.repository, matching: ["*.json", "*.safetensors", "*.jinja", "*.txt", "*.model"]) { progress($0.fractionCompleted) }
        #else
        throw FrogError.message("Built-in local models require Apple silicon.")
        #endif
    }
    func prepare(model: LocalModelDescriptor, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws {
        if model.kind == .text { try await prepareText(id: model.id, url: url, residency: residency); return }
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
            return
        }
        #endif
        if speechID != id {
            let cached = speech?.modelFolder == url ? speech : nil
            await speech?.unloadModels(); speech = nil; speechID = nil
            #if arch(arm64)
            await parakeet?.unload(); parakeet = nil
            #endif
            await residency(loadedIDs)
            try Task.checkCancellation()
            // WhisperKit's cache base contains its model and tokenizer snapshots.
            var base = url
            while base.lastPathComponent != id && base.path != "/" { base.deleteLastPathComponent() }
            if let cached {
                try await cached.loadModels()
                speech = cached
            } else {
                speech = try await WhisperKit(WhisperKitConfig(modelFolder: url.path, tokenizerFolder: base, computeOptions: Self.whisperCompute, verbose: false, logLevel: .none, prewarm: false, load: true, download: false))
            }
            speechID = id
            await residency(loadedIDs)
        }
    }
    func transcribe(_ samples: [Float], model: LocalModelDescriptor, url: URL, language: String?, residency: @Sendable (Set<String>) async -> Void) async throws -> String {
        try await prepare(model: model, url: url, residency: residency)
        try Task.checkCancellation()
        #if arch(arm64)
        if model.backend == .parakeet {
            let result = try await parakeet!.transcribe(samples)
            try Task.checkCancellation()
            return result
        }
        #endif
        try Task.checkCancellation()
        let results = try await speech!.transcribe(audioArray: samples, decodeOptions: DecodingOptions(verbose: false, language: language, detectLanguage: language == nil, skipSpecialTokens: true, withoutTimestamps: true))
        try Task.checkCancellation()
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func prepareText(id: String, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws {
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
        #else
        throw FrogError.message("Built-in local models require Apple silicon.")
        #endif
    }
    func complete(_ text: String, instructions: String, id: String, url: URL, residency: @Sendable (Set<String>) async -> Void) async throws -> String {
        #if arch(arm64)
        try await prepareText(id: id, url: url, residency: residency)
        try Task.checkCancellation()
        let input = try await textModel!.prepare(input: UserInput(prompt: .chat([
            .system(instructions),
            .user(text)
        ]), additionalContext: ["enable_thinking": false]))
        try Task.checkCancellation()
        let stream = try await textModel!.generate(input: input, parameters: GenerateParameters(maxTokens: 2048, temperature: 0.1))
        var output = ""
        var stop: GenerateStopReason?
        for await generation in stream {
            try Task.checkCancellation()
            switch generation {
            case .chunk(let text): output += text
            case .info(let info): stop = info.stopReason
            case .toolCall: break
            }
        }
        // A cancelled task ends the stream early, without a stop reason.
        try Task.checkCancellation()
        return try Self.textResult(output, stop: stop)
        #else
        throw FrogError.message("Built-in local models require Apple silicon.")
        #endif
    }
    #if arch(arm64)
    /// What a generation that has ended may hand back. Text that ran into the
    /// token limit, or that ends inside the model's reasoning, is not a result:
    /// it would replace the selection with part of the answer.
    static func textResult(_ output: String, stop: GenerateStopReason?) throws -> String {
        switch stop {
        case .stop: break
        case .length: throw FrogError.message("The local model stopped before completing the text. Try a smaller selection.")
        case .cancelled, nil: throw CancellationError()
        }
        var output = output
        if let end = output.range(of: "</think>") { output = String(output[end.upperBound...]) }
        else if output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<think>") {
            throw FrogError.message("The local model returned its reasoning without a result. Try again or choose another model.")
        }
        let result = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw FrogError.message("The local model returned no text.") }
        return result
    }
    #endif
    func unload(keepingMetadata: Bool) async {
        await speech?.unloadModels(); speechID = nil
        // Idle expiry frees weights while retaining parsed tokenizer metadata for the
        // next recording. Explicit unload, deletion and folder changes drop everything.
        if !keepingMetadata { speech = nil }
        #if arch(arm64)
        await parakeet?.unload(); parakeet = nil
        textModel = nil
        MLX.Memory.clearCache()
        #endif
        textID = nil
    }
}

#if arch(arm64)
extension HubApi {
    /// The client for MLX and Parakeet files. It bypasses the shared Hugging Face
    /// cache in the home folder, which would keep a second copy of every file that
    /// deleting the model in Frog never removes. And it is forced online: offline
    /// mode would accept an unfinished folder with whichever files it already holds.
    static func modelFolder(_ base: URL) -> HubApi { HubApi(downloadBase: base, cache: nil, useOfflineMode: false) }
}
#endif
