import Foundation
import Darwin

// Serialize read/modify/write transactions across store instances in this process. The two
// stores never touch each other's files, so saving history does not wait for the configuration.
private let configurationLock = NSRecursiveLock()
private let historyLock = NSRecursiveLock()

enum PrivateFile {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Frog", isDirectory: true)
    }

    static func read(_ url: URL, maximumBytes: Int) throws -> Data? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw FrogError.message("Unable to read \(url.lastPathComponent).")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maximumBytes else {
            throw FrogError.message("\(url.lastPathComponent) is not a supported data file. The original file was preserved.")
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw FrogError.message("Unable to read \(url.lastPathComponent).") }
        defer { close(descriptor) }
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= maximumBytes else { throw FrogError.message("Unable to read the data file safely.") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw FrogError.message("Unable to read \(url.lastPathComponent).")
            }
            if count == 0 { break }
            guard data.count + count <= maximumBytes else { throw FrogError.message("The data file is too large.") }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    static func write(_ data: Data, to url: URL, secureDirectory: Bool = true) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              !secureDirectory || chmod(directory.path, 0o700) == 0 else {
            throw FrogError.message("Unable to secure the Frog data directory.")
        }
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw FrogError.message("Unable to create a private data file.") }
        defer { close(descriptor); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw FrogError.message("Unable to save the data file.") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else {
            throw FrogError.message("Unable to finish saving the data file. The previous file was preserved.")
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, name: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw FrogError.message("\(name) could not be decoded. The original file was preserved; restore a backup or move it aside before saving.") }
    }
}

/// Device-local onboarding state is intentionally excluded from configuration exports.
public struct SetupStore {
    private let file: URL
    public init(directory: URL) { file = directory.appendingPathComponent("setup.json") }
    public func needsSetup(existingConfiguration: Bool) throws -> Bool {
        if let data = try PrivateFile.read(file, maximumBytes: 1024) {
            return !(try PrivateFile.decode(Bool.self, from: data, name: "Setup state"))
        }
        // Existing installations keep their setup; new installations resume until skipped/completed.
        try complete(existingConfiguration)
        return !existingConfiguration
    }
    public func complete(_ value: Bool = true) throws { try PrivateFile.write(JSONEncoder().encode(value), to: file) }
}

/// Unchecked because the snapshot it compares the files with changes, as does whether it has noted
/// config.json; both change and are read only while `configurationLock` is held.
public final class ConfigurationStore: @unchecked Sendable {
    public let directory: URL
    /// Complex rules, connections and custom model definitions.
    public var file: URL { directory.appendingPathComponent("config.json") }
    public var textFile: URL { directory.appendingPathComponent("config") }
    private let legacyFile: URL?
    /// Device-local note that config.json has existed beside config on this Mac. Without it a lone
    /// config is a first configuration; with it, config.json went missing.
    private let companionMarker: URL?
    private var companionRecorded = false
    private struct Snapshot: Equatable {
        let textTarget: URL
        let jsonTarget: URL
        let text: Data?
        let json: Data?
    }
    private var snapshot: Snapshot?
    private var loaded: Configuration?
    /// Recovery copies kept for each kind of backup; writing another removes the oldest.
    static let retainedBackups = 5
    /// Times both files were read from disk. A save needs it once before its first write, and
    /// again only after writing config.json, before config follows.
    private(set) var snapshotReads = 0
    public var hasExistingConfiguration: Bool {
        FileManager.default.fileExists(atPath: textFile.path) || FileManager.default.fileExists(atPath: file.path) || legacyFile.map { FileManager.default.fileExists(atPath: $0.path) } == true
    }
    public init(directory: URL? = nil, legacyDirectory: URL? = nil) {
        let configurationDirectory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/frog", isDirectory: true)
        self.directory = configurationDirectory
        let legacy = legacyDirectory ?? (directory == nil ? PrivateFile.defaultDirectory : directory)
        legacyFile = legacy?.appendingPathComponent("configuration.json")
        // It stays out of the configuration directory, which may be synced to another Mac.
        companionMarker = legacy.flatMap { $0.standardizedFileURL == configurationDirectory.standardizedFileURL ? nil : $0.appendingPathComponent("config-companion") }
    }

    public func load(validating validate: ((Configuration) throws -> Void)? = nil) throws -> Configuration {
        configurationLock.lock(); defer { configurationLock.unlock() }
        let current = try readSnapshot()
        let configuration: Configuration
        if let text = current.text {
            if current.json == nil, snapshot?.json != nil || companionNoted {
                throw FrogError.message(loaded == nil
                    ? "config.json is missing beside config. Restore it, import a configuration in Settings, or remove config as well to start again. The files were left unchanged."
                    : "config.json is missing. Restore the companion file before reloading; the current rules and connections were kept.")
            }
            guard let string = String(data: text, encoding: .utf8) else { throw FrogError.message("config must be UTF-8 text. The original file was preserved.") }
            do { configuration = try TextConfiguration.decode(string, companion: current.json ?? ConfigurationFile.encode(Configuration())) }
            catch let FrogError.message(message) where loaded == nil && message.hasSuffix(TextConfiguration.keptRemark) {
                // At launch nothing has loaded yet: there are no previous settings that could have been kept.
                throw FrogError.message(message.dropLast(TextConfiguration.keptRemark.count) + "The files were left unchanged.")
            }
        } else if let json = current.json, !isPrototypeConfiguration(json) {
            configuration = try ConfigurationFile.decode(json)
            try validate?(configuration)
            // A migration that cannot be written is retried on every launch; it must not leave a backup each time.
            let prepared = try prepare(configuration, preserving: nil)
            try backup(json, name: "config-legacy-backup", extension: "json")
            try apply(prepared, expected: current)
            return configuration
        } else if let legacyFile, !companionNoted, let previous = try readConfigurationFile(legacyFile) {
            // The previous file is left as it is, so it needs no copy; once config.json has existed
            // on this Mac it is out of date and is only read again through Import.
            configuration = try ConfigurationFile.decode(previous)
            try validate?(configuration)
            let prepared = try prepare(configuration, preserving: nil)
            if let json = current.json { try backup(json, name: "config-prototype-backup", extension: "json") }
            try apply(prepared, expected: current)
            return configuration
        } else {
            if current.json != nil { throw FrogError.message("config.json belongs to an older Frog prototype. Import a native configuration in Settings; the original will be backed up.") }
            configuration = Configuration()
        }
        try validate?(configuration)
        snapshot = current; loaded = configuration
        if current.json != nil { recordCompanion() }
        return configuration
    }

    private var companionNoted: Bool {
        companionMarker.map { FileManager.default.fileExists(atPath: $0.path) } == true
    }
    /// Notes once that config.json exists beside config. A note that cannot be written only loses
    /// what it protects against; it must not stop a load or a save.
    private func recordCompanion() {
        guard !companionRecorded, let companionMarker else { return }
        companionRecorded = FileManager.default.fileExists(atPath: companionMarker.path)
            || (try? PrivateFile.write(Data(), to: companionMarker)) != nil
    }

    private func isPrototypeConfiguration(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return Set(object.keys) == Set(["globalHotkeys", "llm", "shortcuts", "textProcessing"])
    }

    public func save(_ configuration: Configuration) throws {
        configurationLock.lock(); defer { configurationLock.unlock() }
        if snapshot == nil { _ = try load() }
        guard let snapshot else { return }
        // The files are compared with this snapshot once, right before the first write.
        var candidate = configuration
        // UI candidates retain extension fields from the last successfully loaded document.
        candidate.originalJSON = loaded?.originalJSON ?? candidate.originalJSON
        candidate.knownJSON = loaded?.knownJSON ?? candidate.knownJSON
        try commit(candidate, preserving: snapshot.text.flatMap { String(data: $0, encoding: .utf8) }, expected: snapshot)
    }

    /// Explicit import can recover unreadable settings without discarding the previous file.
    @discardableResult
    public func replaceFromImport(_ configuration: Configuration) throws -> URL? {
        configurationLock.lock(); defer { configurationLock.unlock() }
        try ConfigurationFile.validate(configuration)
        let current = try readSnapshot()
        var backup: URL?
        if let previous = current.json { backup = try self.backup(previous, name: "configuration-backup", extension: "json") }
        if let previous = current.text {
            let url = try self.backup(previous, name: "configuration-backup", extension: "conf")
            if backup == nil { backup = url }
        }
        // Preserve comments on a valid text document; corrupt text is preserved in the backup.
        let text = current.text.flatMap { String(data: $0, encoding: .utf8) }
        let rendered = text.flatMap { try? TextConfiguration.render(configuration, preserving: $0) }
        try commit(configuration, preserving: rendered, expected: current)
        return backup
    }

    private func readConfigurationFile(_ url: URL) throws -> Data? {
        try PrivateFile.read(url.resolvingSymlinksInPath(), maximumBytes: ConfigurationFile.maximumBytes)
    }
    /// Foundation may retain /private/var for a missing leaf but shorten it to /var
    /// once that file exists. Resolve ancestors as well so our own first write does
    /// not look like a symlink retarget. Real symlink destination changes still differ.
    private func resolvedTarget(_ url: URL) -> URL {
        var path = url.resolvingSymlinksInPath().path
        var missing: [String] = []
        while true {
            if let resolved = realpath(path, nil) {
                defer { free(resolved) }
                var target = URL(fileURLWithPath: String(cString: resolved))
                for component in missing.reversed() { target.appendPathComponent(component) }
                return target
            }
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != path else { return url.standardizedFileURL }
            missing.append((path as NSString).lastPathComponent)
            path = parent
        }
    }
    private func readSnapshot() throws -> Snapshot {
        snapshotReads += 1
        let textTarget = resolvedTarget(textFile), jsonTarget = resolvedTarget(file)
        guard textTarget != jsonTarget else { throw FrogError.message("config and config.json must point to different files.") }
        return try Snapshot(textTarget: textTarget, jsonTarget: jsonTarget,
                            text: PrivateFile.read(textTarget, maximumBytes: ConfigurationFile.maximumBytes),
                            json: PrivateFile.read(jsonTarget, maximumBytes: ConfigurationFile.maximumBytes))
    }
    private func ensureUnchanged(_ expected: Snapshot) throws {
        guard try readSnapshot() == expected else {
            throw FrogError.message("Configuration changed outside Frog. Use Settings → Configuration → Reload before editing in the app. Your files and working settings were preserved.")
        }
    }
    @discardableResult
    private func backup(_ bytes: Data, name: String, extension ext: String) throws -> URL {
        let url = directory.appendingPathComponent("\(name)-\(UUID().uuidString).\(ext)").resolvingSymlinksInPath()
        try PrivateFile.write(bytes, to: url, secureDirectory: false)
        pruneBackups(besides: url, name: name, extension: ext)
        return url
    }
    /// Keeps the newest recovery copies of one kind. Only regular files with the exact name Frog
    /// gives a backup are candidates: the directory may be shared with other tools.
    private func pruneBackups(besides newest: URL, name: String, extension ext: String) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: newest.deletingLastPathComponent(), includingPropertiesForKeys: Array(keys)) else { return }
        let prefix = name + "-"
        let older = files.compactMap { file -> (url: URL, modified: Date)? in
            let stem = file.deletingPathExtension().lastPathComponent
            guard file.lastPathComponent != newest.lastPathComponent, file.pathExtension == ext, stem.hasPrefix(prefix),
                  UUID(uuidString: String(stem.dropFirst(prefix.count))) != nil,
                  let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let modified = values.contentModificationDate else { return nil }
            return (file, modified)
        }.sorted { $0.modified > $1.modified }
        for backup in older.dropFirst(Self.retainedBackups - 1) { try? FileManager.default.removeItem(at: backup.url) }
    }
    /// A candidate that rendered, fits and reads back. Preparing one changes no file.
    private struct Prepared {
        let configuration: Configuration
        let text: Data
        let json: Data
    }
    private func prepare(_ configuration: Configuration, preserving text: String?) throws -> Prepared {
        let json = try TextConfiguration.companion(configuration)
        let rendered = try TextConfiguration.render(configuration, preserving: text)
        let bytes = Data(rendered.utf8)
        guard bytes.count <= ConfigurationFile.maximumBytes, json.count <= ConfigurationFile.maximumBytes else { throw FrogError.message("Configuration is too large (maximum 4 MB per file).") }
        // Validate the actual representation before changing either file. Its unknown fields
        // were already carried over by `companion`, so they need not be collected again.
        _ = try TextConfiguration.decode(rendered, companion: json, retainingUnknownFields: false)
        return Prepared(configuration: configuration, text: bytes, json: json)
    }
    private func commit(_ configuration: Configuration, preserving text: String?, expected: Snapshot) throws {
        try apply(prepare(configuration, preserving: text), expected: expected)
    }
    private func apply(_ prepared: Prepared, expected: Snapshot) throws {
        let configuration = prepared.configuration, bytes = prepared.text, json = prepared.json
        let committed = Snapshot(textTarget: expected.textTarget, jsonTarget: expected.jsonTarget, text: bytes, json: json)
        try ensureUnchanged(expected)
        // Atomic replacement follows the resolved destination, preserving chezmoi symlinks.
        // Never chmod an existing dotfiles directory: it may be shared with other applications.
        if expected.text == nil {
            // During migration, text + old full JSON is readable even if the process stops
            // before splitting JSON. Writing the stripped JSON first would lose that property.
            try PrivateFile.write(bytes, to: expected.textTarget, secureDirectory: false)
            do {
                try ensureUnchanged(Snapshot(textTarget: expected.textTarget, jsonTarget: expected.jsonTarget, text: bytes, json: expected.json))
                if json != expected.json { try PrivateFile.write(json, to: expected.jsonTarget, secureDirectory: false) }
            } catch {
                if resolvedTarget(textFile) == expected.textTarget,
                   (try? readConfigurationFile(expected.textTarget)) == bytes {
                    try? FileManager.default.removeItem(at: expected.textTarget)
                }
                throw error
            }
            snapshot = committed; loaded = configuration
            recordCompanion()
            return
        }
        let wroteJSON = json != expected.json
        if wroteJSON { try PrivateFile.write(json, to: expected.jsonTarget, secureDirectory: false) }
        do {
            // Without that write nothing has happened since the comparison above; repeating it
            // would only read both files again.
            if wroteJSON { try ensureUnchanged(Snapshot(textTarget: expected.textTarget, jsonTarget: expected.jsonTarget, text: expected.text, json: json)) }
            if bytes != expected.text { try PrivateFile.write(bytes, to: expected.textTarget, secureDirectory: false) }
        } catch {
            if wroteJSON, resolvedTarget(file) == expected.jsonTarget,
               (try? readConfigurationFile(expected.jsonTarget)) == json {
                if let prior = expected.json { try? PrivateFile.write(prior, to: expected.jsonTarget, secureDirectory: false) }
                else { try? FileManager.default.removeItem(at: expected.jsonTarget) }
            }
            throw error
        }
        snapshot = committed; loaded = configuration
        recordCompanion()
    }
}

public final class HistoryStore: Sendable {
    public let directory: URL
    private var file: URL { directory.appendingPathComponent("history.json") }
    /// Every change reads and writes the whole file, so it stays well below what `read` accepts.
    private static let maximumBytes = 48 * 1_024 * 1_024
    public init(directory: URL? = nil) { self.directory = directory ?? PrivateFile.defaultDirectory }

    public func load(preferences: Preferences) throws -> [HistoryEntry] {
        historyLock.lock(); defer { historyLock.unlock() }
        let entries = try read()
        let retained = bounded(entries, preferences: preferences)
        return entries == retained ? retained : try write(retained)
    }

    /// How many saved entries a change of the limits deletes. Reads the file and leaves it as it is.
    public func droppedCount(changing current: Preferences, to preferences: Preferences) throws -> Int {
        historyLock.lock(); defer { historyLock.unlock() }
        let entries = try read()
        return max(0, bounded(entries, preferences: current).count - bounded(entries, preferences: preferences).count)
    }

    /// Returns what is kept afterwards, as `load` would, or nil when history is off and nothing was saved.
    @discardableResult
    public func append(_ entry: HistoryEntry, preferences: Preferences) throws -> [HistoryEntry]? {
        historyLock.lock(); defer { historyLock.unlock() }
        guard preferences.historyEnabled else { return nil }
        var entries = try read().filter { $0.id != entry.id }
        entries.append(entry)
        return try write(bounded(entries, preferences: preferences))
    }

    /// A late transcription may update a retained entry, never recreate a deleted one.
    @discardableResult
    public func update(_ entry: HistoryEntry, preferences: Preferences) throws -> Bool {
        historyLock.lock(); defer { historyLock.unlock() }
        guard preferences.historyEnabled else { return false }
        var entries = bounded(try read(), preferences: preferences)
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return false }
        entries[index] = entry
        return try write(bounded(entries, preferences: preferences)).contains { $0.id == entry.id }
    }

    /// Returns what is kept afterwards. With preferences the rest is pruned as `load` would.
    @discardableResult
    public func delete(id: UUID, preferences: Preferences? = nil) throws -> [HistoryEntry] {
        historyLock.lock(); defer { historyLock.unlock() }
        let entries = try read()
        var retained = entries.filter { $0.id != id }
        if let preferences { retained = bounded(retained, preferences: preferences) }
        return retained == entries ? retained : try write(retained)
    }

    public func clear() throws {
        historyLock.lock(); defer { historyLock.unlock() }
        // Explicit deletion also permits recovery from a corrupt history file.
        if unlink(file.path) != 0 && errno != ENOENT { throw FrogError.message("Unable to clear history.") }
    }

    private func read() throws -> [HistoryEntry] {
        guard let data = try PrivateFile.read(file, maximumBytes: 64 * 1_024 * 1_024) else { return [] }
        return try PrivateFile.decode([HistoryEntry].self, from: data, name: "History")
    }

    /// Writes the entries, newest first, and returns the ones that fitted. The oldest are left out
    /// when the file would pass its limit, so long texts never stop newer history from being saved.
    private func write(_ entries: [HistoryEntry]) throws -> [HistoryEntry] {
        let encoder = JSONEncoder()
        var data = Data("[".utf8), kept = 0
        for entry in entries {
            let encoded = try encoder.encode(entry)
            // The newest entry is saved whatever its size.
            if kept > 0, data.count + encoded.count + 2 > Self.maximumBytes { break }
            if kept > 0 { data.append(UInt8(ascii: ",")) }
            data.append(encoded); kept += 1
        }
        data.append(UInt8(ascii: "]"))
        guard data.count <= 64 * 1_024 * 1_024 else { throw FrogError.message("History is too large to save. Reduce the history limit or clear history.") }
        try PrivateFile.write(data, to: file)
        return Array(entries.prefix(kept))
    }

    private func bounded(_ entries: [HistoryEntry], preferences: Preferences) -> [HistoryEntry] {
        let limit = min(200, max(1, preferences.historyLimit))
        let days = min(30, max(1, preferences.historyRetentionDays))
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var seen = Set<UUID>()
        return Array(entries.filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp == $1.timestamp ? $0.id.uuidString < $1.id.uuidString : $0.timestamp > $1.timestamp }
            .filter { seen.insert($0.id).inserted }.prefix(limit))
    }
}
