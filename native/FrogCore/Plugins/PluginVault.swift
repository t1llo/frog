import Foundation
import Security

/// Where a plugin's secret settings are kept: the login Keychain in the app, memory in tests. Each plugin reads only
/// its own; removing the plugin deletes them.
public protocol PluginSecretStore: Sendable {
    func read(_ key: String, plugin: String) throws -> String?
    func save(_ value: String, key: String, plugin: String) throws
    func delete(_ key: String, plugin: String) throws
    /// Deletes every secret of the plugin.
    func deleteAll(plugin: String) throws
}

public final class PluginKeychain: PluginSecretStore {
    private let service = "com.frog.plugin-secrets"
    public init() {}

    public func read(_ key: String, plugin: String) throws -> String? {
        var query = identity(key, plugin: plugin)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStore.failure(status) }
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func save(_ value: String, key: String, plugin: String) throws {
        let query = identity(key, plugin: plugin)
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Frog plugin \(plugin)"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainStore.failure(status) }
    }

    public func delete(_ key: String, plugin: String) throws {
        let status = SecItemDelete(identity(key, plugin: plugin) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainStore.failure(status) }
    }

    public func deleteAll(plugin: String) throws {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else { throw KeychainStore.failure(status) }
        query = [:]
        let prefix = plugin + "/"
        for item in result as? [[String: Any]] ?? [] {
            guard let account = item[kSecAttrAccount as String] as? String, account.hasPrefix(prefix) else { continue }
            try delete(String(account.dropFirst(prefix.count)), plugin: plugin)
        }
    }

    /// Plugin ids have no slash, so `<plugin>/<key>` names one setting of one plugin.
    private func identity(_ key: String, plugin: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "\(plugin)/\(key)", kSecAttrSynchronizable as String: false]
    }
}

/// Secrets in memory, for tests.
public final class MemoryPluginSecrets: PluginSecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func read(_ key: String, plugin: String) throws -> String? { lock.withLock { values["\(plugin)/\(key)"] } }
    public func save(_ value: String, key: String, plugin: String) throws { lock.withLock { values["\(plugin)/\(key)"] = value } }
    public func delete(_ key: String, plugin: String) throws { lock.withLock { values["\(plugin)/\(key)"] = nil } }
    public func deleteAll(plugin: String) throws { lock.withLock { values = values.filter { !$0.key.hasPrefix(plugin + "/") } } }
    public var count: Int { lock.withLock { values.count } }
}

/// The folders the user picked for a plugin with the files permission, kept in `folders.json` in its data folder.
/// The plugin names a folder by its id and a path inside it; nothing outside the folders resolves.
public final class PluginFolders: @unchecked Sendable {
    public struct Folder: Codable, Equatable, Sendable {
        public let id: String
        public let path: String
        public var name: String { (path as NSString).lastPathComponent }
    }

    public static let maximumFolders = 20
    public let file: URL
    private let lock = NSLock()

    public init(folder: URL) { file = folder.appendingPathComponent("folders.json") }

    public func list() throws -> [Folder] {
        lock.lock(); defer { lock.unlock() }
        return try read()
    }

    /// Adds a folder the user picked, or returns the one already kept for it.
    @discardableResult
    public func add(_ url: URL) throws -> Folder {
        lock.lock(); defer { lock.unlock() }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        var folders = try read()
        if let existing = folders.first(where: { $0.path == path }) { return existing }
        guard folders.count < Self.maximumFolders else { throw PluginError.invalid("A plugin can keep at most \(Self.maximumFolders) folders. Remove one in its settings first.") }
        let folder = Folder(id: String(UUID().uuidString.prefix(8)).lowercased(), path: path)
        folders.append(folder)
        try write(folders)
        return folder
    }

    public func remove(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try write(try read().filter { $0.id != id })
    }

    /// The file or folder at `path` inside the kept folder `id`: a relative path without `..` or hidden names, which
    /// after following links still lies inside the folder. An empty path is the folder itself.
    public func resolve(_ id: String, _ path: String) throws -> URL {
        guard let folder = try list().first(where: { $0.id == id }) else {
            throw PluginError.invalid("The plugin has no folder “\(id)”. Ask the user to pick one with frog.files.pick.")
        }
        let root = URL(fileURLWithPath: folder.path, isDirectory: true)
        guard !path.isEmpty else { return root }
        guard PluginPath.isSafe(path) else { throw PluginError.invalid("“\(path)” must be a path inside the folder, without .. or hidden names.") }
        let target = root.appendingPathComponent(path).standardizedFileURL
        // A link inside the folder may point anywhere; what it leads to must be inside too. A file still to be written
        // is checked by the folder it goes in.
        var existing = target
        while !FileManager.default.fileExists(atPath: existing.path), existing.path.count > root.path.count {
            existing = existing.deletingLastPathComponent()
        }
        let resolved = existing.resolvingSymlinksInPath().path
        guard resolved == root.path || resolved.hasPrefix(root.path + "/") else {
            throw PluginError.invalid("“\(path)” leads outside the folder.")
        }
        return target
    }

    private func read() throws -> [Folder] {
        guard let data = try PrivateFile.read(file, maximumBytes: 256 * 1024) else { return [] }
        return try PrivateFile.decode([Folder].self, from: data, name: "The plugin's folders")
    }

    private func write(_ folders: [Folder]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try PrivateFile.write(JSONEncoder().encode(folders), to: file)
    }
}
