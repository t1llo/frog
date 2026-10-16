import Foundation
import Darwin

/// What an item takes on disk, as far as Frog could read it.
public struct CleanerSize: Sendable, Equatable, Codable {
    public var bytes: Int64
    /// False when something was unreadable (EPERM, EACCES), dataless, or the walk was cancelled or cut short.
    public var complete: Bool
    /// Newest `st_mtimespec` of the item and every entry below it; nil unless dates were asked for.
    /// A folder's own date changes only when its direct children change, so callers that judge age
    /// (leftovers, junk) must use this, never the item's own date.
    public var newest: Date? = nil

    public init(bytes: Int64, complete: Bool, newest: Date? = nil) {
        self.bytes = bytes
        self.complete = complete
        self.newest = newest
    }
}

/// Measures allocated bytes without following links, without leaving the volume, without downloading iCloud
/// placeholders, and counting hard links and APFS clones once. Synchronous on purpose: the I/O policy that
/// keeps placeholders on the server is per thread, so callers run it inside `Task.detached(priority: .utility)`.
public struct CleanerSizer: Sendable {
    public let maximumEntries: Int
    /// `st_flags` as the walk sees them; tests mark entries dataless, since a real placeholder cannot be made.
    let entryFlags: @Sendable (_ path: String, _ flags: UInt32) -> UInt32
    /// The APFS content identifier of a large regular file; tests stand in for clones, which cannot be made
    /// reliably in a temporary folder.
    let contentIdentifier: @Sendable (_ path: String) -> Int64?

    public init(maximumEntries: Int = 2_000_000) {
        self.init(maximumEntries: maximumEntries, entryFlags: { $1 }, contentIdentifier: Self.fileContentIdentifier)
    }

    init(maximumEntries: Int, entryFlags: @escaping @Sendable (String, UInt32) -> UInt32,
         contentIdentifier: @escaping @Sendable (String) -> Int64?) {
        self.maximumEntries = maximumEntries
        self.entryFlags = entryFlags
        self.contentIdentifier = contentIdentifier
    }

    /// `SF_DATALESS` from sys/stat.h: an iCloud placeholder whose data lives on the server.
    static let datalessFlag: UInt32 = 0x4000_0000
    /// Clones are looked for only among files this large; smaller ones are not worth a second metadata read.
    static let cloneThreshold: Int64 = 1_000_000
    private static let cancellationStride = 512

    static let fileContentIdentifier: @Sendable (String) -> Int64? = { path in
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileContentIdentifierKey])
        return values?.fileContentIdentifier
    }

    /// Keyed by `url.path`. One inode set for the whole call, so items that share files count them once.
    /// `includeDates` also fills `newest` from the same walk (no second walk).
    public func measure(_ urls: [URL], includeDates: Bool = false) -> [String: CleanerSize] {
        CleanerIOPolicy.withoutDownloading {
            var walk = Walk(sizer: self, includeDates: includeDates)
            var sizes: [String: CleanerSize] = [:]
            for url in urls { sizes[url.path] = walk.measure(url.path) }
            return sizes
        }
    }

    public func measure(_ url: URL, includeDates: Bool = false) -> CleanerSize {
        measure([url], includeDates: includeDates)[url.path] ?? CleanerSize(bytes: 0, complete: false)
    }

    /// The state shared by every item of one call.
    private struct Walk {
        let sizer: CleanerSizer
        let includeDates: Bool
        var inodes = Set<FileKey>()
        var clones = Set<FileKey>()
        var visited = 0
        var stopped = false

        struct FileKey: Hashable { var device: Int32; var number: UInt64 }

        init(sizer: CleanerSizer, includeDates: Bool) {
            self.sizer = sizer
            self.includeDates = includeDates
        }

        mutating func measure(_ path: String) -> CleanerSize {
            var size = CleanerSize(bytes: 0, complete: true)
            guard !stopped else { size.complete = false; return size }
            guard let copy = strdup(path) else { size.complete = false; return size }
            defer { free(copy) }
            var paths: [UnsafeMutablePointer<CChar>?] = [copy, nil]
            guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
                size.complete = false
                return size
            }
            defer { fts_close(fts) }
            var newest: timespec?
            while let entry = fts_read(fts) {
                let info = Int32(entry.pointee.fts_info)
                // A folder comes back once more after its contents (or as unreadable); only the first visit counts.
                if info == FTS_DP || info == FTS_DC || info == FTS_DOT { continue }
                if info == FTS_DNR || info == FTS_ERR || info == FTS_NS {
                    // EDEADLK here means a dataless folder the policy kept from downloading; incomplete either way.
                    size.complete = false
                    continue
                }
                if visited % CleanerSizer.cancellationStride == 0, Task.isCancelled { stopped = true }
                if visited >= sizer.maximumEntries { stopped = true }
                if stopped { size.complete = false; break }
                visited += 1

                guard let status = entry.pointee.fts_statp?.pointee else { size.complete = false; continue }
                if includeDates, newest.map({ Self.isNewer(status.st_mtimespec, than: $0) }) ?? true {
                    newest = status.st_mtimespec
                }
                let flags = sizer.entryFlags(String(cString: entry.pointee.fts_path), status.st_flags)
                if flags & CleanerSizer.datalessFlag != 0 {
                    // Its data is on the server; reading below it would download it.
                    if info == FTS_D { fts_set(fts, entry, FTS_SKIP) }
                    size.complete = false
                    continue
                }
                let isDirectory = info == FTS_D
                if !isDirectory, status.st_nlink > 1,
                   !inodes.insert(FileKey(device: status.st_dev, number: status.st_ino)).inserted {
                    continue
                }
                let allocated = Int64(status.st_blocks) * 512
                if info == FTS_F, allocated >= CleanerSizer.cloneThreshold,
                   let identifier = sizer.contentIdentifier(String(cString: entry.pointee.fts_path)),
                   !clones.insert(FileKey(device: status.st_dev, number: UInt64(bitPattern: identifier))).inserted {
                    continue
                }
                size.bytes += allocated
            }
            if let newest {
                size.newest = Date(timeIntervalSince1970: TimeInterval(newest.tv_sec) + TimeInterval(newest.tv_nsec) / 1_000_000_000)
            }
            return size
        }

        private static func isNewer(_ time: timespec, than other: timespec) -> Bool {
            time.tv_sec != other.tv_sec ? time.tv_sec > other.tv_sec : time.tv_nsec > other.tv_nsec
        }
    }
}

/// Runs `body` with the thread's dataless-file policy set to "do not download", then restores the previous
/// policy. Every cleaner read that may meet iCloud placeholders goes through it, so a scan never downloads
/// a user's files.
public enum CleanerIOPolicy {
    public static func withoutDownloading<T>(_ body: () throws -> T) rethrows -> T {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                           IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            if previous >= 0 {
                _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous)
            }
        }
        return try body()
    }
}

public enum CleanerFormat {
    /// ByteCountFormatter, `.file` style, for display only. Digits always, so an empty file reads "0 bytes"
    /// beside "4 KB", not "Zero KB".
    public static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: value)
    }
}
