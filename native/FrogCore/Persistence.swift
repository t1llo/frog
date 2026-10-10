import Foundation
import Darwin

// Serializes read/modify/write transactions across store instances in this process.
private let persistenceLock = NSRecursiveLock()

private enum PrivateFile {
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

public final class ConfigurationStore: @unchecked Sendable {
    public let directory: URL
    /// Complex rules, connections and custom model definitions.
    public var file: URL { directory.appendingPathComponent("config.json") }
    public var textFile: URL { directory.appendingPathComponent("config") }
    private let legacyFile: URL?
    private struct Snapshot: Equatable {
        let textTarget: URL
        let jsonTarget: URL
        let text: Data?
        let json: Data?
    }
    private var snapshot: Snapshot?
    private var loaded: Configuration?
    public var hasExistingConfiguration: Bool {
        FileManager.default.fileExists(atPath: textFile.path) || FileManager.default.fileExists(atPath: file.path) || legacyFile.map { FileManager.default.fileExists(atPath: $0.path) } == true
    }
    public init(directory: URL? = nil, legacyDirectory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/frog", isDirectory: true)
        let legacy = legacyDirectory ?? (directory == nil ? PrivateFile.defaultDirectory : directory)
        legacyFile = legacy?.appendingPathComponent("configuration.json")
    }

    public func load(validating validate: ((Configuration) throws -> Void)? = nil) throws -> Configuration {
        persistenceLock.lock(); defer { persistenceLock.unlock() }
        let current = try readSnapshot()
        let configuration: Configuration
        if let text = current.text {
            if current.json == nil, snapshot?.json != nil {
                throw FrogError.message("config.json is missing. Restore the companion file before reloading; the current rules and connections were kept.")
            }
            guard let string = String(data: text, encoding: .utf8) else { throw FrogError.message("config must be UTF-8 text. The original file was preserved.") }
            configuration = try TextConfiguration.decode(string, companion: current.json ?? ConfigurationFile.encode(Configuration()))
        } else if let json = current.json, !isPrototypeConfiguration(json) {
            configuration = try ConfigurationFile.decode(json)
            try validate?(configuration)
            try backup(json, name: "config-legacy-backup", extension: "json")
            try commit(configuration, preserving: nil, expected: current)
            return configuration
        } else if let legacyFile, let previous = try readConfigurationFile(legacyFile) {
            configuration = try ConfigurationFile.decode(previous)
            try validate?(configuration)
            if let json = current.json { try backup(json, name: "config-prototype-backup", extension: "json") }
            try backup(previous, name: "config-legacy-backup", extension: "json")
            try commit(configuration, preserving: nil, expected: current)
            return configuration
        } else {
            if current.json != nil { throw FrogError.message("config.json belongs to an older Frog prototype. Import a native configuration in Settings; the original will be backed up.") }
            configuration = Configuration()
        }
        try validate?(configuration)
        snapshot = current; loaded = configuration
        return configuration
    }

    private func isPrototypeConfiguration(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return Set(object.keys) == Set(["globalHotkeys", "llm", "shortcuts", "textProcessing"])
    }

    public func save(_ configuration: Configuration) throws {
        persistenceLock.lock(); defer { persistenceLock.unlock() }
        if snapshot == nil { _ = try load() }
        guard let snapshot else { return }
        try ensureUnchanged(snapshot)
        var candidate = configuration
        // UI candidates retain extension fields from the last successfully loaded document.
        candidate.originalJSON = loaded?.originalJSON ?? candidate.originalJSON
        candidate.knownJSON = loaded?.knownJSON ?? candidate.knownJSON
        try commit(candidate, preserving: snapshot.text.flatMap { String(data: $0, encoding: .utf8) }, expected: snapshot)
    }

    /// Explicit import can recover unreadable settings without discarding the previous file.
    @discardableResult
    public func replaceFromImport(_ configuration: Configuration) throws -> URL? {
        persistenceLock.lock(); defer { persistenceLock.unlock() }
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
        return url
    }
    private func commit(_ configuration: Configuration, preserving text: String?, expected: Snapshot) throws {
        let json = try TextConfiguration.companion(configuration)
        let rendered = try TextConfiguration.render(configuration, preserving: text)
        let bytes = Data(rendered.utf8)
        let committed = Snapshot(textTarget: expected.textTarget, jsonTarget: expected.jsonTarget, text: bytes, json: json)
        guard bytes.count <= ConfigurationFile.maximumBytes, json.count <= ConfigurationFile.maximumBytes else { throw FrogError.message("Configuration is too large (maximum 4 MB per file).") }
        // Validate the actual representation before changing either file.
        _ = try TextConfiguration.decode(rendered, companion: json)
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
            return
        }
        if json != expected.json { try PrivateFile.write(json, to: expected.jsonTarget, secureDirectory: false) }
        do {
            try ensureUnchanged(Snapshot(textTarget: expected.textTarget, jsonTarget: expected.jsonTarget, text: expected.text, json: json))
            if bytes != expected.text { try PrivateFile.write(bytes, to: expected.textTarget, secureDirectory: false) }
        } catch {
            if json != expected.json, resolvedTarget(file) == expected.jsonTarget,
               (try? readConfigurationFile(expected.jsonTarget)) == json {
                if let prior = expected.json { try? PrivateFile.write(prior, to: expected.jsonTarget, secureDirectory: false) }
                else { try? FileManager.default.removeItem(at: expected.jsonTarget) }
            }
            throw error
        }
        snapshot = committed; loaded = configuration
    }
}

public final class HistoryStore: @unchecked Sendable {
    public let directory: URL
    private var file: URL { directory.appendingPathComponent("history.json") }
    public init(directory: URL? = nil) { self.directory = directory ?? PrivateFile.defaultDirectory }

    public func load(preferences: Preferences) throws -> [HistoryEntry] {
        persistenceLock.lock(); defer { persistenceLock.unlock() }
        let entries = try read()
        let retained = bounded(entries, preferences: preferences)
        if entries != retained { try write(retained) }
        return retained
    }

    public func append(_ entry: HistoryEntry, preferences: Preferences) throws {
        persistenceLock.lock(); defer { persistenceLock.unlock() }
        guard preferences.historyEnabled else { return }
        var entries = try read().filter { $0.id != entry.id }
        entries.append(entry)
        try write(bounded(entries, preferences: preferences))
    }

    /// A late transcription may update a retained entry, never recreate a deleted one.
    @discardableResult
    public func update(_ entry: HistoryEntry, preferences: Preferences) throws -> Bool {
        persistenceLock.lock(); defer { persistenceLock.unlock() }
        guard preferences.historyEnabled else { return false }
        var entries = bounded(try read(), preferences: preferences)
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return false }
        entries[index] = entry
        try write(bounded(entries, preferences: preferences))
        return true
    }

    public func delete(id: UUID) throws {
        persistenceLock.lock(); defer { persistenceLock.unlock() }
        let entries = try read()
        let retained = entries.filter { $0.id != id }
        if retained != entries { try write(retained) }
    }

    public func clear() throws {
        persistenceLock.lock(); defer { persistenceLock.unlock() }
        // Explicit deletion also permits recovery from a corrupt history file.
        if unlink(file.path) != 0 && errno != ENOENT { throw FrogError.message("Unable to clear history.") }
    }

    private func read() throws -> [HistoryEntry] {
        guard let data = try PrivateFile.read(file, maximumBytes: 64 * 1_024 * 1_024) else { return [] }
        return try PrivateFile.decode([HistoryEntry].self, from: data, name: "History")
    }

    private func write(_ entries: [HistoryEntry]) throws {
        let data = try JSONEncoder().encode(entries)
        guard data.count <= 64 * 1_024 * 1_024 else { throw FrogError.message("History is too large to save. Reduce the history limit or clear history.") }
        try PrivateFile.write(data, to: file)
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
