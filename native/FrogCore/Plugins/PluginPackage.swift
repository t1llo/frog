import CryptoKit
import Darwin
import Foundation

/// The access a plugin asks for, or the access the user approved: its permissions, its hosts, and the
/// SHA-256 of each script the user could read.
public struct PluginGrant: Codable, Equatable, Sendable {
    public var permissions: [PluginPermission]
    public var hosts: [String]
    public var scripts: [String: String]

    public init(permissions: [PluginPermission] = [], hosts: [String] = [], scripts: [String: String] = [:]) {
        self.permissions = permissions.sorted(); self.hosts = hosts.sorted(); self.scripts = scripts
    }

    /// Whether everything `requested` asks for was approved here: no new permission or host, and every
    /// script unchanged.
    public func covers(_ requested: PluginGrant) -> Bool {
        Set(requested.permissions).isSubset(of: permissions) && Set(requested.hosts).isSubset(of: hosts)
            && requested.scripts.allSatisfy { scripts[$0.key] == $0.value }
    }

    /// What `requested` asks for beyond this grant, for the review sheet.
    public func additions(in requested: PluginGrant) -> (permissions: [PluginPermission], hosts: [String], scripts: [String]) {
        (requested.permissions.filter { !permissions.contains($0) }, requested.hosts.filter { !hosts.contains($0) },
         requested.scripts.filter { scripts[$0.key] != $0.value }.keys.sorted())
    }
}

/// A plugin's files as read from a folder: the manifest, every file it ships, and its scripts' hashes.
public struct PluginPackage: Sendable {
    public struct File: Equatable, Sendable {
        public let path: String
        public let size: Int
    }

    public static let maximumFiles = 400
    public static let maximumBytes = 20 * 1024 * 1024
    static let maximumManifestBytes = 64 * 1024
    static let maximumScriptBytes = 100_000
    static let maximumDepth = 12

    public let root: URL
    public let manifest: PluginManifest
    /// Relative paths, sorted. Hidden files and folders are left out.
    public let files: [File]
    public let scriptHashes: [String: String]

    public var size: Int { files.reduce(0) { $0 + $1.size } }
    public var grant: PluginGrant { manifest.grant(scriptHashes: scriptHashes) }

    /// Reads and checks the plugin in `folder`.
    public static func read(_ folder: URL) throws -> PluginPackage {
        let root = folder.standardizedFileURL
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw PluginError.invalid("\(root.path) is not a folder.")
        }
        var files: [File] = []
        try collect(root, prefix: "", depth: 0, into: &files)
        files.sort { $0.path < $1.path }
        guard files.contains(where: { $0.path == PluginManifest.fileName }) else {
            throw PluginError.invalid("The folder has no plugin.json.")
        }
        let manifestData = try readFile(root.appendingPathComponent(PluginManifest.fileName), maximumBytes: maximumManifestBytes)
        let manifest = try PluginManifest.decode(manifestData)
        let paths = Set(files.map(\.path))
        if let entry = manifest.entry, !paths.contains(entry) {
            throw PluginError.invalid("The entry page “\(entry)” is not in the folder.")
        }
        var hashes: [String: String] = [:]
        for (name, path) in manifest.scripts {
            guard paths.contains(path) else { throw PluginError.invalid("The script “\(name)” at \(path) is not in the folder.") }
            let data = try readFile(root.appendingPathComponent(path), maximumBytes: maximumScriptBytes)
            guard String(data: data, encoding: .utf8) != nil, !data.contains(0) else {
                throw PluginError.invalid("The script “\(name)” must be UTF-8 text.")
            }
            hashes[name] = sha256(data)
        }
        return PluginPackage(root: root, manifest: manifest, files: files, scriptHashes: hashes)
    }

    /// The text of one of the plugin's scripts, for the review sheet and for running it.
    public func scriptText(_ name: String) throws -> String {
        guard let path = manifest.scripts[name] else { throw PluginError.invalid("The plugin has no script named “\(name)”.") }
        let data = try Self.readFile(root.appendingPathComponent(path), maximumBytes: Self.maximumScriptBytes)
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads a regular file without following a symbolic link.
    public static func readFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw PluginError.invalid("Unable to read \(url.lastPathComponent).") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw PluginError.invalid("\(url.lastPathComponent) is not a regular file.")
        }
        guard info.st_size <= maximumBytes else { throw PluginError.invalid("\(url.lastPathComponent) is too large.") }
        var data = Data(capacity: Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw PluginError.invalid("Unable to read \(url.lastPathComponent).") }
            if count == 0 { break }
            guard data.count + count <= maximumBytes else { throw PluginError.invalid("\(url.lastPathComponent) is too large.") }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func collect(_ folder: URL, prefix: String, depth: Int, into files: inout [File]) throws {
        guard depth <= maximumDepth else { throw PluginError.invalid("The plugin's folders are nested too deeply.") }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        for name in names.sorted() where !name.hasPrefix(".") {
            let path = prefix + name
            guard PluginPath.isSafe(path) else { throw PluginError.invalid("“\(path)” is not a name a plugin file can have.") }
            let url = folder.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw PluginError.invalid("Unable to read \(path).") }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: try collect(url, prefix: path + "/", depth: depth + 1, into: &files)
            case S_IFREG:
                files.append(File(path: path, size: Int(info.st_size)))
                guard files.count <= maximumFiles else { throw PluginError.invalid("A plugin can have at most \(maximumFiles) files.") }
                guard files.reduce(0, { $0 + $1.size }) <= maximumBytes else { throw PluginError.invalid("A plugin can be at most 20 MB.") }
            case S_IFLNK: throw PluginError.invalid("“\(path)” is a symbolic link. Plugins cannot contain links.")
            default: throw PluginError.invalid("“\(path)” is not a regular file.")
            }
        }
    }
}
