import Foundation
import Combine
import CryptoKit
import FrogCore
import os
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
    /// A downloader that reports a fraction of 1 and keeps working is preparing the
    /// model, which has no fraction (`preparing`).
    typealias Downloader = @Sendable (LocalModelDescriptor, URL, @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL
    /// The bytes free on the disk that holds a folder, or nil when it cannot be told.
    typealias FreeSpaceReader = @Sendable (URL) -> Int64?
    /// Checks a downloaded model's files: the model, its folder and the folder its
    /// download returned. It runs off the main actor.
    typealias FileChecker = @Sendable (LocalModelDescriptor, URL, URL) -> ModelFileCheck
    enum FileCheckState: Equatable { case checking, finished(ModelFileCheck) }
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
    @Published private(set) var progress: [String: DownloadProgress] = [:]
    /// Downloads whose files are in and whose model is being made ready for use.
    @Published private(set) var preparing = Set<String>()
    @Published private(set) var errors: [String: String] = [:]
    /// What the folder of each downloaded model takes on disk, once measured.
    @Published private(set) var diskUse: [String: Int64] = [:]
    /// What "Check files" found for a downloaded model, until it is repaired or deleted.
    @Published private(set) var fileChecks: [String: FileCheckState] = [:]
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
    private let freeSpace: FreeSpaceReader
    private let fileChecker: FileChecker
    private var checking: [String: Task<Void, Never>] = [:]
    private var measuring: Task<Void, Never>?
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
        measureDiskUse()
    }
    func descriptor(_ id: String) -> LocalModelDescriptor? { catalog.first { $0.id == id } }

    init(directory: URL? = nil, runtime: any LocalInferenceEngine = LocalInference(), downloader: @escaping Downloader = LocalInference.download, freeSpace: @escaping FreeSpaceReader = LocalModels.availableCapacity,
         fileChecker: @escaping FileChecker = { ModelFiles.check($0, folder: $1, installed: $2, contents: true) }) {
        self.runtime = runtime; self.downloader = downloader; self.freeSpace = freeSpace; self.fileChecker = fileChecker
        let support = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Frog")
        defaultDirectory = support.appendingPathComponent("Models", isDirectory: true)
        storagePreference = support.appendingPathComponent("model-storage.json")
        if let data = try? Data(contentsOf: storagePreference), let path = try? JSONDecoder().decode(String.self, from: data), path.hasPrefix("/") {
            root = URL(fileURLWithPath: path, isDirectory: true)
        } else { root = defaultDirectory }
        for model in LocalModelDescriptor.catalog where modelURL(model.id) != nil { installed.insert(model.id) }
        unfinished = unfinishedDownloads()
        measureDiskUse()
    }
    /// Storage location is device-local, intentionally excluded from configuration exports.
    func changeDirectory(to location: URL) async throws {
        guard !busy, residencyHolds.isEmpty, downloads.isEmpty, !changingDirectory else { throw FrogError.message("Wait for model operations to finish before changing the download folder.") }
        guard location.isFileURL else { throw FrogError.message("Choose a local model folder.") }
        let location = URL(fileURLWithPath: location.standardizedFileURL.path, isDirectory: true)
        if location == root {
            // Choosing the folder again finds the models of a disk connected since launch.
            installed = Set(catalog.filter { modelURL($0.id) != nil }.map(\.id))
            unfinished = unfinishedDownloads()
            measureDiskUse()
            onInventoryChanged?()
            return
        }
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
        errors = [:]; fileChecks = [:]
        measureDiskUse()
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
    /// Measures the folders of the downloaded models off the main actor. What they
    /// take changes only with a download, a deletion, the folder or the catalogue,
    /// so they are measured then and not each time a view asks.
    private func measureDiskUse() {
        let folders = Dictionary(uniqueKeysWithValues: installed.map { ($0, directory($0)) })
        measuring?.cancel()
        measuring = Task { [weak self] in
            let sizes = await Task.detached(priority: .utility) { folders.mapValues(Self.allocatedSize) }.value
            guard let self, !Task.isCancelled else { return }
            self.diskUse = sizes.filter { self.installed.contains($0.key) }
        }
    }
    func waitForDiskUse() async { await measuring?.value }
    /// What the measured models among `ids` take together; nil when none is measured.
    func totalDiskUse(of ids: some Sequence<String>) -> Int64? {
        let sizes = Set(ids).compactMap { diskUse[$0] }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }
    /// The size a model's row shows: what its folder takes once it is downloaded,
    /// otherwise what its download fetches.
    func size(of model: LocalModelDescriptor) -> String {
        diskUse[model.id].map(LocalModelDescriptor.byteCount) ?? model.downloadSize
    }
    /// What the files in a folder take on disk; nothing for a folder that does not exist.
    nonisolated static func allocatedSize(_ folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
    /// The space macOS would free for a download the person asked for, read from the
    /// nearest folder that exists, since the model folder may not exist yet.
    nonisolated static func availableCapacity(_ folder: URL) -> Int64? {
        var folder = folder.standardizedFileURL
        while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 { folder.deleteLastPathComponent() }
        guard let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values.volumeAvailableCapacity.map(Int64.init)
    }
    /// Room a download leaves on the disk besides the model, for macOS and the other apps.
    static let spareBytes: Int64 = 100_000_000
    /// The size of each running download that was checked for room, and what its
    /// folder held when it started.
    private var admitted: [String: (bytes: Int64, fetched: Int64)] = [:]
    /// What the running downloads other than `id` have still to fetch. What they
    /// fetched is already off the free space.
    private func pendingBytes(besides id: String) -> Int64 {
        admitted.filter { $0.key != id }.reduce(0) { total, download in
            let received = max(download.value.fetched, progress[download.key]?.bytesReceived ?? 0)
            return total + max(download.value.bytes - received, 0)
        }
    }
    /// Refuses a download that would not fit on the disk of the model folder,
    /// beside what the downloads under way have still to fetch. A resumed download
    /// needs room only for what its folder lacks; a model whose size is unknown is
    /// not checked.
    private func ensureRoom(for model: LocalModelDescriptor, in folder: URL) async throws {
        guard let bytes = model.downloadBytes else { return }
        let freeSpace = freeSpace, root = root
        let (free, fetched) = await Task.detached(priority: .userInitiated) { (freeSpace(root), Self.allocatedSize(folder)) }.value
        let needed = max(bytes - fetched, 0) + Self.spareBytes, pending = pendingBytes(besides: model.id)
        guard let free, free < needed + pending else { admitted[model.id] = (bytes, fetched); return }
        let disk = "\(model.name) needs about \(LocalModelDescriptor.byteCount(needed)) of free space, but the disk of the model folder has \(LocalModelDescriptor.byteCount(max(free, 0))) free"
        if pending > 0 { throw FrogError.message("\(disk) and the downloads under way still need \(LocalModelDescriptor.byteCount(pending)) of it. Wait for them to finish, free up space or choose another model folder in Settings, then try again.") }
        throw FrogError.message("\(disk). Free up space or choose another model folder in Settings, then try again.")
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
        errors[model.id] = nil; progress[model.id] = DownloadProgress(fraction: 0)
        downloads[model.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.downloadEnded(model.id) }
            var marked = resuming
            do {
                try await self.ensureRoom(for: model, in: base)
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                if !marked { try Data().write(to: marker); marked = true }
                self.unfinished.insert(model.id)
                try await self.fetch(model, into: base)
                try? FileManager.default.removeItem(at: marker)
                self.unfinished.remove(model.id)
                self.installed.insert(model.id)
                self.measureDiskUse()
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
    /// Runs the downloader into a model's folder, with the row's progress, and records
    /// the installation that it returns.
    private func fetch(_ model: LocalModelDescriptor, into base: URL) async throws {
        let url = try await downloader(model, base) { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, self.downloads[model.id] != nil else { return }
                self.show(update, for: model.id)
            }
        }
        try Task.checkCancellation()
        guard url.path.hasPrefix(base.path + "/") else { throw FrogError.message("Invalid model installation path.") }
        let relative = String(url.path.dropFirst(base.path.count + 1))
        try relative.write(to: base.appendingPathComponent("installed.txt"), atomically: true, encoding: .utf8)
    }
    private func downloadEnded(_ id: String) {
        downloads[id] = nil; progress[id] = nil; progressShown[id] = nil; admitted[id] = nil; preparing.remove(id); discarding.remove(id)
    }
    /// Checks a downloaded model's files off the main actor; `fileChecks` has the result.
    func checkFiles(_ id: String) {
        guard let model = descriptor(id), installed.contains(id), downloads[id] == nil, checking[id] == nil, let url = modelURL(id) else { return }
        let base = directory(id), root = root, checker = fileChecker
        fileChecks[id] = .checking
        checking[id] = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { checker(model, base, url) }.value
            guard let self else { return }
            self.checking[id] = nil
            // A deletion, a repair or another model folder makes the result stale.
            guard self.root == root, self.installed.contains(id), self.fileChecks[id] == .checking else { return }
            self.fileChecks[id] = .finished(result)
        }
    }
    func waitForFileCheck(_ id: String) async { await checking[id]?.value }
    /// Fetches again what a check found missing or damaged, into the same folder with
    /// the normal download. The library skips a file whose recorded commit matches
    /// without reading it, so damaged files are removed first; the rest is kept. The
    /// model stays downloaded meanwhile, so its rules keep it, but it does not run.
    func repair(_ id: String) async throws {
        guard !busy, residencyHolds.isEmpty, downloads[id] == nil, checking[id] == nil, !changingDirectory else { throw FrogError.message("Wait for the model operation to finish before repairing it.") }
        guard Self.supported, let model = descriptor(id), installed.contains(id), case .finished(let check) = fileChecks[id], !check.passed else { return }
        if loaded.contains(id) {
            busy = true
            unloadTask?.cancel(); unloadTask = nil
            loaded = []; await runtime.unload(keepingMetadata: false)
            busy = false
        }
        guard downloads[id] == nil, installed.contains(id) else { return }
        let base = directory(id)
        errors[id] = nil; fileChecks[id] = nil; progress[id] = DownloadProgress(fraction: 0)
        downloads[id] = Task { [weak self] in
            guard let self else { return }
            var repaired = false
            defer {
                self.downloadEnded(id)
                if repaired { self.checkFiles(id) }
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    for path in check.damaged { try ModelFiles.remove(base.appendingPathComponent(path)) }
                }.value
                try await self.fetch(model, into: base)
                repaired = true
                self.measureDiskUse()
            } catch {
                // Cancelling keeps the files: the model is still downloaded.
                if !Task.isCancelled { self.errors[id] = error.localizedDescription }
            }
        }
    }
    /// The line under a download's bar changes with every byte; it is published again
    /// at most this often.
    static let progressLineInterval: TimeInterval = 0.5
    /// When each download's progress was last published, as system uptime.
    private var progressShown: [String: TimeInterval] = [:]
    /// Every publish redraws all that observes the models, and a download reports
    /// about ten times a second: a new value goes out only when its row would show
    /// another whole percent, the files being in, or a new line that is due.
    private func show(_ update: DownloadProgress, for id: String) {
        if update.hasAllFiles, !preparing.contains(id) { preparing.insert(id) }
        let now = ProcessInfo.processInfo.systemUptime
        if let shown = progress[id], Int(shown.fraction * 100) == Int(update.fraction * 100) {
            guard shown.summary != update.summary, now - (progressShown[id] ?? 0) >= Self.progressLineInterval else { return }
        }
        progress[id] = update; progressShown[id] = now
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
            do { try await runtime.prepare(model: model, url: url, residency: { [weak self] ids in await self?.updateResidency(ids) }) }
            catch where !(error is CancellationError) && !Task.isCancelled { throw FrogError.message(Self.loadFailure(error, model: model)) }
        }
        try Task.checkCancellation()
    }
    /// A model that downloaded completely and does not load may have damaged files.
    /// The library's own text stays in the message.
    static func loadFailure(_ error: Error, model: LocalModelDescriptor) -> String {
        var original = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = original.last, !".!?".contains(last) { original += "." }
        return "Could not load \(model.name): \(original) Its files may be damaged: in Models, choose Check files in its menu."
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
        installed.remove(id); unfinished.remove(id); errors[id] = nil; diskUse[id] = nil; fileChecks[id] = nil
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
        // Only a repair downloads into the folder of a downloaded model.
        guard downloads[id] == nil else { throw FrogError.message("\(descriptor(id)?.name ?? id) is being repaired. Try again once its download has finished.") }
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

/// Measures a model download for its row: the bytes fetched so far, a fraction
/// that follows them, and a speed averaged over the last few seconds.
///
/// The libraries count files: each file of a download is one equal step of their
/// progress, whether it is a small configuration or the weights. The order of the
/// files is not known in advance, so their sizes cannot be lined up with those
/// steps. The bytes are read from the model folder instead, where every file lands.
final class DownloadMeter: @unchecked Sendable {
    /// The speed is averaged over this many seconds…
    static let window: TimeInterval = 5
    /// …and reported once the average covers this many, so a first burst does not
    /// promise a time left.
    static let steady: TimeInterval = 3
    private let folder: URL
    private let expected: Int64?
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    private var received: Int64 = 0
    /// What the folder held when the last file landed, and the estimated bytes of the file in flight.
    private var landed: Int64 = 0, flowing: Int64 = 0
    private var filesDone: Int64 = -1
    private var lastFlow: TimeInterval = 0

    init(folder: URL, expected: Int64?, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.folder = folder; self.expected = expected.flatMap { $0 > 0 ? $0 : nil }; self.now = now
    }

    /// For a library that writes each file into the folder as it arrives (WhisperKit).
    func written(fraction: Double) -> DownloadProgress {
        lock.withLock { report(Self.fileBytes(folder), fraction: fraction, at: now()) }
    }

    /// For swift-transformers' snapshot, whose progress counts files and which keeps
    /// the file in flight in a temporary file until it is complete. The bytes of
    /// that file follow from the speed the library reports with each step, and the
    /// folder is read again whenever a file lands, which corrects the estimate.
    func snapshot(_ progress: Progress) -> DownloadProgress {
        lock.withLock {
            let time = now()
            if progress.completedUnitCount != filesDone {
                filesDone = progress.completedUnitCount
                landed = Self.fileBytes(folder); flowing = 0; lastFlow = time
            } else if let speed = progress.userInfo[.throughputKey] as? Double {
                // The library's speed covers the time since its previous step that
                // carried bytes; a heartbeat while nothing arrives carries no speed.
                flowing += Int64(max(speed, 0) * (time - lastFlow)); lastFlow = time
            }
            return report(landed + flowing, fraction: progress.fractionCompleted, at: time)
        }
    }

    private func report(_ bytes: Int64, fraction library: Double, at time: TimeInterval) -> DownloadProgress {
        received = min(max(bytes, received), expected ?? .max)
        samples.append((time, received))
        while samples.count > 1, samples[1].time <= time - Self.window { samples.removeFirst() }
        let span = time - samples[0].time
        let speed = span >= Self.steady ? Double(received - samples[0].bytes) / span : nil
        // A full bar says that the files are in: only the library may say that.
        let fraction = library >= 1 ? 1 : expected.map { min(Double(received) / Double($0), 0.999) } ?? library
        return DownloadProgress(fraction: fraction, bytesReceived: received, bytesExpected: expected, bytesPerSecond: speed)
    }

    /// The length of the files in a folder, hidden partial files included: what was
    /// fetched, not what the disk allots to it.
    static func fileBytes(_ folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

/// What checking a downloaded model's files found, as paths relative to its folder.
struct ModelFileCheck: Equatable, Sendable {
    var missing: [String] = []
    var damaged: [String] = []
    var passed: Bool { missing.isEmpty && damaged.isEmpty }
    /// "2 files missing, 1 damaged: tokenizer.json, config.json, model.safetensors"
    var summary: String {
        guard !passed else { return "All files are present and match the download." }
        var counts: [String] = []
        if !missing.isEmpty { counts.append(missing.count == 1 ? "1 file missing" : "\(missing.count) files missing") }
        if !damaged.isEmpty { counts.append(damaged.count == 1 ? (missing.isEmpty ? "1 file damaged" : "1 damaged") : (missing.isEmpty ? "\(damaged.count) files damaged" : "\(damaged.count) damaged")) }
        let files = missing + damaged
        return counts.joined(separator: ", ") + ": " + files.prefix(3).map(Self.name).joined(separator: ", ") + (files.count > 3 ? "…" : "")
    }
    /// A path as the repository on Hugging Face has it, without `models/<owner>/<name>/`.
    private static func name(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.first == "models" && parts.count > 3 ? parts.dropFirst(3).joined(separator: "/") : path
    }
}

/// Checks a downloaded model's files without the network. The Hugging Face clients
/// of swift-transformers and WhisperKit record each file they fetch in
/// `<repository>/.cache/huggingface/download/<file>.metadata`: commit, etag and time.
/// The etag of a file stored by LFS, the weights among them, is the SHA-256 of its
/// bytes. The libraries' own offline check stops at the first file that differs and
/// does not notice a missing one, so the same records are read here.
enum ModelFiles {
    /// The files that a runtime cannot load without, relative to the folder its download returns.
    static func required(_ model: LocalModelDescriptor) -> [String] {
        switch model.backend {
        case .mlx: ["config.json", "tokenizer.json", "tokenizer_config.json"]
        case .parakeet: ["Preprocessor", "Encoder", "Decoder", "JointDecision"].map { "\($0).mlmodelc/coremldata.bin" } + ["parakeet_vocab.json"]
        case .whisperKit: ["AudioEncoder", "TextDecoder", "MelSpectrogram"].map { "\($0).mlmodelc/coremldata.bin" }
        }
    }

    /// Missing: a required file, or a file that the download recorded, is not there.
    /// Damaged: a required file is empty, or, when `contents` is set, the bytes of an
    /// LFS file no longer have the hash recorded for it. Reading every byte takes a
    /// few seconds for a model of gigabytes; without `contents` the check is instant.
    static func check(_ model: LocalModelDescriptor, folder: URL, installed: URL, contents: Bool) -> ModelFileCheck {
        let base = folder.standardizedFileURL.path, installedPath = installed.standardizedFileURL.path
        let prefix = installedPath.hasPrefix(base + "/") ? String(installedPath.dropFirst(base.count + 1)) + "/" : ""
        var missing = Set<String>(), damaged = Set<String>()
        func size(_ path: String) -> Int64? {
            guard let values = try? folder.appendingPathComponent(path).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { return nil }
            return Int64(values.fileSize ?? 0)
        }
        for name in required(model) {
            switch size(prefix + name) { case nil: missing.insert(prefix + name); case 0: damaged.insert(prefix + name); default: break }
        }
        if model.backend == .mlx {
            let weights = ((try? FileManager.default.contentsOfDirectory(atPath: installedPath)) ?? []).filter { $0.hasSuffix(".safetensors") }
            if weights.isEmpty { missing.insert(prefix + "*.safetensors") }
            for file in weights where size(prefix + file) == 0 { damaged.insert(prefix + file) }
        }
        let records = ".cache/huggingface/download/", suffix = ".metadata"
        for case let path as String in FileManager.default.enumerator(atPath: base) ?? NSEnumerator() where path.hasSuffix(suffix) {
            // "models/<owner>/<name>/.cache/huggingface/download/<file>.metadata" records "models/<owner>/<name>/<file>".
            guard let range = path.range(of: records), range.lowerBound == path.startIndex || path[path.index(before: range.lowerBound)] == "/" else { continue }
            let target = String(path[..<range.lowerBound]) + String(path[range.upperBound...].dropLast(suffix.count))
            guard let record = try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8) else { continue }
            let lines = record.components(separatedBy: .newlines)
            guard lines.count >= 3 else { continue }
            guard let length = size(target) else { missing.insert(target); continue }
            let etag = lines[1].trimmingCharacters(in: .whitespaces)
            if contents, isSHA256(etag), length == 0 || sha256(folder.appendingPathComponent(target)) != etag { damaged.insert(target) }
        }
        return ModelFileCheck(missing: missing.sorted(), damaged: damaged.subtracting(missing).sorted())
    }

    /// The check at the end of a download, before it counts as installed. Empty files
    /// are removed, so that resuming the download fetches them again.
    static func requireComplete(_ model: LocalModelDescriptor, folder: URL, installed: URL) throws -> URL {
        try Task.checkCancellation()
        let check = check(model, folder: folder, installed: installed, contents: false)
        guard !check.passed else { return installed }
        for path in check.damaged { try remove(folder.appendingPathComponent(path)) }
        throw FrogError.message("The download of \(model.name) lacks files that it needs (\(check.summary)). Resume the download to fetch them; if this happens again, the source on Hugging Face may not include them.")
    }

    static func remove(_ file: URL) throws {
        do { try FileManager.default.removeItem(at: file) }
        catch CocoaError.fileNoSuchFile { /* Already gone. */ }
    }

    private static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func sha256(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = autoreleasepool { try? handle.read(upToCount: 4 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
    /// MLX keeps freed buffers for reuse, by default up to its whole memory limit:
    /// a cache that grows through a long generation and holds on to the weights of
    /// a replaced model. MLX suggests 20 MB of cache for running a language model.
    static let textBufferCache = 20 * 1024 * 1024
    #endif
    private var textID: String?
    var loadedIDs: Set<String> { Set([speechID, textID].compactMap { $0 }) }

    static func download(_ model: LocalModelDescriptor, base: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
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
        // Any other download error is a request that got no answer, the file list
        // first of all: the client passes it on as the text of its URL error only.
        case Hub.HubClientError.downloadError: return offline
        default: break
        }
        #endif
        if error is FrogError { return error.localizedDescription }
        let unreachable: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff]
        if let network = cause as? URLError, unreachable.contains(network.code) { return offline }
        let code = cause as NSError
        if (code.domain == NSCocoaErrorDomain && code.code == NSFileWriteOutOfSpaceError) || (code.domain == NSPOSIXErrorDomain && code.code == Int(ENOSPC)) {
            return "Not enough free disk space for \(model.name)\(model.downloadBytes.map { " (\(LocalModelDescriptor.byteCount($0)))" } ?? ""). Free up space and try again; the files already downloaded are kept."
        }
        return "Could not download \(model.name). \(error.localizedDescription)"
    }
    private static func fetch(_ model: LocalModelDescriptor, base: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        #if arch(arm64)
        if model.backend == .parakeet { return try ModelFiles.requireComplete(model, folder: base, installed: try await ParakeetRuntime.download(model, base: base, progress: progress)) }
        let meter = DownloadMeter(folder: base, expected: model.downloadBytes)
        if model.backend == .whisperKit {
            // WhisperKit appends each file to a partial file in the model folder, so
            // the folder holds every byte so far. It is read twice a second, which
            // also shows a download that has stopped receiving anything.
            let fraction = OSAllocatedUnfairLock(initialState: 0.0)
            let reading = Task.detached {
                while !Task.isCancelled {
                    progress(meter.written(fraction: min(fraction.withLock { $0 }, 0.999)))
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            let url: URL
            do {
                url = try await WhisperKit.download(variant: model.variant!, downloadBase: base, from: model.repository) { update in fraction.withLock { $0 = update.fractionCompleted } }
                reading.cancel(); await reading.value
            } catch { reading.cancel(); await reading.value; throw error }
            try Task.checkCancellation()
            // Download/tokenize during explicit installation, not the first recording.
            // Loading the model once takes a while and reports nothing: say so
            // instead of leaving a bar that stands still.
            progress(.filesAreIn)
            let kit = try await WhisperKit(WhisperKitConfig(modelFolder: url.path, tokenizerFolder: base, computeOptions: whisperCompute, verbose: false, logLevel: .none, prewarm: false, load: true, download: false))
            await kit.unloadModels()
            return url
        }
        let folder = try await HubApi.modelFolder(base).snapshot(from: model.repository, matching: LocalModelDescriptor.mlxDownloadPatterns) { progress(meter.snapshot($0)) }
        // WhisperKit loads its model above; the other runtimes find a missing file only at first use.
        return try ModelFiles.requireComplete(model, folder: base, installed: folder)
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
            // The replaced model's weights go back to macOS before the next one loads.
            MLX.Memory.cacheLimit = Self.textBufferCache
            MLX.Memory.clearCache()
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
