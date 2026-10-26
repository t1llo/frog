import Compression
import Darwin
import Foundation

/// `.frogplugin` files: zip archives of a plugin's folder. Frog reads them itself rather than with a
/// system tool, so nothing in an archive is written anywhere but the folder it is unpacked into: no
/// absolute or `..` paths, no links, no encrypted entries, and limits on files and size.
public enum PluginArchive {
    public static let fileExtension = "frogplugin"
    /// The largest archive Frog downloads or opens.
    public static let maximumArchiveBytes = 25 * 1024 * 1024

    // MARK: Reading

    /// Unpacks `data` into `destination`, which must not exist yet. An archive whose files sit in one
    /// top-level folder, as zipping a folder makes it, is unpacked from inside that folder.
    public static func extract(_ data: Data, to destination: URL) throws {
        guard data.count <= maximumArchiveBytes else { throw PluginError.invalid("The plugin file is larger than 25 MB.") }
        let entries = try centralDirectory(data)
        var files = entries.filter { !$0.isDirectory && !$0.isHidden }
        guard !files.isEmpty else { throw PluginError.invalid("The plugin file is empty.") }
        // One shared top-level folder is dropped.
        if !files.contains(where: { $0.path == PluginManifest.fileName }) {
            let tops = Set(files.map { $0.path.split(separator: "/").first.map(String.init) ?? "" })
            guard tops.count == 1, let top = tops.first, files.allSatisfy({ $0.path.hasPrefix(top + "/") }),
                  files.contains(where: { $0.path == top + "/" + PluginManifest.fileName }) else {
                throw PluginError.invalid("The plugin file has no plugin.json.")
            }
            files = files.map { var entry = $0; entry.path.removeFirst(top.count + 1); return entry }
        }
        guard files.count <= PluginPackage.maximumFiles else { throw PluginError.invalid("A plugin can have at most \(PluginPackage.maximumFiles) files.") }
        guard files.reduce(0, { $0 + $1.size }) <= PluginPackage.maximumBytes else { throw PluginError.invalid("A plugin can be at most 20 MB.") }
        guard Set(files.map { $0.path.lowercased() }).count == files.count else { throw PluginError.invalid("The plugin file lists a file twice.") }

        // Every entry is read and checked before anything is written.
        let contents = try files.map { try $0.contents(in: data) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        for (entry, contents) in zip(files, contents) {
            let url = destination.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try writeNew(contents, to: url)
        }
    }

    struct Entry {
        var path: String
        let isDirectory: Bool
        let isHidden: Bool
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let size: Int
        let localHeader: Int

        func contents(in archive: Data) throws -> Data {
            let bytes = Bytes(archive)
            guard try bytes.uint32(localHeader) == 0x0403_4b50 else { throw PluginArchive.damaged }
            let start = localHeader + 30 + Int(try bytes.uint16(localHeader + 26)) + Int(try bytes.uint16(localHeader + 28))
            guard start >= 0, compressedSize >= 0, start + compressedSize <= archive.count else { throw PluginArchive.damaged }
            let compressed = archive.subdata(in: archive.startIndex + start ..< archive.startIndex + start + compressedSize)
            let output: Data
            switch method {
            case 0:
                guard compressedSize == size else { throw PluginArchive.damaged }
                output = compressed
            case 8:
                output = try PluginArchive.inflate(compressed, size: size)
            default:
                throw PluginError.invalid("The plugin file uses a kind of compression Frog does not read.")
            }
            guard CRC32.checksum(output) == crc else { throw PluginArchive.damaged }
            return output
        }
    }

    static var damaged: PluginError { .invalid("The plugin file is damaged.") }

    static func centralDirectory(_ data: Data) throws -> [Entry] {
        let bytes = Bytes(data)
        // The end-of-central-directory record is in the last 22 bytes plus a comment of up to 65,535.
        guard data.count >= 22 else { throw damaged }
        var end = -1
        var position = data.count - 22
        let lowest = max(0, data.count - 22 - 65_535)
        while position >= lowest {
            if try bytes.uint32(position) == 0x0605_4b50 { end = position; break }
            position -= 1
        }
        guard end >= 0 else { throw PluginError.invalid("The plugin file is not a zip archive.") }
        let count = Int(try bytes.uint16(end + 10))
        let directorySize = Int(try bytes.uint32(end + 12))
        let directoryOffset = Int(try bytes.uint32(end + 16))
        guard try bytes.uint16(end + 4) == 0, try bytes.uint16(end + 6) == 0 else {
            throw PluginError.invalid("Archives split across several files are not supported.")
        }
        guard count != 0xFFFF, directoryOffset != 0xFFFF_FFFF else { throw PluginError.invalid("ZIP64 archives are not supported.") }
        guard count <= PluginPackage.maximumFiles * 4, directoryOffset + directorySize <= end else { throw damaged }

        var entries: [Entry] = []
        var offset = directoryOffset
        for _ in 0..<count {
            guard try bytes.uint32(offset) == 0x0201_4b50 else { throw damaged }
            let madeBy = try bytes.uint16(offset + 4)
            let flags = try bytes.uint16(offset + 8)
            let method = try bytes.uint16(offset + 10)
            let crc = try bytes.uint32(offset + 16)
            let compressedSize = Int(try bytes.uint32(offset + 20))
            let size = Int(try bytes.uint32(offset + 24))
            let nameLength = Int(try bytes.uint16(offset + 28))
            let extraLength = Int(try bytes.uint16(offset + 30))
            let commentLength = Int(try bytes.uint16(offset + 32))
            let external = try bytes.uint32(offset + 38)
            let localHeader = Int(try bytes.uint32(offset + 42))
            guard offset + 46 + nameLength <= data.count else { throw damaged }
            let nameData = data.subdata(in: data.startIndex + offset + 46 ..< data.startIndex + offset + 46 + nameLength)
            offset += 46 + nameLength + extraLength + commentLength

            guard flags & 0x1 == 0 else { throw PluginError.invalid("The plugin file is encrypted.") }
            guard let name = String(data: nameData, encoding: .utf8) else { throw PluginError.invalid("The plugin file has a name Frog cannot read.") }
            guard compressedSize != 0xFFFF_FFFF, size != 0xFFFF_FFFF, localHeader != 0xFFFF_FFFF else {
                throw PluginError.invalid("ZIP64 archives are not supported.")
            }
            // A Unix-made entry carries its file type; a link is never unpacked.
            if madeBy >> 8 == 3, (external >> 16) & 0o170000 == 0o120000 {
                throw PluginError.invalid("“\(name)” is a symbolic link. Plugins cannot contain links.")
            }
            let isDirectory = name.hasSuffix("/")
            let path = isDirectory ? String(name.dropLast()) : name
            if path.isEmpty, isDirectory { continue }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            // macOS adds __MACOSX/ and ._ files for resource forks; they and other hidden names are skipped.
            let isHidden = parts.contains { $0.hasPrefix(".") && $0 != "." && $0 != ".." } || parts.first == "__MACOSX"
            if !isHidden {
                guard PluginPath.isSafe(path) else { throw PluginError.invalid("The plugin file contains an unsafe path: \(name)") }
            }
            entries.append(Entry(path: path, isDirectory: isDirectory, isHidden: isHidden, method: method, crc: crc,
                                 compressedSize: compressedSize, size: size, localHeader: localHeader))
        }
        return entries
    }

    static func inflate(_ data: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, size,
                                          source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw damaged }
        return output
    }

    private static func writeNew(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else { throw PluginError.invalid("Unable to write \(url.lastPathComponent).") }
        defer { close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw PluginError.invalid("Unable to write \(url.lastPathComponent).") }
                offset += count
            }
        }
    }

    // MARK: Writing

    /// A zip of the package's files, the same bytes for the same files.
    public static func create(_ package: PluginPackage) throws -> Data {
        var archive = Data()
        var directory = Data()
        for file in package.files {
            let contents = try PluginPackage.readFile(package.root.appendingPathComponent(file.path), maximumBytes: PluginPackage.maximumBytes)
            let crc = CRC32.checksum(contents)
            let deflated = deflate(contents)
            let method: UInt16 = deflated.map { $0.count < contents.count } == true ? 8 : 0
            let stored = method == 8 ? deflated! : contents
            let name = Data(file.path.utf8)
            let offset = archive.count
            guard offset <= Int(UInt32.max) else { throw PluginError.invalid("The plugin is too large to pack.") }

            var local = Data()
            local.append32(0x0403_4b50); local.append16(20); local.append16(0x0800); local.append16(method)
            local.append16(0); local.append16(0x21) // 1980-01-01, 00:00
            local.append32(crc); local.append32(UInt32(stored.count)); local.append32(UInt32(contents.count))
            local.append16(UInt16(name.count)); local.append16(0)
            archive.append(local); archive.append(name); archive.append(stored)

            var entry = Data()
            entry.append32(0x0201_4b50); entry.append16(0x0314); entry.append16(20); entry.append16(0x0800); entry.append16(method)
            entry.append16(0); entry.append16(0x21)
            entry.append32(crc); entry.append32(UInt32(stored.count)); entry.append32(UInt32(contents.count))
            entry.append16(UInt16(name.count)); entry.append16(0); entry.append16(0); entry.append16(0); entry.append16(0)
            entry.append32(UInt32(0o100644) << 16); entry.append32(UInt32(offset))
            directory.append(entry); directory.append(name)
        }
        let directoryOffset = archive.count
        archive.append(directory)
        var end = Data()
        end.append32(0x0605_4b50); end.append16(0); end.append16(0)
        end.append16(UInt16(package.files.count)); end.append16(UInt16(package.files.count))
        end.append32(UInt32(directory.count)); end.append32(UInt32(directoryOffset)); end.append16(0)
        archive.append(end)
        return archive
    }

    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }
}

/// Little-endian reads that fail instead of reading past the end.
private struct Bytes {
    let data: Data
    init(_ data: Data) { self.data = data }
    func uint16(_ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { throw PluginArchive.damaged }
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }
    func uint32(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw PluginArchive.damaged }
        let base = data.startIndex + offset
        return UInt32(data[base]) | UInt32(data[base + 1]) << 8 | UInt32(data[base + 2]) << 16 | UInt32(data[base + 3]) << 24
    }
}

private extension Data {
    mutating func append16(_ value: UInt16) { append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)]) }
    mutating func append32(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((value >> UInt32(shift)) & 0xFF)) } }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
