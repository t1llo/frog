import Darwin
import Foundation

/// Where an installed plugin came from.
public enum PluginSource: Codable, Equatable, Sendable {
    /// A folder on this Mac, such as one an AI agent is building it in.
    case folder(String)
    /// A `.frogplugin` file downloaded from a link.
    case link(String)
    /// A `.frogplugin` file on this Mac.
    case file(String)

    public var label: String {
        switch self {
        case .folder(let path), .file(let path): (path as NSString).abbreviatingWithTildeInPath
        case .link(let url): URL(string: url)?.host ?? url
        }
    }

    /// Whether a plugin from `other` comes from the same place, so it may keep what the user approved for this one.
    /// Links share a place when they share the host and the first folder, such as github.com/jane. A file
    /// chosen on this Mac shares none, since anyone can make a file with any plugin's id.
    public func sharesOrigin(with other: PluginSource) -> Bool {
        switch (self, other) {
        case (.folder(let a), .folder(let b)): return a == b
        case (.link(let a), .link(let b)):
            guard let a = URL(string: a), let b = URL(string: b), let host = a.host?.lowercased(), host == b.host?.lowercased() else { return false }
            return a.pathComponents.dropFirst().first == b.pathComponents.dropFirst().first
        default: return false
        }
    }
}

/// What Frog keeps about an installed plugin besides its files.
public struct PluginRecord: Codable, Equatable, Sendable {
    public var id: String
    /// Off when the user turned it off. A plugin whose update asks for more stays on but waits for review.
    public var enabled: Bool
    /// What the user approved; nil until they review it the first time.
    public var approved: PluginGrant?
    public var source: PluginSource
    /// The SHA-256 of the `.frogplugin` file it came from, when it came from one.
    public var sha256: String?
    public var installed: Date
    public var updated: Date
}

/// Installed plugins, under `<Frog data>/Plugins`: `Installed/<id>/` holds each plugin's files,
/// `Data/<id>/` what it stores, and `plugins.json` the records. Only Frog writes here; the plugins'
/// pages read their own files through Frog and never see these folders.
public final class PluginStore: @unchecked Sendable {
    public let directory: URL
    public var installedDirectory: URL { directory.appendingPathComponent("Installed", isDirectory: true) }
    public var dataDirectory: URL { directory.appendingPathComponent("Data", isDirectory: true) }
    var registryFile: URL { directory.appendingPathComponent("plugins.json") }
    private let lock = NSRecursiveLock()

    public init(directory: URL? = nil) {
        self.directory = directory ?? PrivateFile.defaultDirectory.appendingPathComponent("Plugins", isDirectory: true)
    }

    public func folder(for id: String) -> URL { installedDirectory.appendingPathComponent(id, isDirectory: true) }
    public func dataFolder(for id: String) -> URL { dataDirectory.appendingPathComponent(id, isDirectory: true) }

    // MARK: Records

    private struct Registry: Codable {
        var version = 1
        var plugins: [PluginRecord] = []
    }

    public func records() throws -> [PluginRecord] {
        lock.lock(); defer { lock.unlock() }
        return try readRegistry().plugins
    }

    public func record(_ id: String) throws -> PluginRecord? { try records().first { $0.id == id } }

    private func readRegistry() throws -> Registry {
        guard let data = try PrivateFile.read(registryFile, maximumBytes: 2 * 1024 * 1024) else { return Registry() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(Registry.self, from: data) }
        catch { throw FrogError.message("plugins.json could not be decoded. Move it aside to start the plugin list afresh.") }
    }

    private func change(_ change: (inout Registry) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var registry = try readRegistry()
        try change(&registry)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try PrivateFile.write(try encoder.encode(registry), to: registryFile)
    }

    // MARK: Installing

    /// The installed copy of a plugin, read and checked again.
    public func package(_ id: String) throws -> PluginPackage {
        guard PluginManifest.isValidID(id) else { throw PluginError.invalid("“\(id)” is not a plugin id.") }
        let package = try PluginPackage.read(folder(for: id))
        guard package.manifest.id == id else { throw PluginError.invalid("The installed plugin “\(id)” names another id.") }
        return package
    }

    /// Copies the plugin's files in, replacing an earlier version. A plugin installed for the first time
    /// waits for review unless `approving`; an update keeps what was approved, so it runs at once when it
    /// asks for nothing new.
    @discardableResult
    public func install(_ package: PluginPackage, source: PluginSource, sha256: String? = nil, approving: Bool = false, now: Date = Date()) throws -> PluginRecord {
        let id = package.manifest.id
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: installedDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = installedDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        for file in package.files {
            let data = try PluginPackage.readFile(package.root.appendingPathComponent(file.path), maximumBytes: PluginPackage.maximumBytes)
            let target = staging.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: target.path, contents: data, attributes: [.posixPermissions: 0o644]) else {
                throw PluginError.invalid("Unable to copy \(file.path).")
            }
        }
        // The copy is read back, so what runs is what was checked.
        let installed = try PluginPackage.read(staging)
        guard installed.manifest == package.manifest, installed.scriptHashes == package.scriptHashes else {
            throw PluginError.invalid("The plugin changed while it was being installed. Try again.")
        }

        let target = folder(for: id)
        let previous = installedDirectory.appendingPathComponent(".previous-\(UUID().uuidString)", isDirectory: true)
        let replacing = FileManager.default.fileExists(atPath: target.path)
        if replacing { try FileManager.default.moveItem(at: target, to: previous) }
        do { try FileManager.default.moveItem(at: staging, to: target) }
        catch {
            if replacing { try? FileManager.default.moveItem(at: previous, to: target) }
            throw error
        }
        if replacing { try? FileManager.default.removeItem(at: previous) }

        var result: PluginRecord!
        try change { registry in
            if let index = registry.plugins.firstIndex(where: { $0.id == id }) {
                var record = registry.plugins[index]
                // Code from somewhere else gets none of the approval the installed plugin had.
                if !record.source.sharesOrigin(with: source) { record.approved = nil }
                record.source = source; record.sha256 = sha256; record.updated = now
                if approving { record.approved = package.grant; record.enabled = true }
                registry.plugins[index] = record
                result = record
            } else {
                let record = PluginRecord(id: id, enabled: approving, approved: approving ? package.grant : nil,
                                          source: source, sha256: sha256, installed: now, updated: now)
                registry.plugins.append(record)
                result = record
            }
        }
        return result
    }

    /// Records the user's approval of what the installed copy asks for, and turns it on. `expecting` is what the
    /// user reviewed; a plugin that asks for anything else by now is refused, so an approval never covers more
    /// than was shown.
    public func approve(_ id: String, expecting reviewed: PluginGrant? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let grant = try package(id).grant
        if let reviewed, grant != reviewed { throw PluginError.invalid("The plugin changed while you reviewed it. Review it again.") }
        try change { registry in
            guard let index = registry.plugins.firstIndex(where: { $0.id == id }) else { throw PluginError.invalid("No plugin “\(id)” is installed.") }
            registry.plugins[index].approved = grant
            registry.plugins[index].enabled = true
        }
    }

    public func setEnabled(_ id: String, _ enabled: Bool) throws {
        try change { registry in
            guard let index = registry.plugins.firstIndex(where: { $0.id == id }) else { throw PluginError.invalid("No plugin “\(id)” is installed.") }
            guard !enabled || registry.plugins[index].approved != nil else { throw PluginError.invalid("Review the plugin before turning it on.") }
            registry.plugins[index].enabled = enabled
        }
    }

    /// Moves the plugin and what it stored to the Trash.
    public func remove(_ id: String, trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        guard PluginManifest.isValidID(id) else { throw PluginError.invalid("“\(id)” is not a plugin id.") }
        lock.lock(); defer { lock.unlock() }
        for url in [folder(for: id), dataFolder(for: id)] where FileManager.default.fileExists(atPath: url.path) {
            try trash(url)
        }
        try change { $0.plugins.removeAll { $0.id == id } }
    }

    // MARK: Archives

    /// Unpacks a `.frogplugin` file into a new folder under `staging` and reads it, without installing it.
    public func unpack(_ archive: Data, in staging: URL) throws -> PluginPackage {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folder = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try PluginArchive.extract(archive, to: folder)
        return try PluginPackage.read(folder)
    }
}

/// A plugin's own storage: string keys mapped to JSON text, at most 5 MB in all.
public final class PluginStorage: @unchecked Sendable {
    public static let maximumBytes = 5 * 1024 * 1024
    public let file: URL
    private var values: [String: String]?
    private let lock = NSLock()

    public init(folder: URL) { file = folder.appendingPathComponent("storage.json") }

    private func loaded() throws -> [String: String] {
        if let values { return values }
        let data = try PrivateFile.read(file, maximumBytes: Self.maximumBytes + 1024 * 1024)
        let read = try data.map { try PrivateFile.decode([String: String].self, from: $0, name: "The plugin's storage") } ?? [:]
        values = read
        return read
    }

    public func get(_ key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return try loaded()[key]
    }

    public func keys() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return try loaded().keys.sorted()
    }

    /// Stores `json`, the JSON text of a value; nil removes the key.
    public func set(_ key: String, json: String?) throws {
        lock.lock(); defer { lock.unlock() }
        guard !key.isEmpty, key.count <= 200 else { throw PluginError.invalid("A storage key must be 1 to 200 characters.") }
        let current = try loaded()
        var next = current
        next[key] = json
        guard next != current else { return }
        // The limit counts the file as written, escapes included, so it always reads back.
        let data = try JSONEncoder().encode(next)
        guard data.count <= Self.maximumBytes else { throw PluginError.invalid("The plugin's storage is full: it can keep 5 MB.") }
        try PrivateFile.write(data, to: file)
        values = next
    }
}
