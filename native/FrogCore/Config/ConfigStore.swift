import Foundation

/// config.toml for the running app: the document it was last read as, saves that never overwrite
/// an edit made elsewhere, and a watcher that picks up those edits.
///
/// It is `@MainActor` rather than an actor: every caller is UI or app lifecycle code on the main
/// actor, which reads settings synchronously; the file is at most 4 MB and read and written
/// synchronously; and the watcher's events arrive on the main queue, so `onChange` runs where its
/// handlers update the UI, without hops or a second copy of the configuration to keep in step.
@MainActor
public final class ConfigStore {
    public nonisolated static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/frog/config.toml")
    }

    public let fileURL: URL
    /// The configuration in effect: the file as last read or saved. A version on disk that does
    /// not read never replaces it.
    public private(set) var document = ConfigDocument()
    /// Called after an edit made outside Frog reads, by the watcher or when a save merged it.
    public var onChange: ((ConfigDocument) -> Void)?
    /// Called when an edit made outside Frog does not read; `document` stays as it was.
    public var onError: ((ConfigError) -> Void)?

    /// The version on disk that `document` matches.
    private var fingerprint: ConfigFingerprint?
    /// A broken version already reported, so it is reported once.
    private var rejected: ConfigFingerprint?
    private let debounce: TimeInterval
    private var watcher: ConfigFileWatcher?
    private var pendingCheck: DispatchWorkItem?

    /// `debounce` is how long the watcher waits for an editor to finish writing.
    public init(fileURL: URL = ConfigStore.defaultFileURL, debounce: TimeInterval = 0.15) {
        self.fileURL = fileURL
        self.debounce = debounce
    }

    // MARK: Reading

    /// Reads the file; a missing one is an empty document. A file that does not read throws and
    /// leaves `document` as it was.
    public func load() throws {
        guard let disk = try ConfigFile.read(fileURL) else {
            document = ConfigDocument(); fingerprint = nil; rejected = nil
            return
        }
        document = try ConfigDocument(data: disk.data)
        fingerprint = disk.fingerprint
        rejected = nil
    }

    public func section<T: ConfigSection>(_ name: String, as type: T.Type = T.self) throws -> ConfigSectionResult<T> {
        try document.section(name, as: type)
    }

    public func core<T: ConfigSection>(as type: T.Type = T.self) throws -> ConfigSectionResult<T> {
        try document.core(as: type)
    }

    public func pluginSwitches() throws -> [String: Bool] { try document.pluginSwitches() }

    /// Whether `[plugins]` turns a plugin on, or `default` when it does not say.
    public func isPluginEnabled(_ id: String, default fallback: Bool) -> Bool {
        document.value(at: ["plugins", id])?.boolValue ?? fallback
    }

    // MARK: Writing

    public func update<T: ConfigSection>(_ name: String, _ value: T) throws {
        try edit { try $0.update(name, value) }
    }

    public func updateCore<T: ConfigSection>(_ value: T) throws {
        try edit { try $0.updateCore(value) }
    }

    public func setPlugin(_ id: String, enabled: Bool) throws {
        try edit { try $0.setPlugin(id, enabled: enabled) }
    }

    /// Applies `change` and saves. When the file changed on disk since it was read, the change is
    /// applied to the version on disk instead, so an edit made in an editor is never lost; when
    /// that version does not read, nothing is saved and the error has kind `.externalEdit`.
    public func edit(_ change: (inout ConfigDocument) throws -> Void) throws {
        var candidate = document
        try change(&candidate)
        let disk = try ConfigFile.read(fileURL)
        var merged = false
        if disk?.fingerprint != fingerprint {
            let external: ConfigDocument
            do { external = try disk.map { try ConfigDocument(data: $0.data) } ?? ConfigDocument() }
            catch let error as ConfigError {
                rejected = disk?.fingerprint
                throw ConfigError(.externalEdit, line: error.line, column: error.column,
                                  "\(fileURL.lastPathComponent) was changed outside Frog and does not read (\(error.description)). Nothing was saved; fix the file and try again.")
            }
            candidate = external
            try change(&candidate)
            document = external
            fingerprint = disk?.fingerprint
            rejected = nil
            merged = true
        }
        if candidate != document || disk == nil && !candidate.data.isEmpty {
            fingerprint = try ConfigFile.write(candidate.data, to: fileURL)
            document = candidate
            watcher?.rearm()
        }
        if merged { onChange?(document) }
    }

    // MARK: Watching

    /// Watches the file and its folder, so an editor's atomic replace is seen as well as a write
    /// in place. Events within `debounce` of each other are checked once. Frog's own saves are not
    /// reported: the file then matches `document`.
    public func startWatching() {
        stopWatching()
        let watcher = ConfigFileWatcher(fileURL: fileURL) { [weak self] in
            MainActor.assumeIsolated { self?.fileEvent() }
        }
        watcher.rearm()
        self.watcher = watcher
    }

    public func stopWatching() {
        pendingCheck?.cancel()
        pendingCheck = nil
        watcher = nil
    }

    private func fileEvent() {
        pendingCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.checkForExternalEdit() }
        }
        pendingCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: check)
    }

    /// Reads the file after an event. A deleted file keeps the running configuration until a new one appears.
    func checkForExternalEdit() {
        pendingCheck = nil
        watcher?.rearm()
        let disk: (data: Data, fingerprint: ConfigFingerprint)?
        do { disk = try ConfigFile.read(fileURL) }
        catch let error as ConfigError { onError?(error); return }
        catch { return }
        guard let disk, disk.fingerprint != fingerprint, disk.fingerprint != rejected else { return }
        do {
            let edited = try ConfigDocument(data: disk.data)
            document = edited
            fingerprint = disk.fingerprint
            rejected = nil
            onChange?(edited)
        } catch let error as ConfigError {
            rejected = disk.fingerprint
            onError?(error)
        } catch {}
    }
}

/// Dispatch sources on config.toml and its folder. Editors that save by writing a new file and
/// renaming it over the old one leave the file source watching a deleted file; the folder source
/// sees the rename, and `rearm` opens the new file.
///
/// Unchecked because its sources are created, re-armed and cancelled only on the main queue,
/// which is also where their handlers run.
final class ConfigFileWatcher: @unchecked Sendable {
    private let fileURL: URL
    private let onEvent: @Sendable () -> Void
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var watchedFile: (dev_t, ino_t)?

    init(fileURL: URL, onEvent: @escaping @Sendable () -> Void) {
        self.fileURL = fileURL
        self.onEvent = onEvent
    }

    deinit {
        directorySource?.cancel()
        fileSource?.cancel()
    }

    /// Starts watching whatever is not watched yet, and follows the file to a new inode.
    func rearm() {
        let target = ConfigFile.target(fileURL)
        if directorySource == nil {
            directorySource = source(target.deletingLastPathComponent().path, events: [.write, .rename, .delete])
        }
        var info = stat()
        let current = stat(target.path, &info) == 0 ? (info.st_dev, info.st_ino) : nil
        if let current, let watchedFile, watchedFile == current, fileSource != nil { return }
        fileSource?.cancel()
        fileSource = nil
        watchedFile = nil
        guard let current else { return }
        fileSource = source(target.path, events: [.write, .extend, .delete, .rename, .attrib])
        if fileSource != nil { watchedFile = current }
    }

    private func source(_ path: String, events: DispatchSource.FileSystemEvent) -> (any DispatchSourceFileSystemObject)? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: .main)
        let onEvent = onEvent
        source.setEventHandler { onEvent() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}
