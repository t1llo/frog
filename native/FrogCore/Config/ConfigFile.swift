import CryptoKit
import Darwin
import Foundation

/// What a version of config.toml on disk looked like. Two reads with the same fingerprint saw the same file.
struct ConfigFingerprint: Equatable, Sendable {
    var size: Int64
    var modifiedSeconds: Int
    var modifiedNanoseconds: Int
    var sha256: Data
}

/// Reads and writes config.toml: regular files of at most 4 MB, replaced atomically with mode 0600.
enum ConfigFile {
    static let maximumBytes = 4 * 1_024 * 1_024

    /// Symlinks (a dotfiles manager's, say) are followed, and the file they point at is replaced.
    static func target(_ url: URL) -> URL { url.resolvingSymlinksInPath() }

    /// Nil when there is no file.
    static func read(_ url: URL) throws -> (data: Data, fingerprint: ConfigFingerprint)? {
        let path = target(url).path
        let name = url.lastPathComponent
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw ConfigError(.file, "\(name) could not be read (\(String(cString: strerror(errno))))")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ConfigError(.file, "\(name) could not be read") }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw ConfigError(.file, "\(name) is not a regular file") }
        guard info.st_size <= maximumBytes else { throw ConfigError(.file, "\(name) is larger than 4 MB") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw ConfigError(.file, "\(name) could not be read")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw ConfigError(.file, "\(name) is larger than 4 MB") }
        }
        let fingerprint = ConfigFingerprint(size: Int64(info.st_size), modifiedSeconds: info.st_mtimespec.tv_sec,
                                            modifiedNanoseconds: info.st_mtimespec.tv_nsec, sha256: Data(SHA256.hash(data: data)))
        return (data, fingerprint)
    }

    /// Writes beside the file and renames over it, so readers see the old or the new file, never
    /// half of one. A missing folder is created with mode 0700; an existing one is left as it is,
    /// since a dotfiles folder may be shared with other tools. Returns the fingerprint of what landed.
    @discardableResult
    static func write(_ data: Data, to url: URL) throws -> ConfigFingerprint? {
        guard data.count <= maximumBytes else { throw ConfigError(.file, "\(url.lastPathComponent) would be larger than 4 MB; nothing was saved") }
        let destination = target(url)
        let directory = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                throw ConfigError(.file, "\(directory.path) could not be created: \(error.localizedDescription)")
            }
        }
        do { try PrivateFile.write(data, to: destination, secureDirectory: false) }
        catch { throw ConfigError(.file, "\(url.lastPathComponent) could not be saved: \(error.localizedDescription)") }
        return try read(destination)?.fingerprint
    }
}
