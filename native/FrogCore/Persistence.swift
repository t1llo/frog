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

    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              chmod(directory.path, 0o700) == 0 else {
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
    public var file: URL { directory.appendingPathComponent("config.json") }
    private let legacyFile: URL?
    public var hasExistingConfiguration: Bool {
        FileManager.default.fileExists(atPath: file.path) || legacyFile.map { FileManager.default.fileExists(atPath: $0.path) } == true
    }
    public init(directory: URL? = nil, legacyDirectory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/frog", isDirectory: true)
        let legacy = legacyDirectory ?? (directory == nil ? PrivateFile.defaultDirectory : directory)
        legacyFile = legacy?.appendingPathComponent("configuration.json")
    }

    public func load() throws -> Configuration {
        persistenceLock.lock(); defer { persistenceLock.unlock() }
        let data = try PrivateFile.read(file, maximumBytes: ConfigurationFile.maximumBytes)
        if data == nil || data.map(isPrototypeConfiguration) == true {
            guard let legacyFile, let previous = try PrivateFile.read(legacyFile, maximumBytes: ConfigurationFile.maximumBytes) else {
                if data != nil { throw FrogError.message("The file at \(file.path) belongs to an older Frog prototype. Import a native Frog configuration to replace it; the original file will be backed up.") }
                return Configuration()
            }
            let configuration = try PrivateFile.decode(Configuration.self, from: previous, name: "Previous configuration")
            try validate(configuration)
            if let data {
                try PrivateFile.write(data, to: directory.appendingPathComponent("config-prototype-backup-\(UUID().uuidString).json"))
            }
            try PrivateFile.write(try ConfigurationFile.encode(configuration), to: file)
            return configuration
        }
        guard let data else { return Configuration() }
        let configuration = try PrivateFile.decode(Configuration.self, from: data, name: "Configuration")
        try validate(configuration)
        return configuration
    }

    private func isPrototypeConfiguration(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return Set(object.keys) == Set(["globalHotkeys", "llm", "shortcuts", "textProcessing"])
    }

    public func save(_ configuration: Configuration) throws {
        persistenceLock.lock(); defer { persistenceLock.unlock() }
        // Never silently replace corrupt data or data from a newer application version.
        _ = try load()
        try validate(configuration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        guard data.count <= 4 * 1_024 * 1_024 else { throw FrogError.message("Configuration is too large to save.") }
        try PrivateFile.write(data, to: file)
    }

    /// Explicit import can recover unreadable settings without discarding the previous file.
    @discardableResult
    public func replaceFromImport(_ configuration: Configuration) throws -> URL? {
        persistenceLock.lock(); defer { persistenceLock.unlock() }
        let data = try ConfigurationFile.encode(configuration)
        var backup: URL?
        if let previous = try PrivateFile.read(file, maximumBytes: ConfigurationFile.maximumBytes) {
            let url = directory.appendingPathComponent("configuration-backup-\(UUID().uuidString).json")
            try PrivateFile.write(previous, to: url)
            backup = url
        }
        try PrivateFile.write(data, to: file)
        return backup
    }

    private func validate(_ configuration: Configuration) throws {
        guard configuration.version == 1 else { throw FrogError.message("Unsupported configuration version. The original file was preserved.") }
        guard Set(configuration.providers.map(\.id)).count == configuration.providers.count,
              Set(configuration.rules.map(\.id)).count == configuration.rules.count else {
            throw FrogError.message("Configuration contains duplicate identifiers. The original file was preserved.")
        }
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
